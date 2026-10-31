import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { display, window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { process } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { ProbeLog } from '../probe/ProbeLog';
import { cancelSelect, isSelectFlowBusy, captureForTrayOverlay } from '../common/ShotFlow';

const DOMAIN: number = 0x0000;
const TAG: string = 'NGshot';
const OVERLAY_PAGE: string = 'pages/SelectPage';
const OVERLAY_WINDOW: string = 'ngshot_overlay';

// 托盘图标左键拉起的框选层带这个参数：先自己拍屏再上屏。没有它就是快捷键那条路，
// 屏幕已经由 EntryAbility 拍好放进 ShotService 了。
function wantsCapture(want: Want): boolean {
  const params: Record<string, Object> | undefined = want.parameters;
  if (params === undefined) {
    return false;
  }
  const v: Object | undefined = params['ngCapture'];
  return v !== undefined && v.toString() === '1';
}

// 框选层失去系统激活后，页面收不到 Esc，onBackground 也未必来，截图锁就一直不放，
// 之后每次 Ctrl+1 和托盘左键都撞在「上一次还没结束」上，只能退出应用。
// 宽限 1.5s 是留给正常出口的：复制、保存、取消时窗口同样会先失去激活，那几条路自己会放锁并
// terminateSelf，这里过了宽限再确认一次 busy 才发信号。
const ABANDON_GRACE_MS: number = 1500;
let abandonTimer: number = -1;
let abandonSeq: number = 0;

function watchActivation(active: boolean): void {
  if (abandonTimer >= 0) {
    clearTimeout(abandonTimer);
    abandonTimer = -1;
  }
  if (active) {
    return;
  }
  abandonTimer = setTimeout((): void => {
    abandonTimer = -1;
    if (!isSelectFlowBusy()) {
      return;
    }
    abandonSeq++;
    ProbeLog.add('框选层失去激活 1.5s 还停在流程里，通知页面按取消处理（否则截图锁不放，热键全废）');
    AppStorage.setOrCreate('selectAbandon', abandonSeq);
  }, ABANDON_GRACE_MS);
}

// 全屏框选层。
// 独立能力的原因和编辑器一样：主能力 hideAbility() 后，它的子窗能拿到窗口 id，但 globalDisplayRect
// 为 0x0，不会上屏。与 EntryAbility 同进程（没有 process 字段），页面直接读 ShotService 里截好的全屏 PNG。
export default class SelectAbility extends UIAbility {
  private fromTray: boolean = false;
  // 全屏层承载在子窗上时为该句柄，退回能力主窗时为 null——重载内容用的接口不一样。
  private overlayWin: window.Window | null = null;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.fromTray = wantsCapture(want);
    AppStorage.setOrCreate('selectAbilityContext', this.context);
    ProbeLog.add(`SelectAbility onCreate pid=${process.pid}`);
    hilog.info(DOMAIN, TAG, 'select ability created');
  }

  // 能力是到前台的（上屏后 8ms 就触发 onForeground），所以 Esc 收不到不是被判成后台，
  // 而是窗口没被系统激活，见 claimFocus()。这两行日志留着，方便看能力有没有来回切。
  onForeground(): void {
    ProbeLog.add('SelectAbility onForeground');
  }

  onBackground(): void {
    ProbeLog.add('SelectAbility onBackground');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    if (!this.fromTray) {
      this.openOverlay(windowStage);
      return;
    }
    // 托盘这条路：窗口还没 loadContent，屏幕上没有任何自家内容，拍出来的就是纯桌面。
    ProbeLog.add('框选层：托盘左键发起，先拍屏再上屏（主界面全程不出现）');
    captureForTrayOverlay((line: string): void => {
      ProbeLog.add(line);
    }, this.context).then((ok: boolean): void => {
      if (!ok) {
        ProbeLog.add('托盘这一张没拍成，框选层直接收掉');
        this.context.terminateSelf();
        return;
      }
      this.openOverlay(windowStage);
    }).catch((e: BusinessError) => {
      ProbeLog.add(`托盘截图异常 code=${e.code} msg=${e.message}，框选层收掉`);
      this.context.terminateSelf();
    });
  }

  // 全屏层优先做成子窗：子窗 decorEnabled=false 时创建即沉浸式布局，位置由应用自己定，能压到
  // 状态栏区域（0,0）。能力主窗是系统摆的普通自由窗，上屏时会被摆到工作区里（windowRect @0,75），
  // 而且挪不回来——这台设备上 setWindowLayoutFullScreen 返回成功，窗口标记却还是 false，
  // 系统一直按普通窗口把它夹在工作区里。顶上的活桌面（连着真状态栏）和底图里的状态栏一并排，
  // 看着就是两条。所以快捷键和托盘都先走子窗，建不出来才退回主窗。
  private openOverlay(windowStage: window.WindowStage): void {
    this.openSubOverlay(windowStage).then((ok: boolean): void => {
      if (ok) {
        return;
      }
      ProbeLog.add('框选层改用能力主窗（子窗这条路没成）');
      this.openMainOverlay(windowStage);
    });
  }

  private async openSubOverlay(windowStage: window.WindowStage): Promise<boolean> {
    try {
      const opts: window.SubWindowOptions = {
        title: '',
        decorEnabled: false
      };
      const sub: window.Window = await windowStage.createSubWindowWithOptions(OVERLAY_WINDOW, opts);
      this.overlayWin = sub;
      AppStorage.setOrCreate('selectWindow', sub);
      await sub.setUIContent(OVERLAY_PAGE);
      ProbeLog.add('SelectPage 已加载（子窗）');
      await fitToDisplay(sub, '框选层子窗');
      await sub.showWindow();
      if (!onScreen(sub)) {
        // 主窗还没上过屏时子窗跟不出来：把能力主窗显出来（它没有内容，屏幕上看不到东西）再挂一次。
        ProbeLog.add('框选层子窗没上屏，先显示能力主窗再试');
        const main: window.Window = await windowStage.getMainWindow();
        await main.showWindow();
        await sleep(120);
        await sub.showWindow();
      }
      if (!onScreen(sub)) {
        ProbeLog.add('框选层子窗仍未上屏，改成主窗承载');
        await this.dropSubOverlay();
        return false;
      }
      await nudgeToOrigin(sub);
      await claimFocus(sub);
      return true;
    } catch (e) {
      const err = e as BusinessError;
      ProbeLog.add(`框选层子窗没建成 code=${err.code} msg=${err.message}`);
      await this.dropSubOverlay();
      return false;
    }
  }

  private async dropSubOverlay(): Promise<void> {
    const w: window.Window | null = this.overlayWin;
    this.overlayWin = null;
    AppStorage.delete('selectWindow');
    if (w === null) {
      return;
    }
    try {
      await w.destroyWindow();
    } catch (e) {
      const err = e as BusinessError;
      ProbeLog.add(`框选层子窗销毁失败 code=${err.code} msg=${err.message}`);
    }
  }

  private openMainOverlay(windowStage: window.WindowStage): void {
    // 两个时序约束。resize/move/setWindowLayoutFullScreen 必须在 loadContent 之前，否则窗口会先按当时
    // 的尺寸闪一下再铺满（loadContent 会自动显示窗口）；setWindowDecorVisible 在窗口显示前调用抛 1300002，
    // 只能放在 loadContent 之后重试，成功后页面 onAreaChange 重新测量，kx/ky 映射自动修正。
    this.overlayWin = null;
    let main: window.Window | null = null;
    windowStage.getMainWindow().then((win: window.Window) => {
      main = win;
      AppStorage.setOrCreate('selectWindow', win);
      ProbeLog.add(`框选窗主窗已登记 ${JSON.stringify(win.getWindowProperties())}`);
      return makeOverlay(win);
    }).then((): Promise<void> => new Promise<void>((resolve: () => void) => {
      windowStage.loadContent(OVERLAY_PAGE, (err: BusinessError) => {
        if (err.code) {
          ProbeLog.add(`SelectPage loadContent 失败 code=${err.code} msg=${err.message}`);
        } else {
          ProbeLog.add('SelectPage 已加载');
        }
        resolve();
      });
    })).then((): Promise<void> => {
      if (main === null) {
        return Promise.resolve();
      }
      return hideDecorWhenReady(main, '框选层');
    }).then((): Promise<void> => {
      if (main === null) {
        return Promise.resolve();
      }
      return nudgeToOrigin(main);
    }).then((): Promise<void> => {
      if (main === null) {
        return Promise.resolve();
      }
      return claimFocus(main);
    }).catch((e: BusinessError) => {
      ProbeLog.add(`框选窗 getMainWindow 失败 code=${e.code} msg=${e.message}`);
    });
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 同时只有一个框选层：下一次截图重载页面重画新图即可，窗口尺寸已经就位，不必重跑 makeOverlay。
    const win: window.Window | undefined = AppStorage.get<window.Window>('selectWindow');
    if (win === undefined) {
      ProbeLog.add('第二次框选要复用全屏层，但主窗没登记上');
      return;
    }
    const w: window.Window = win;
    if (!wantsCapture(want)) {
      void this.reloadOverlay(w);
      return;
    }
    // 框选层还留着时又点了托盘图标：重拍一张再重载。正在流程里就跳过这一下——不能 terminateSelf，
    // 那会把用户正在框的这张一起收掉。
    if (isSelectFlowBusy()) {
      ProbeLog.add('托盘又点了一下，但截图流程还在跑，忽略');
      return;
    }
    captureForTrayOverlay((line: string): void => {
      ProbeLog.add(line);
    }, this.context).then((ok: boolean): void => {
      if (!ok) {
        this.context.terminateSelf();
        return;
      }
      void this.reloadOverlay(w);
    });
  }

  private reloadOverlay(w: window.Window): Promise<void> {
    const page: Promise<void> = this.overlayWin !== null ? w.setUIContent(OVERLAY_PAGE) : w.loadContent(OVERLAY_PAGE);
    return page.then((): Promise<void> => {
      ProbeLog.add('框选窗已复用并重新加载');
      return nudgeToOrigin(w);
    }).then((): void => {
      void claimFocus(w);
    }).catch((e: BusinessError) => {
      ProbeLog.add(`框选窗重新加载失败 code=${e.code} msg=${e.message}`);
    });
  }

  onDestroy(): void {
    ProbeLog.add('SelectAbility onDestroy');
    if (abandonTimer >= 0) {
      clearTimeout(abandonTimer);
      abandonTimer = -1;
    }
    // 页面没走出口就被销毁（窗口被系统收掉），锁只能在这里放，否则本进程后续热键全部作废。
    if (isSelectFlowBusy()) {
      cancelSelect((line: string): void => {
        ProbeLog.add(line);
      });
    }
  }
}

