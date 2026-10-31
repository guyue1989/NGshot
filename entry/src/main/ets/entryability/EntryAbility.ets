import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { process } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { ProbeLog } from '../probe/ProbeLog';
import { initSettings, saveDirUriNow, hotkeyKeyNow, hotkeyModsNow } from '../common/ShotSettings';
import { activateGrant } from '../common/SaveDirGrant';
import { registerHotkey, unregisterHotkey, hotkeyText } from '../probe/Hotkey';
import { captureToOverlay, requestTrayCapture } from '../common/ShotFlow';
import { initTray, removeTray, trayAddedNow } from '../common/Tray';
import { startKeepAlive, stopKeepAlive } from '../common/KeepAlive';
import { applySavedTheme } from '../common/Theme';

const DOMAIN: number = 0x0000;
const TAG: string = 'NGshot';

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
    windowStage.loadContent('pages/Main', (err: BusinessError) => {
      if (err.code) {
        ProbeLog.add(`Main loadContent 失败 code=${err.code} msg=${err.message}`);
        return;
      }
      ProbeLog.add('主界面已加载');
      // setColorMode 的文档前提是“窗口已创建、页面已加载”，所以放在 loadContent 成功之后。
      applySavedTheme(this.context, (line: string): void => {
        ProbeLog.add(line);
      });
    });
    windowStage.getMainWindow().then((win: window.Window) => {
      AppStorage.setOrCreate('mainWindow', win);
      ProbeLog.add(`主窗口已登记 ${JSON.stringify(win.getWindowProperties())}`);
    }).catch((e: BusinessError) => {
      ProbeLog.add(`getMainWindow 失败 code=${e.code} msg=${e.message}`);
    });
    this.hideInsteadOfClose(windowStage);
    // hideAbility() 文档要求状态栏图标已存在，所以先让图标挂上，图标的结果决定关闭按钮能否隐藏。
    initTray((line: string): void => {
      ProbeLog.add(line);
    }, this.context, hotkeyText(hotkeyModsNow(), hotkeyKeyNow()), (): void => {
      void requestTrayCapture((line: string): void => {
        ProbeLog.add(line);
      }, this.context);
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
      // 隐藏后的窗口不一定走过 onBackground（触发时前台标志仍是 是），所以保活不能只靠那个回调。
      startKeepAlive((line: string): void => {
        ProbeLog.add(line);
      }, this.context);
    }).catch((e: BusinessError): void => {
      ProbeLog.add(`hideAbility 失败 code=${e.code} msg=${e.message}`);
      this.setHidden(false);
      this.minimizeFallback();
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
    // 点一次面板会连着唤起两次，这段逻辑必须可重入：未隐藏时 showAbility() 是空操作，
    // 第二遍也不能把窗口当成最小化恢复的。
    ProbeLog.add(`唤起主界面（此前收起态=${wasHidden ? 'hideAbility' : '没收起'}）`);
    this.context.showAbility().then((): void => {
      if (wasHidden) {
        ProbeLog.add('showAbility 成功，主界面回来了');
      }
      // 回到可见后，常驻阶段持有长时任务的理由就不在了。
      stopKeepAlive((line: string): void => {
        ProbeLog.add(line);
      }, this.context);
    }).catch((e: BusinessError): void => {
      ProbeLog.add(`showAbility 失败 code=${e.code} msg=${e.message}`);
    });
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 只有右键菜单「打开主界面」会到这里，托盘左键直达框选层。startAbility 撤销不了 hideAbility，
    // 所以用 showAbility()。
    this.showFromTray();
  }

  onForeground(): void {
    AppStorage.setOrCreate('appForeground', true);
    // 只有最小化后从 Dock 点回来这一条要把收起标志改回可见：它不走 showFromTray，窗口是系统恢复的。
    // 其他回到前台的时机窗口不一定真在屏上，跟着清标志会让下一张拍错。
    if (AppStorage.get<boolean>('abilityMinimized') === true) {
      AppStorage.setOrCreate('abilityMinimized', false);
      ProbeLog.add('从 Dock 点回来了（此前是最小化），收起标志改回可见');
      this.setHidden(false);
    }
    ProbeLog.add('EntryAbility onForeground');
  }

  onBackground(): void {
    AppStorage.setOrCreate('appForeground', false);
    ProbeLog.add('EntryAbility onBackground');
    // 后台进程没有长时任务会被挂起，挂起后就不再响应全局快捷键。每次都申请，系统可能悄悄收回。
    startKeepAlive((line: string): void => {
      ProbeLog.add(line);
    }, this.context);
  }

  onDestroy(): void {
    unregisterHotkey((line: string): void => {
      ProbeLog.add(line);
    });
    stopKeepAlive((line: string): void => {
      ProbeLog.add(line);
    }, this.context);
    removeTray((line: string): void => {
      ProbeLog.add(line);
    }, this.context);
    ProbeLog.add('EntryAbility onDestroy');
  }
}
