import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { BusinessError, Callback, emitter } from '@kit.BasicServicesKit';
import { statusBarManager } from '@kit.DeskTopExtensionKit';
import { ProbeLog } from '../probe/ProbeLog';

export type TrayLog = (line: string) => void;

const GLYPH: number = 24;
const MAIN_ABILITY: string = 'EntryAbility';
const MODULE: string = 'entry';

let added: boolean = false;
let clickCallback: Callback<emitter.EventData> | null = null;

// 托盘图标用应用图标里的“N”记号，两根圆头竖笔加一根斜笔。状态栏只收单色，白黑各一份，
// 24px 下也只放得下字母本身，相机和圆点在这么小的尺寸会糊在一起，所以不画。
// 字母占 10px 高（y 7~17）居中，四周留白由圆头描边填满。
function segDist(x: number, y: number, ax: number, ay: number, bx: number, by: number): number {
  const ex: number = bx - ax;
  const ey: number = by - ay;
  const l2: number = ex * ex + ey * ey;
  let t: number = l2 > 0 ? ((x - ax) * ex + (y - ay) * ey) / l2 : 0;
  if (t < 0) {
    t = 0;
  } else if (t > 1) {
    t = 1;
  }
  const dx: number = x - (ax + ex * t);
  const dy: number = y - (ay + ey * t);
  return Math.sqrt(dx * dx + dy * dy);
}

// 24 画布里的 N：两根竖笔在 x=7/17、y 7~17，笔画半径 1.5；斜笔两头各缩进 0.6 接在竖笔上。
// 笔画直径 3px，再粗斜笔就会贴上右竖笔、中间糊成一片，只剩一条清楚的缝。
// 距离场加 1px 覆盖抗锯齿，与图标生成脚本同一套算法。
function nCoverage(x: number, y: number): number {
  const r: number = 1.5;
  let d: number = segDist(x, y, 7, 7, 7, 17) - r;
  const dr: number = segDist(x, y, 17, 7, 17, 17) - r;
  if (dr < d) {
    d = dr;
  }
  const dd: number = segDist(x, y, 7.6, 16.4, 16.4, 7.6) - r;
  if (dd < d) {
    d = dd;
  }
  const cov: number = 0.5 - d;
  if (cov <= 0) {
    return 0;
  }
  return cov >= 1 ? 1 : cov;
}

// 状态栏要透明底的单色图标，白色和黑色各一份，两张 PixelMap 只差墨色。
// 直接画像素而不解码 SVG：宿主拒绝 24x24 以上的图，光栅化的 SVG 会按画布尺寸出图。
async function trayGlyph(ink: number, size: number): Promise<image.PixelMap> {
  const buf: ArrayBuffer = new ArrayBuffer(size * size * 4);
  const view: Uint8Array = new Uint8Array(buf);
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const cov: number = nCoverage(x + 0.5, y + 0.5);
      if (cov <= 0) {
        continue;
      }
      const i: number = (y * size + x) * 4;
      view[i] = ink;
      view[i + 1] = ink;
      view[i + 2] = ink;
      view[i + 3] = Math.round(255 * cov);
    }
  }
  const opts: image.InitializationOptions = {
    editable: false,
    pixelFormat: image.PixelMapFormat.RGBA_8888,
    size: { width: size, height: size }
  };
  return await image.createPixelMap(buf, opts);
}

// 图标是常驻的前提：hideAbility() 要求状态栏已有图标，这一步成功之后关闭按钮才能变成“收进状态栏”。
// 左键不弹面板：quickOperation.abilityName 传空串，宿主改为送 statusBarIconClick 事件到本进程，
// 由主能力直接拉起框选层，点击路径上不出现任何额外的宿主窗口。
export async function initTray(log: TrayLog, ctx: common.UIAbilityContext, hotkey: string,
  onLeftClick: () => void): Promise<boolean> {
  if (added) {
    log('托盘图标已经挂上了，跳过');
    return true;
  }
  try {
    const icons: statusBarManager.StatusBarIcon = {
      white: await trayGlyph(255, GLYPH),
      black: await trayGlyph(0, GLYPH)
    };
    // abilityName 空串＝左键不弹面板，点击以 statusBarIconClick 事件送到本进程。
    // title 和 height 是必填项：title 是面板标题（不弹面板时看不到），height 给 0 会让图标不出现。
    const operation: statusBarManager.QuickOperation = {
      abilityName: '',
      moduleName: MODULE,
      title: '',
      height: 1
    };
    const openAction: statusBarManager.StatusBarMenuAction = {
      abilityName: MAIN_ABILITY,
      moduleName: MODULE
    };
    const openItem: statusBarManager.StatusBarMenuItem = {
      title: '打开主界面',
      menuAction: openAction
    };
    const group: statusBarManager.StatusBarGroupMenu = [openItem];
    const item: statusBarManager.StatusBarItem = {
      icons: icons,
      quickOperation: operation,
      statusBarGroupMenu: [group],
      hoverTips: `年槌糕Shot · 左键或 ${hotkey} 截图`
    };
    statusBarManager.addToStatusBar(ctx, item);
    added = true;
    log('托盘图标已挂上');
    const cb: Callback<emitter.EventData> = (): void => {
      ProbeLog.add('状态栏图标左键（statusBarIconClick）');
      onLeftClick();
    };
    clickCallback = cb;
    statusBarManager.on('statusBarIconClick', cb);
    return true;
  } catch (e) {
    const err = e as BusinessError;
    log(`挂托盘失败 code=${err.code} msg=${err.message}（801=设备不支持状态栏扩展）`);
    return false;
  }
}

export function removeTray(log: TrayLog, ctx: common.UIAbilityContext): void {
  if (!added) {
    log('托盘本来就没挂，remove 跳过');
    return;
  }
  try {
    const cb: Callback<emitter.EventData> | null = clickCallback;
    if (cb !== null) {
      statusBarManager.off('statusBarIconClick', cb);
    }
  } catch (e) {
    const err = e as BusinessError;
    log(`取消 statusBarIconClick 监听失败 code=${err.code} msg=${err.message}`);
  }
  clickCallback = null;
  try {
    statusBarManager.removeFromStatusBar(ctx);
    added = false;
    log('托盘图标已移除');
  } catch (e) {
    const err = e as BusinessError;
    log(`移除托盘失败 code=${err.code} msg=${err.message}`);
  }
}

export function trayAddedNow(): boolean {
  return added;
}