// 子窗按屏幕像素铺满并挪到左上角。子窗创建即沉浸式布局，内容可以进状态栏那一条，
// 所以这里的 0,0 是屏幕原点，不是工作区原点。
async function fitToDisplay(win: window.Window, tag: string): Promise<void> {
  const d = display.getDefaultDisplaySync();
  await win.resizeAsync(d.width, d.height);
  await win.moveWindowToAsync(0, 0);
  try {
    await win.setWindowLayoutFullScreen(true);
  } catch (e) {
    const err = e as BusinessError;
    ProbeLog.add(`${tag}：setWindowLayoutFullScreen 失败 code=${err.code} msg=${err.message}`);
  }
  const p = win.getWindowProperties();
  ProbeLog.add(`${tag}铺屏：屏 ${d.width}x${d.height} → windowRect `
    + `${p.windowRect.width}x${p.windowRect.height}@${p.windowRect.left},${p.windowRect.top}`
    + `，globalDisplayRect ${JSON.stringify(p.globalDisplayRect)}`);
}

// 窗口没上屏时查属性拿到的是 0×0 的显示区。
function onScreen(win: window.Window): boolean {
  try {
    const r: window.Rect | undefined = win.getWindowProperties().globalDisplayRect;
    return r !== undefined && r.width > 0 && r.height > 0;
  } catch (e) {
    return false;
  }
}

