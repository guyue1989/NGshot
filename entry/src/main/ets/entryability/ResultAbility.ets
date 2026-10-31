import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { display, window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { process } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { ProbeLog } from '../probe/ProbeLog';

const DOMAIN: number = 0x0000;
const TAG: string = 'NGshot';

// 用 createSubWindowWithOptions 建的结果窗在主能力 hideAbility() 后能拿到窗口 id，但 globalDisplayRect
// 为 0x0，直到 showAbility() 把整个能力带到前台才上屏，所以编辑器不能做常驻能力的子窗，要有独立能力。
// 两个能力都没写 process 字段，同进程，页面才能直接读 ShotService 里的 PNG 和 AppStorage 状态。
export default class ResultAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    AppStorage.setOrCreate('resultAbilityContext', this.context);
    ProbeLog.add(`ResultAbility onCreate pid=${process.pid}`);
    hilog.info(DOMAIN, TAG, 'result ability created');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/ShotPage', (err: BusinessError) => {
      if (err.code) {
        ProbeLog.add(`ShotPage loadContent 失败 code=${err.code} msg=${err.message}`);
        return;
      }
      ProbeLog.add('ShotPage 已加载');
    });
    windowStage.getMainWindow().then((win: window.Window) => {
      AppStorage.setOrCreate('resultWindow', win);
      ProbeLog.add(`结果窗主窗已登记 ${JSON.stringify(win.getWindowProperties())}`);
      return fitToShot(win);
    }).catch((e: BusinessError) => {
      ProbeLog.add(`结果窗 getMainWindow 失败 code=${e.code} msg=${e.message}`);
    });
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 同时只有一个编辑窗：第二次截图重载本页，按新数据重画，而不是再叠一个窗口。
    const win: window.Window | undefined = AppStorage.get<window.Window>('resultWindow');
    if (win === undefined) {
      ProbeLog.add('第二次截图要复用结果窗，但主窗没登记上');
      return;
    }
    win.loadContent('pages/ShotPage').then((): Promise<void> => {
      ProbeLog.add('结果窗已复用并重新加载');
      return fitToShot(win);
    }).catch((e: BusinessError) => {
      ProbeLog.add(`结果窗重新加载失败 code=${e.code} msg=${e.message}`);
    });
  }

  onDestroy(): void {
    ProbeLog.add('ResultAbility onDestroy');
  }
}

// 按图片尺寸贴合结果窗，单位 px：能力主窗上 resizeAsync 请求 3118x2173 就得到 windowRect 3118x2173
// （只有 window.createWindow() 的窗口收 vp）。windowRect 含标题栏，装饰和页面自身的 chrome 都要加在
// 图片高度上；系统不会把窗口裁进屏幕，2173px 落在 2080px 的屏上会把按钮顶出底边，所以整体夹一次。
async function fitToShot(win: window.Window): Promise<void> {
  const w: number | undefined = AppStorage.get<number>('shotWidth');
  const h: number | undefined = AppStorage.get<number>('shotHeight');
  if (w === undefined || h === undefined || w <= 0 || h <= 0) {
    ProbeLog.add('结果窗没拿到 shotWidth/shotHeight，保持默认尺寸');
    return;
  }
  const CHROME_VP: number = 160;
  const DECOR_PX: number = 70;
  try {
    const d = display.getDefaultDisplaySync();
    const chromePx: number = Math.round(CHROME_VP * d.densityPixels) + DECOR_PX;
    const targetW: number = Math.min(w, d.width);
    const targetH: number = Math.min(h + chromePx, d.height);
    await win.resizeAsync(targetW, targetH);
    const props = win.getWindowProperties();
    ProbeLog.add(`结果窗贴合：图 ${w}x${h}，屏 ${d.width}x${d.height}，chrome ${chromePx}px`
      + ` → 请求 ${targetW}x${targetH}，windowRect ${props.windowRect.width}x${props.windowRect.height}`
      + `，drawable ${props.drawableRect.width}x${props.drawableRect.height}`);
  } catch (e) {
    const err = e as BusinessError;
    ProbeLog.add(`结果窗 resizeAsync 失败 code=${err.code} msg=${e.message}`);
  }
}
