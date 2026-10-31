import { AbilityConstant, contextConstant, StartOptions, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { process } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { ProbeLog } from '../probe/ProbeLog';
import { initSettings, saveDirUriNow, hotkeyKeyNow, hotkeyModsNow } from '../common/ShotSettings';
import { activateGrant } from '../common/SaveDirGrant';
import { registerHotkey, unregisterHotkey, hotkeyText } from '../probe/Hotkey';
import { BUNDLE_NAME, captureToOverlay, requestTrayCapture } from '../common/ShotFlow';
import { initTray, removeTray, trayAddedNow } from '../common/Tray';
import { applySavedTheme } from '../common/Theme';

const DOMAIN: number = 0x0000;
const TAG: string = 'NGshot';
// 绑进程用的能力：它平时不跑，所以带 processMode 拉起不会撞上 16000068（Ability 已经在运行中）。
const BACK: string = 'BackGroundAbility';
// addToStatusBar() 是同步返回的，但图标在系统服务那边注册完要晚一点，而「图标在不在」同时决定了
// 绑定和收起两个调用能不能过，所以两者都按这个次数和间隔重试。
const RETRY_TRIES: number = 3;
const RETRY_GAP: number = 400;
// 设备不支持（不是 2in1 / 平板）：重试多少次都不会变，直接放弃。
const NOT_SUPPORTED: number = 801;

export default class EntryAbility extends UIAbility {
  // hideAbility() 与 minimize() 是两种不同状态：只有 showAbility() 撤销前者，只有 startAbility()
  // 撤销后者，所以要记住做过哪一种。状态放 AppStorage，因为 ShotFlow 截图时也会隐藏窗口，
  // 两个私有布尔值会互相矛盾。
  private isHidden(): boolean {
    return AppStorage.get<boolean>('abilityHidden') === true;
  }

  private setHidden(hidden: boolean): void {
    AppStorage.setOrCreate('abilityHidden', hidden);
  }

  // 主界面只在真要看的时候才建：冷启动直接挂到状态栏，右键「打开主界面」时才 loadContent。
  private stage: window.WindowStage | null = null;
  private mainLoaded: boolean = false;
  // 启动收起还没做成就是 true；每次重试和补做都只看它，做成或彻底放弃时清掉。
  private startupHidePending: boolean = false;
  private startupHideTries: number = 0;
  private bindTries: number = 0;
  private iconBound: boolean = false;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    ProbeLog.init(this.context.filesDir);
    // 页面通过 AppStorage 拿 context，本 SDK 上的 getContext() 已废弃。
    AppStorage.setOrCreate('abilityContext', this.context);
    AppStorage.setOrCreate('appForeground', true);
    ProbeLog.add(`EntryAbility onCreate pid=${process.pid} filesDir=${this.context.filesDir}`);
    initSettings(this.context, (line: string): void => {
      ProbeLog.add(line);
    }).then((): void => {
      // 持久化的目录授权要 activatePermission 重新加载才生效，每次启动都必须做，
      // 否则重启后保存目录不可写，截图静默失败。
      const uri: string = saveDirUriNow();
      if (uri !== '') {
        activateGrant(uri, (line: string): void => {
          ProbeLog.add(line);
        });
      }
    });
    // 快捷键才是真正的入口，先于任何界面挂上。
    registerHotkey((line: string): void => {
      ProbeLog.add(line);
    }, (source: string): void => {
      const fg: boolean | undefined = AppStorage.get<boolean>('appForeground');
      ProbeLog.add(`${source} 命中 前台=${fg === true ? '是' : '否'} 隐藏=${this.isHidden() ? '是' : '否'}`);
      captureToOverlay((line: string): void => {
        ProbeLog.add(line);
      }, this.context);
    });
    hilog.info(DOMAIN, TAG, 'onCreate');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    this.stage = windowStage;
    windowStage.getMainWindow().then((win: window.Window) => {
      AppStorage.setOrCreate('mainWindow', win);
      ProbeLog.add(`主窗口已登记 ${JSON.stringify(win.getWindowProperties())}`);
    }).catch((e: BusinessError) => {
      ProbeLog.add(`getMainWindow 失败 code=${e.code} msg=${e.message}`);
    });
    this.hideInsteadOfClose(windowStage);
    // hideAbility() 文档要求状态栏图标已存在，所以先让图标挂上；挂上之后这次启动就不再显示主界面，
    // 图标没挂上时不能收——收进状态栏就没有任何入口了，只能照旧把主界面打开。
    initTray((line: string): void => {
      ProbeLog.add(line);
    }, this.context, hotkeyText(hotkeyModsNow(), hotkeyKeyNow()), (): void => {
      void requestTrayCapture((line: string): void => {
        ProbeLog.add(line);
      }, this.context);
    }).then((ok: boolean): void => {
      if (!ok) {
        ProbeLog.add('托盘图标没挂上，这次仍打开主界面（收起就没有入口了）');
        this.ensureMainLoaded();
        return;
      }
      // 官方把 16000067 的可能原因写成「调用方不是以 attach 模式启动」，所以先绑定再收起。
      this.bindToStatusBar();
      this.startupHidePending = true;
      this.hideAtStartup();
    });
  }

  // 进程绑到状态栏图标上，这是鸿蒙 PC 给托盘应用的官方保活方式：绑上之后窗口收起进程也不被挂起，
  // 全局快捷键继续可用。走这条就不再申请长时任务，那条「正在运行计算任务」的常驻通知也随之消失。
  // 前提是应用已经在状态栏有图标，否则校验不过，所以图标刚挂上那一下要重试。
  // 绑定是进程级的，做成一次就不再需要；没做成时只靠 hideAbility + 托盘图标，本机实测也不会被挂起。
  // STARTUP_HIDE 保证这个能力不上屏、不进 Dock。
  private bindToStatusBar(): void {
    if (this.iconBound) {
      return;
    }
    this.bindTries++;
    const attempt: number = this.bindTries;
    const target: Want = { bundleName: BUNDLE_NAME, abilityName: BACK };
    const options: StartOptions = {
      processMode: contextConstant.ProcessMode.ATTACH_TO_STATUS_BAR_ITEM,
      startupVisibility: contextConstant.StartupVisibility.STARTUP_HIDE
    };
    this.context.startAbility(target, options).then((): void => {
      this.iconBound = true;
      ProbeLog.add(`进程已绑定状态栏图标（attach 保活，无常驻通知，第 ${attempt} 次尝试）`);
    }).catch((e: BusinessError): void => {
      if (e.code === NOT_SUPPORTED) {
        ProbeLog.add(`本机不支持状态栏图标绑定 code=801，常驻只靠 hideAbility + 托盘图标`);
        return;
      }
      ProbeLog.add(`绑定状态栏图标第 ${attempt} 次落空 code=${e.code} msg=${e.message}`);
      if (attempt >= RETRY_TRIES) {
        ProbeLog.add(`绑定 ${RETRY_TRIES} 次都没做成，常驻只靠 hideAbility + 托盘图标（本机实测这样也不被挂起）`);
        return;
      }
      setTimeout((): void => {
        this.bindToStatusBar();
      }, RETRY_GAP);
    });
  }

  // 主界面延迟到真要看时才加载；setColorMode 的文档前提是“窗口已创建、页面已加载”，所以放在回调里。
  private ensureMainLoaded(): void {
    if (this.mainLoaded || this.stage === null) {
      return;
    }
    this.mainLoaded = true;
    const stage: window.WindowStage = this.stage;
    stage.loadContent('pages/Main', (err: BusinessError) => {
      if (err.code) {
        this.mainLoaded = false;
        ProbeLog.add(`Main loadContent 失败 code=${err.code} msg=${err.message}`);
        return;
      }
      ProbeLog.add('主界面已加载');
      applySavedTheme(this.context, (line: string): void => {
        ProbeLog.add(line);
      });
    });
  }

  // 标题栏的 X 不能退出一个住在状态栏里的工具：把关闭请求转成 hideAbility()，窗口和 Dock 条目消失，
  // 进程、快捷键订阅、托盘图标都还在。windowStageClose 只在自由窗口态触发，6.1+ 最大化窗口走正常关闭，
  // 所以返回值和日志都要看。
  private hideInsteadOfClose(windowStage: window.WindowStage): void {
    try {
      windowStage.on('windowStageClose', (): boolean => {
        const hasIcon: boolean = trayAddedNow();
        ProbeLog.add(`点关闭：托盘=${hasIcon ? '已挂' : '没挂上'} → ${hasIcon ? 'hideAbility' : 'minimize'}`);
        if (hasIcon) {
          this.hideToTray();
        } else {
          this.minimizeFallback();
        }
        return true;
      });
    } catch (e) {
      const err = e as BusinessError;
      ProbeLog.add(`windowStageClose 监听注册失败 code=${err.code} msg=${err.message}`);
    }
  }

  private hideToTray(): void {
    // 不看收起标志：标志是“我们认为窗口在哪”，而 X 只有窗口真在屏上才点得到。两者对不上时
    // （例如标志没被清），照着标志跳过就等于 X 按了没反应。
    this.setHidden(true);
    this.context.hideAbility().then((): void => {
      ProbeLog.add('已收进状态栏（hideAbility 成功）');
    }).catch((e: BusinessError): void => {
      this.setHidden(false);
      ProbeLog.add(`hideAbility 失败 code=${e.code} msg=${e.message}`);
      this.minimizeFallback();
    });
  }

  // 冷启动的收起是「打开应用不弹主界面」的唯一保障，落空就重试：图标挂上之前那一下必定失败，
  // 而 initTray 的回调和首次 onForeground 谁先到不固定，只押一个时机就会漏。
  // 全落空时不去加载主界面（那正是要避免的），改成最小化：屏幕上没有本应用，快捷键和托盘左键照常用，
  // 而「打开主界面」和点 Dock 都会把界面补加载出来，不会留一个空白窗。
  private hideAtStartup(): void {
    if (!this.startupHidePending) {
      return;
    }
    this.startupHideTries++;
    const attempt: number = this.startupHideTries;
    this.setHidden(true);
    this.context.hideAbility().then((): void => {
      this.startupHidePending = false;
      ProbeLog.add(`已收进状态栏（hideAbility 成功，第 ${attempt} 次尝试）`);
    }).catch((e: BusinessError): void => {
      this.setHidden(false);
      ProbeLog.add(`启动收起第 ${attempt} 次落空 code=${e.code} msg=${e.message}`);
      if (attempt >= RETRY_TRIES) {
        this.startupHidePending = false;
        ProbeLog.add(`启动收起 ${RETRY_TRIES} 次都没做成，改成最小化（主界面仍不加载）`);
        this.minimizeFallback();
        return;
      }
      setTimeout((): void => {
        this.hideAtStartup();
      }, RETRY_GAP);
    });
  }

  private minimizeFallback(): void {
    const win: window.Window | undefined = AppStorage.get<window.Window>('mainWindow');
    if (win === undefined) {
      ProbeLog.add('要关窗但拿不到主窗口，只能放着');
      return;
    }
    win.minimize().then((): void => {
      // 标记这次是系统最小化而非 hideAbility，onForeground 只认这一条来清收起标志。
      AppStorage.setOrCreate('abilityMinimized', true);
      ProbeLog.add('主窗口已最小化（没有托盘图标时的退路）');
    }).catch((e: BusinessError): void => {
      ProbeLog.add(`minimize 失败 code=${e.code} msg=${e.message}`);
    });
  }

  private showFromTray(): void {
    const wasHidden: boolean = this.isHidden();
    this.setHidden(false);
    this.startupHidePending = false;
    this.ensureMainLoaded();
    // 点一次面板会连着唤起两次，这段逻辑必须可重入：未隐藏时 showAbility() 是空操作，
    // 第二遍也不能把窗口当成最小化恢复的。
    ProbeLog.add(`唤起主界面（此前收起态=${wasHidden ? 'hideAbility' : '没收起'}）`);
    this.context.showAbility().then((): void => {
      if (wasHidden) {
        ProbeLog.add('showAbility 成功，主界面回来了');
      }
    }).catch((e: BusinessError): void => {
      ProbeLog.add(`showAbility 失败 code=${e.code} msg=${e.message}`);
    });
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 右键菜单「打开主界面」和再点一次桌面图标会到这里，托盘左键直达框选层。
    // startAbility 撤销不了 hideAbility，所以用 showAbility()。
    this.showFromTray();
  }

  onForeground(): void {
    AppStorage.setOrCreate('appForeground', true);
    // 图标回调和首次 onForeground 的先后不固定，两边都留一个补做入口，靠 startupHidePending 收敛。
    if (this.startupHidePending) {
      ProbeLog.add('在 onForeground 补做启动收起');
      this.hideAtStartup();
    }
    // 只有最小化后从 Dock 点回来这一条要把收起标志改回可见：它不走 showFromTray，窗口是系统恢复的。
    // 其他回到前台的时机窗口不一定真在屏上，跟着清标志会让下一张拍错。
    if (AppStorage.get<boolean>('abilityMinimized') === true) {
      AppStorage.setOrCreate('abilityMinimized', false);
      ProbeLog.add('从 Dock 点回来了（此前是最小化），收起标志改回可见');
      this.setHidden(false);
      // 空白窗没有可操作性，用户既然把窗口要回来了，就把界面加载出来。
      this.ensureMainLoaded();
    }
    ProbeLog.add('EntryAbility onForeground');
  }

  onBackground(): void {
    AppStorage.setOrCreate('appForeground', false);
    ProbeLog.add('EntryAbility onBackground');
  }

  onDestroy(): void {
    unregisterHotkey((line: string): void => {
      ProbeLog.add(line);
    });
    removeTray((line: string): void => {
      ProbeLog.add(line);
    }, this.context);
    ProbeLog.add('EntryAbility onDestroy');
  }
}