// 窗口显示前 setWindowDecorVisible 一律抛 1300002，所以放在 loadContent 之后重试，直到自动显示发生。
// 若始终没成功，页面按带 70px 标题栏布局，映射日志里的 ky 会偏。
async function hideDecorWhenReady(win: window.Window, tag: string): Promise<void> {
  for (let i = 0; i < 40; i++) {
    try {
      await win.setWindowDecorVisible(false);
      ProbeLog.add(`${tag}：标题栏已隐藏`);
      return;
    } catch (e) {
      await new Promise<void>((resolve: () => void) => {
        setTimeout(resolve, 50);
      });
    }
  }
  ProbeLog.add(`${tag}：标题栏重试 2s 仍藏不掉（1300002 持续），布局要按留标题栏看`);
}

// 三步各自 try：哪一步被这台设备拒绝，决定布局怎么做。setWindowDecorVisible/maximize 属于
// SessionManager（可能抛 801/1300004），resizeAsync/moveWindowToAsync/setWindowLayoutFullScreen
// 属于 WindowManager.Core。
// 能力主窗上 resizeAsync 按 px 算（请求 3118x2173，windowRect 就是 3118x2173），直接传屏幕像素。
async function makeOverlay(win: window.Window): Promise<void> {
  try {
    await win.setWindowLayoutFullScreen(true);
    ProbeLog.add('框选层：布局已延伸到状态栏区域（状态栏本身在 PC 上关不掉，见 setSpecificSystemBarEnabled 的 2in1 说明）');
  } catch (e) {
    const err = e as BusinessError;
    ProbeLog.add(`框选层 setWindowLayoutFullScreen 失败 code=${err.code} msg=${err.message}`);
  }
  try {
    const d = display.getDefaultDisplaySync();
    await win.resizeAsync(d.width, d.height);
    await win.moveWindowToAsync(0, 0);
    const props = win.getWindowProperties();
    ProbeLog.add(`框选层铺屏：屏 ${d.width}x${d.height} → windowRect `
      + `${props.windowRect.width}x${props.windowRect.height}@${props.windowRect.left},${props.windowRect.top}`
      + `，drawable ${props.drawableRect.width}x${props.drawableRect.height}`
      + `，globalDisplayRect ${JSON.stringify(props.globalDisplayRect)}`);
    // windowRect 偶尔报 top=75（状态栏高度）而 globalDisplayRect 仍是 0,0。300ms 后再读一次，
    // 两次不一样说明是全屏布局与移动的先后竞争、最终会落定；两次都是 75 才是真的下移了。
    setTimeout((): void => {
      try {
        const late = win.getWindowProperties();
        ProbeLog.add(`框选层铺屏 300ms 后：windowRect `
          + `${late.windowRect.width}x${late.windowRect.height}@${late.windowRect.left},${late.windowRect.top}`
          + `，globalDisplayRect ${JSON.stringify(late.globalDisplayRect)}`);
      } catch (e) {
        // 300ms 内已经收掉的窗口查属性会抛，这类情况本来就不需要这条日志。
      }
    }, 300);
  } catch (e) {
    const err = e as BusinessError;
    ProbeLog.add(`框选层 resize/move 失败 code=${err.code} msg=${err.message}`);
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(resolve, ms);
  });
}

