import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { display, window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { process } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { ProbeLog } from '../probe/ProbeLog';
import { PinStage, consumePendingPin, setPagePin, peekPagePin } from '../common/PinService';

const DOMAIN: number = 0x0000;
const TAG: string = 'NGshot';

// 一张贴在屏幕上的贴图。launchType 是 standard（多实例），所以能同时贴多张，和单例的 Result/Select 不同。
// 独立能力的原因同上：主能力 hideAbility() 后，它的子窗 globalDisplayRect 为 0x0，不上屏。
// 与 EntryAbility 同进程，页面通过 PinService 读暂存的数据。
// 贴图是能力主窗，setWindowTopmost 在已声明的 ohos.permission.WINDOW_TOPMOST 下可用（子窗才返回 1300004）。
export default class PinAbility extends UIAbility {
  onCreate(_want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    const pin: PinStage | null = consumePendingPin();
    setPagePin(pin);
    ProbeLog.add(`PinAbility onCreate pid=${process.pid} 贴图 `
      + (pin === null ? '没有待贴数据' : `${pin.w}x${pin.h}@${pin.x},${pin.y} id=${pin.id}`));
    hilog.info(DOMAIN, TAG, 'pin ability created');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // resize/move 在 loadContent 之前，避免窗口先按默认浮动尺寸闪一下；setWindowDecorVisible 要等窗口
    // 显示，否则 1300002，放在加载之后重试。
    let main: window.Window | null = null;
    windowStage.getMainWindow().then((win: window.Window) => {
      main = win;
      return makePinWindow(win);
    }).then((): Promise<void> => new Promise<void>((resolve: () => void) => {
      windowStage.loadContent('pages/PinWindowPage', (err: BusinessError) => {
        if (err.code) {
          ProbeLog.add(`PinWindowPage loadContent 失败 code=${err.code} msg=${err.message}`);
        } else {
          ProbeLog.add('PinWindowPage 已加载');
        }
        resolve();
      });
    })).then((): Promise<void> => {
      if (main === null) {
        return Promise.resolve();
      }
      return hideDecorWhenReady(main, '贴图窗').then((): Promise<void> => topmostPin(main as window.Window));
    }).catch((e: BusinessError) => {
      ProbeLog.add(`贴图窗 getMainWindow 失败 code=${e.code} msg=${e.message}`);
    });
  }

  onDestroy(): void {
    ProbeLog.add('PinAbility onDestroy');
  }
}

// 与 SelectAbility 同一时序规则：窗口显示后 setWindowDecorVisible 才有效，
// 放在 loadContent 之后重试，别去硬碰 1300002。
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
  ProbeLog.add(`${tag}：标题栏重试 2s 仍藏不掉（1300002 持续），贴图会带一条标题栏`);
}

// 贴图窗是能力主窗，setWindowTopmost(true/false) 可用，只有子窗才返回 1300004。
// 置顶在加载完成后请求，catch 是兜底，不是预期失败。
async function topmostPin(win: window.Window): Promise<void> {
  try {
    await win.setWindowTopmost(true);
    ProbeLog.add('贴图窗：已置顶');
  } catch (e) {
    const err = e as BusinessError;
    ProbeLog.add(`贴图窗置顶失败 code=${err.code} msg=${err.message}`);
  }
}

// 和框选层同样三步，但不铺满屏幕：窗口贴着截图，放在原选区位置。能力主窗上 resizeAsync/
// moveWindowToAsync 按 px 算，系统不会把窗口约束进屏幕，尺寸和位置都得自己夹。
async function makePinWindow(win: window.Window): Promise<void> {
  try {
    await win.setWindowLayoutFullScreen(true);
  } catch (e) {
    const err = e as BusinessError;
    ProbeLog.add(`贴图窗 setWindowLayoutFullScreen 失败 code=${err.code} msg=${err.message}`);
  }
  const pin: PinStage | null = peekPagePin();
  const d = display.getDefaultDisplaySync();
  try {
    let w: number = d.width;
    let h: number = d.height;
    let x: number = 0;
    let y: number = 0;
    if (pin !== null) {
      w = Math.min(pin.w, d.width);
      h = Math.min(pin.h, d.height);
      x = Math.max(0, Math.min(pin.x, d.width - w));
      y = Math.max(0, Math.min(pin.y, d.height - h));
    }
    await win.resizeAsync(w, h);
    await win.moveWindowToAsync(x, y);
    const props = win.getWindowProperties();
    ProbeLog.add(`贴图窗贴合：请求 ${w}x${h}@${x},${y} → windowRect `
      + `${props.windowRect.width}x${props.windowRect.height}@${props.windowRect.left},${props.windowRect.top}`
      + `，drawable ${props.drawableRect.width}x${props.drawableRect.height}`
      + `，globalDisplayRect ${JSON.stringify(props.globalDisplayRect)}`);
  } catch (e) {
    const err = e as BusinessError;
    ProbeLog.add(`贴图窗 resize/move 失败 code=${err.code} msg=${err.message}`);
  }
}