// 窗口曾被系统摆到 top=75（≈状态栏高）：底图下沿 75px 看不到、顶部 75px 露出活桌面。
// 成因是 show 之后系统按工作区又摆了一次位，而这时之前设过的全屏布局标记可能已被装饰刷新清掉，
// moveWindowToAsync(0,0) 会被夹回工作区原点，而且结果要隔一拍才读得到。所以这里改成
// 「重设全屏布局 → 挪 → 复查」，直到真的归零；否则顶上那条活桌面和底图里的状态栏会并排出现，
// 看着就是两条状态栏。
async function nudgeToOrigin(win: window.Window): Promise<void> {
  const d = display.getDefaultDisplaySync();
  let last: string = '';
  for (let i = 0; i < 10; i++) {
    const r: window.Rect | null = windowRectOf(win);
    if (r === null) {
      return;
    }
    last = `${r.left},${r.top}`;
    if (r.left === 0 && r.top === 0) {
      if (i > 0) {
        ProbeLog.add(`框选层已复位到 0,0（第${i + 1}次复查）`);
      }
      return;
    }
    if (i === 0) {
      try {
        await win.setWindowLayoutFullScreen(true);
        await win.resizeAsync(d.width, d.height);
      } catch (e) {
        const err = e as BusinessError;
        ProbeLog.add(`框选层复位前重设全屏布局失败 code=${err.code} msg=${err.message}`);
      }
    }
    try {
      await win.moveWindowToAsync(0, 0);
    } catch (e) {
      const err = e as BusinessError;
      ProbeLog.add(`框选层复位失败 code=${err.code} msg=${err.message}`);
      return;
    }
    await sleep(100);
  }
  ProbeLog.add(`框选层停在 ${last} 没复位${layoutFlagsOf(win)}`);
}

function windowRectOf(win: window.Window): window.Rect | null {
  try {
    return win.getWindowProperties().windowRect;
  } catch (e) {
    return null;
  }
}

function layoutFlagsOf(win: window.Window): string {
  try {
    const p = win.getWindowProperties();
    return `（布局全屏=${p.isLayoutFullScreen} 窗口全屏=${p.isFullScreen}）`;
  } catch (e) {
    return '';
  }
}

// 键盘焦点：刚上屏时 isFocused 为 false，按键到不了页面，而组件级 requestFocus 是成功的，
// 缺的是窗口级系统键盘焦点。主动 showWindow() 后 200~250ms 变 true，所以循环调用并盯到
// isFocused 为 true 再返回。
async function claimFocus(win: window.Window): Promise<void> {
  try {
    win.on('windowHighlightChange', (on: boolean) => {
      ProbeLog.add(`框选层激活态变化 → ${on ? '激活' : '非激活'}`);
      watchActivation(on);
    });
  } catch (e) {
    const err = e as BusinessError;
    ProbeLog.add(`框选层激活态监听没挂上 code=${err.code}`);
  }
  for (let attempt = 1; attempt <= 3; attempt++) {
    try {
      await win.showWindow();
    } catch (e) {
      const err = e as BusinessError;
      ProbeLog.add(`框选层 showWindow 第${attempt}次失败 code=${err.code} msg=${err.message}`);
      return;
    }
    for (let i = 1; i <= 6; i++) {
      await sleep(100);
      let focused: boolean = false;
      try {
        focused = win.isFocused();
      } catch (e) {
        const err = e as BusinessError;
        ProbeLog.add(`框选层 isFocused 查询失败 code=${err.code} msg=${err.message}`);
        return;
      }
      if (focused) {
        ProbeLog.add(`框选层：系统键盘焦点到位（第${attempt}次 showWindow 后 ${i * 100}ms）`);
        return;
      }
    }
  }
  ProbeLog.add('框选层：3 次 showWindow 各等 600ms 仍没有系统键盘焦点，Esc 大概还得等第一次点击');
}
