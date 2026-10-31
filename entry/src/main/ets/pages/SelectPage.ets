import { common, Want } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { ProbeLog } from '../probe/ProbeLog';
import { cropRegionPng, annotatedPng, regionPixels, RegionPixels, disposeShot, copyShot, saveShot,
  captureMapNow, setCaptureMap } from '../common/ShotService';
import { Mark, Box, MARK_CSS, MARK_W_VP, MOSAIC_VP, MASK_ALPHA, NUM_FONT, HEAD_SOLID, HEAD_OPEN, HEAD_BOTH,
  headPoints, arrowBarbs, parseRgb, TEXT_BASE,
  TEXT_LINE_H, wrapText, textMaxEm, markBounds, hitMark, shiftMark } from '../common/MarkService';
import { BUNDLE_NAME, cancelSelect, dropSelectLock, setScrollStopHook } from '../common/ShotFlow';
import { stagePin } from '../common/PinService';
import { ocrFromPng, copyText } from '../common/OcrService';
import { autoDoNow, autoDoLabel, noteBand, lastBandNow, rememberBandNow, guidesNow, cornersNow,
  hotkeyKeyNow, hotkeyModsNow } from '../common/ShotSettings';
import { hotkeyText } from '../probe/Hotkey';
import { grabBand, longPng, resetLong, longSegs, longHeight, longWidth, longDiag, longPreview }
  from '../common/LongShotService';

const KEYCODE_ESCAPE: number = 2070;
// Delete 键（向后删）。KEYCODE_DEL 2055 是退格，不是同一个键。
const KEYCODE_FORWARD_DEL: number = 2071;
// 方向键 2012~2015，字母键 A=2017、C=2019、S=2035、Y=2041、Z=2042，Esc 2070，均取自
// @ohos.multimodalInput.keyCode。
const KEYCODE_DPAD_UP: number = 2012;
const KEYCODE_DPAD_DOWN: number = 2013;
const KEYCODE_DPAD_LEFT: number = 2014;
const KEYCODE_DPAD_RIGHT: number = 2015;
const KEYCODE_A: number = 2017;
const KEYCODE_C: number = 2019;
const KEYCODE_S: number = 2035;
const KEYCODE_Y: number = 2041;
const KEYCODE_Z: number = 2042;
// getModifierKeyState 在本 SDK 的声明里是可选成员，直接调用报 TS2722，因此自己维护左右
// Ctrl、Shift 的按下状态。Ctrl 键值 2072、2073。
const KEYCODE_SHIFT_LEFT: number = 2047;
const KEYCODE_SHIFT_RIGHT: number = 2048;
const KEYCODE_CTRL_LEFT: number = 2072;
const KEYCODE_CTRL_RIGHT: number = 2073;

// 工具条贴着选区就地显示，不另开结果窗；图标在上、说明在下，几何只在 barRect() 里算一次，
// 摆放和“按在条上不算落笔”都读它。
// 1014 = 8 + 8 内边距 + 20 格 × 48 + 19 个间隔 × 2，20 格是当前全部按钮；58 = 8 + 8 + 42 格高。
const BAR_W: number = 1014;
const BAR_H: number = 58;
const BTN_W: number = 48;
const BTN_H: number = 42;
// 图标 24vp 图形、2vp 描边，向下 3vp 间距加 10vp 说明（3 个汉字 30vp，仍在 48vp 格内）。
const ICON_VP: number = 24;
// 提示条停留时长：够读完一句「取词 9 行，已进剪贴板」，又不会留在屏幕上挡画面。
const TOAST_MS: number = 3000;

// 画图工具选中后工具条旁展开一排常用色加一个“更多”，“更多”里是 12 色相 × 5 明度加
// 12 级灰。色板是浮层，inBar() 必须算进去，否则在色板上按下会被当成落笔或重新框选。
// 304 = 8 + 8 内边距 + 9 个 22 宽色块 + 9 个 6 宽间隔 + 36 的“更多”（共 10 个孩子）；
// 38 = 8 + 8 + 22。
const PALETTE_W: number = 304;
const PALETTE_H: number = 38;
// 文字工具多一排字号：4 个 28 宽格子、4 个间距（与“更多”之间也算一个）；
// 440 = 8 + 8 内边距 + 9 × 22 + 4 × 28 + 36 + 13 × 6。
const PALETTE_W_TEXT: number = 440;
// 画图工具多三档线宽（细/中/粗，各 28 宽）：304 + 3 × 28 + 3 × 6 = 406。
const PALETTE_W_DRAW: number = 406;
// 矩形/椭圆再多两档空心/实心（各 36 宽）：406 + 2 × 36 + 2 × 6 = 490。
const PALETTE_W_FILL: number = 490;
// 箭头再多三档头型（实心/开口/双向，各 28 宽）：406 + 3 × 28 + 3 × 6 = 508。
const PALETTE_W_ARROW: number = 508;
const SIZE_W: number = 28;
const FILL_W: number = 36;
const TEXT_SIZES: number[] = [12, 16, 22, 30];
const TEXT_SIZE_DEF: number = 16;
// 线宽档位（vp）。默认为 MARK_W_VP（3），每一笔记下自己落笔时的宽度。
const WIDTHS: number[] = [3, 6, 10];
const WIDTH_NAMES: string[] = ['细', '中', '粗'];
// 箭头头型档位，下标就是 Mark.head（见 MarkService 的 HEAD_*）。
const HEADS: number[] = [HEAD_SOLID, HEAD_OPEN, HEAD_BOTH];
const HEAD_NAMES: string[] = ['实心', '开口', '双向'];
// 序号圆底直径（vp）。数字字号 = 直径 × NUM_FONT，和出图同一套。
const NUM_D_VP: number = 26;
// 选中标注上方那排小按钮：删除 / 上移 / 下移 / 置顶 / 置底，各 52 宽；
// 300 = 8 + 8 内边距 + 5 × 52 + 4 × 6，38 = 8 + 8 + 22。
const SEL_W: number = 300;
const SEL_H: number = 38;
// 选区八个手柄（四角加四边中点）的边长和命中半径。手柄是 8vp 方块，命中共给到 9vp 半宽，
// 这么细的目标鼠标也抓得住。
const HANDLE_VP: number = 8;
const HANDLE_HIT: number = 9;
const HANDLE_DIRS: string[] = ['nw', 'n', 'ne', 'e', 'se', 's', 'sw', 'w'];
// 框最小的边长（vp）：再小就出不了图，也抓不住手柄。
const BAND_MIN: number = 8;
// 就地打字：输入框就是点下去那块地方，无底色无边框，字号和颜色与出图一致。宽度到选区
// 右边（超宽自动折行，不能画出去被裁），高度按折行数算，行距 TEXT_LINE_H；上沿抬 0.2 倍
// 字号，第一行视觉中心与烧进底图的基线（y0 + 0.85 字号）重合。它要算进忽略区（inEditor）。
const TEXT_EDIT_LIFT: number = 0.2;
const TEXT_INPUT_ID: string = 'ngshotTextInput';
// 根 Stack 的 id：grabKeys() 用它 requestFocus 把键盘焦点要过来（见 onPageShow）。
const ROOT_ID: string = 'ngshotSelectRoot';
// 300 = 8 + 8 内边距 + 12 × 20 + 11 × 4；156 = 8 + 8 + 6 × 20 + 5 × 4。
const MORE_W: number = 300;
const MORE_H: number = 156;
const COMMON_COLORS: string[] = ['#FF3B30', '#FF9500', '#FFCC00', '#34C759', '#00C7BE',
  '#007AFF', '#AF52DE', '#000000', '#FFFFFF'];
const COMMON_NAMES: string[] = ['红', '橙', '黄', '绿', '青', '蓝', '紫', '黑', '白'];

function hex2(f: number): string {
  const n: number = Math.round(Math.max(0, Math.min(255, f * 255)));
  const s: string = n.toString(16).toUpperCase();
  return s.length < 2 ? `0${s}` : s;
}

function hsvHex(h: number, s: number, v: number): string {
  const c: number = v * s;
  const hp: number = h / 60;
  const x: number = c * (1 - Math.abs(hp % 2 - 1));
  const o: number = v - c;
  if (hp < 1) {
    return `#${hex2(c + o)}${hex2(x + o)}${hex2(o)}`;
  }
  if (hp < 2) {
    return `#${hex2(x + o)}${hex2(c + o)}${hex2(o)}`;
  }
  if (hp < 3) {
    return `#${hex2(o)}${hex2(c + o)}${hex2(x + o)}`;
  }
  if (hp < 4) {
    return `#${hex2(o)}${hex2(x + o)}${hex2(c + o)}`;
  }
  if (hp < 5) {
    return `#${hex2(x + o)}${hex2(o)}${hex2(c + o)}`;
  }
  return `#${hex2(c + o)}${hex2(o)}${hex2(x + o)}`;
}

// 12 个色相一行，从上到下：淡、浅、原色、深、暗；最后一行是 12 级灰。
function buildMoreColors(): string[][] {
  const tones: number[][] = [[0.32, 1], [0.55, 1], [1, 1], [1, 0.72], [1, 0.45]];
  const rows: string[][] = [];
  for (let t = 0; t < tones.length; t++) {
    const row: string[] = [];
    for (let i = 0; i < 12; i++) {
      row.push(hsvHex(i * 30, tones[t][0], tones[t][1]));
    }
    rows.push(row);
  }
  const gray: string[] = [];
  for (let i = 0; i < 12; i++) {
    const v: number = (255 - i * (255 / 11)) / 255;
    gray.push(`#${hex2(v)}${hex2(v)}${hex2(v)}`);
  }
  rows.push(gray);
  return rows;
}

const MORE_COLORS: string[][] = buildMoreColors();

// 长截图采集面板。PC 上窗口最小宽度 320vp（608px），面板按 320vp 排。
// 采集节拍 300ms：capture 要 200~500ms，实际帧间隔约 550ms；给到 700ms 时一帧能滚过整条
// 选区，两帧没有重叠就只能重锚丢段。
const PANEL_W_VP: number = 320;
const PANEL_H_VP: number = 176;
const SCROLL_TICK_MS: number = 300;
// 收尾时等在途帧归位的上限：一次 capture 要 200~500ms，2 秒足够；再久说明取帧卡住了，
// 按已有结果出图，别把面板留在收尾状态。
const FINISH_WAIT_MS: number = 2000;

interface BarRect {
  x: number;
  y: number;
  w: number;
  h: number;
}

// 全屏框选层：capture() 冻结的快照铺满窗口，在上面拖矩形，所见即截图内容。
// 不用 screenshot.pick()：它在本机会留下僵尸会话。拖框、松手定框弹工具条，Esc 或右键取消。
// 底图直接用 capture 的 PixelMap，PNG 只给导出路径，后台编码，热键到上屏不等它。
// 标注是选区局部 vp 的命令表，导出按 px 栅格化（getPixelMap() 是 vp 尺寸，分辨率减半），文字走 Drawing API，vp 到 px 走 kx/ky。
@Entry
@Component
struct SelectPage {
  @State shot: image.PixelMap | null = null;
  @State areaW: number = 0;
  @State areaH: number = 0;
  @State imgW: number = 0;
  @State imgH: number = 0;
  @State left: number = 0;
  @State top: number = 0;
  @State wide: number = 0;
  @State high: number = 0;
  @State decided: boolean = false;
  @State tool: string = '';
  // 当前工具的颜色，按工具分别记住，默认红；只影响下一笔，已落笔的标注各带自己的颜色。
  @State markColor: string = MARK_CSS;
  @State colorMore: boolean = false;
  // 文字工具：在选区内点一下就地打字，点已有的文字就改它；落笔后是一段普通的 Mark。
  @State textOn: boolean = false;
  @State textDraft: string = '';
  @State textSize: number = TEXT_SIZE_DEF;
  @State hasMarks: boolean = false;
  // 下一笔的线宽/填充（每一笔落笔时自己记下来，改档位不影响已经画好的笔）。
  @State markW: number = MARK_W_VP;
  @State markFill: boolean = false;
  @State markHead: number = HEAD_SOLID;
  @State hasUndo: boolean = false;
  @State hasRedo: boolean = false;
  // 选择工具选中的是命令表里第几笔，-1 表示没选中。
  @State selIndex: number = -1;
  // 取色器的结果条：点它可以复制 HEX。hexCss 单独存一份，之后换颜色也不会改掉已经取到的那次。
  @State hexTip: string = '';
  @State hexCss: string = '';
  // “框选后自动动作”执行中：选区还在出图，但工具条先不画，免得只闪一下。
  @State autoGoing: boolean = false;
  @State scrolling: boolean = false;
  @State scrollDone: boolean = false;
  @State scrollSegs: number = 0;
  @State scrollW: number = 0;
  @State scrollH: number = 0;
  @State scrollMsg: string = '';
  // 一句话提示：贴着工具条显示 TOAST_MS 就自己收，屏幕上不常驻任何东西。
  @State toast: string = '';
  private toastTimer: number = -1;
  @State preview: image.PixelMap | null = null;
  // SelectAbility 发现窗口失去激活、流程还挂着时把这个序号加一，等价于按 Esc 收场。
  @StorageLink('selectAbandon') @Watch('onAbandon') abandonSeq: number = 0;
  private anchorX: number = 0;
  private anchorY: number = 0;
  private drawing: boolean = false;
  private ignoring: boolean = false;
  private working: boolean = false;
  // 选区调整：空字符串是没在拖，move 是整块平移，其余是手柄方向（见 HANDLE_DIRS）。
  private boxMode: string = '';
  // 按下那一刻的 left/top/wide/high，拖动时按“基准 + 位移”重算，不会累积误差。
  private boxBase: number[] = [0, 0, 0, 0];
  private boxGrabX: number = 0;
  private boxGrabY: number = 0;
  // 记忆框选只在这一次进层时套用一次（之后用户自己拖的框不许再被顶掉）。
  private bandApplied: boolean = false;
  // 鼠标中键按过：下一次定框不执行“框选后自动动作”，只影响一次，定框时即清掉。
  private autoSkip: boolean = false;
  // 修饰键状态（见 KEYCODE_CTRL_* / KEYCODE_SHIFT_* 的注释）。失焦时一并清掉，免得粘住。
  private ctrlDown: boolean = false;
  private shiftDown: boolean = false;
  private marks: Mark[] = [];
  // 四个画图工具 + 文字各自的颜色，没挑过就是默认红；只在本次截图里记着。
  private toolColors: Map<string, string> = new Map<string, string>();
  // 文字落点（选区内 vp）。
  private textAt: number[] = [0, 0];
  // 正在改的是命令表里的第几段文字，-1 表示新写一段。改动只在这一段上原地生效，没落笔就不算数。
  private editIndex: number = -1;
  // 按住已有的文字可以拖着挪位置：按下记“抓点离这段字原点的偏移”，拖过 3vp 才算真挪；
  // 松开时没挪动就是“点它改字”，所以按下那一刻不能直接开输入框。
  private textDragIndex: number = -1;
  private textGrabX: number = 0;
  private textGrabY: number = 0;
  private textMoved: boolean = false;
  private textPressMs: number = 0;
  // 鼠标左键是否还按着。合成的触屏 Down/Up 可能落在按下那一刻，用这个区分鼠标拖动和手指拖动。
  private mouseHeld: boolean = false;
  // 上一次按下的时间与位置，用来认出同一物理按下送来的第二份事件（鼠标 Press + 合成 Down）。
  private lastPressMs: number = 0;
  private lastPressX: number = -999;
  private lastPressY: number = -999;
  private draft: Mark | null = null;
  private marking: boolean = false;
  // 撤销/重做各存一份“改动前整份命令表”的快照。命令表很小，几十笔，比给每种操作各写一套
  // 逆操作简单，移动、层级、删除、改字都能统一回退。
  private history: Mark[][] = [];
  private future: Mark[][] = [];
  // 选择工具拖动：按下时记下整笔的副本，移动时按“副本 + 位移”重算，松手才进历史。
  private pickMoving: boolean = false;
  private pickMoved: boolean = false;
  private pickGrabX: number = 0;
  private pickGrabY: number = 0;
  private pickBase: Mark | null = null;
  // 最近一个吃颜色的工具（取色器取到的颜色要还给谁）。
  private lastDrawTool: string = 'rect';
  private base: RegionPixels | null = null;
  private baseLoading: boolean = false;
  private baseTried: boolean = false;
  private scrollTimer: number = -1;
  private scrollBusy: boolean = false;
  // 采集期间选区固定，px 矩形先算好存着（窗口缩成面板后 areaW/areaH 变了，不能再按 vp 反算）。
  private bandPx: number[] = [0, 0, 0, 0];
  private longBytes: ArrayBuffer | null = null;
  // 面板预览的双缓冲：换上新图之后，上一张还要在 Image 里多活一帧才释放。
  private previewPrev: image.PixelMap | null = null;
  private previewBusy: boolean = false;
  private ctx2d: CanvasRenderingContext2D =
    new CanvasRenderingContext2D(new RenderingContextSettings(true));

  private ctx(): common.UIAbilityContext | null {
    const stored: common.UIAbilityContext | undefined =
      AppStorage.get<common.UIAbilityContext>('abilityContext');
    if (stored === undefined) {
      this.say('拿不到宿主 abilityContext，存不了盘');
      return null;
    }
    return stored;
  }

  private say(line: string): void {
    ProbeLog.add(`框选层 ${line}`);
    AppStorage.setOrCreate('selectStatus', line);
    this.toast = line;
    if (this.toastTimer >= 0) {
      clearTimeout(this.toastTimer);
    }
    this.toastTimer = setTimeout((): void => {
      this.toastTimer = -1;
      this.toast = '';
    }, TOAST_MS);
  }

  // 图尺寸和布局区域都就绪才打这行：build 阶段的 onAreaChange 早于图片就绪，否则 kx/ky 没有意义。
  // 这行数是 vp 到 px 映射的依据（本机约 1.900），标注栅格化也按它缩放。
  private logMapping(): void {
    if (this.imgW > 0 && this.imgH > 0 && this.areaW > 0 && this.areaH > 0) {
      ProbeLog.add(`框选层映射：图 ${this.imgW}x${this.imgH}px，区域 ${this.areaW.toFixed(1)}x`
        + `${this.areaH.toFixed(1)}vp → kx=${(this.imgW / this.areaW).toFixed(3)} `
        + `ky=${(this.imgH / this.areaH).toFixed(3)}`);
    }
  }

  aboutToAppear(): void {
    const pm: image.PixelMap | null = captureMapNow();
    if (pm === null) {
      this.say('没有整屏快照，框选层是空的');
      return;
    }
    const meta: image.ImageInfo = pm.getImageInfoSync();
    this.imgW = meta.size.width;
    this.imgH = meta.size.height;
    this.shot = pm;
    ProbeLog.add(`框选层 整屏 ${this.imgW}x${this.imgH}px 直接上屏（没等 PNG 编解码）`);
    this.logMapping();
  }

  aboutToDisappear(): void {
    this.stopScrollTimer();
    if (this.toastTimer >= 0) {
      clearTimeout(this.toastTimer);
      this.toastTimer = -1;
    }
    setScrollStopHook(null);
    const pm: image.PixelMap | null = this.shot;
    if (pm !== null) {
      disposeShot(pm);
      this.shot = null;
    }
    setCaptureMap(null);
    this.base = null;
    this.dropPreview();
  }

  // 页面刚上屏时没有组件持有焦点，键盘事件无人接收，Esc 不响应，点一下或框过一次才正常。
  // 页面显示后把焦点要回根 Stack；文字输入框关闭后焦点随它消失，也要再要一次。
  onPageShow(): void {
    this.grabKeys('页面显示');
    // 系统焦点可能晚一点才到位，800ms 后再要一次组件焦点。
    setTimeout((): void => {
      this.grabKeys('页面显示 +800ms');
    }, 800);
  }

  // 键盘事件只发给焦点节点。requestFocus 按 id 请求，clearFocus 把焦点强制转到页面根容器，
  // 两者都指向根 Stack，都调一遍，任一成功即可。
  private grabKeys(why: string): void {
    setTimeout((): void => {
      if (this.textOn || this.scrolling || this.scrollDone) {
        return;
      }
      let ok: boolean = false;
      try {
        this.getUIContext().getFocusController().requestFocus(ROOT_ID);
        ok = true;
      } catch (e) {
        const err = e as BusinessError;
        ProbeLog.add(`焦点请求失败（${why}）code=${err.code} ${err.message}`);
      }
      try {
        this.getUIContext().getFocusController().clearFocus();
        ok = true;
      } catch (e) {
        const err = e as BusinessError;
        ProbeLog.add(`clearFocus 失败（${why}）code=${err.code}`);
      }
      ProbeLog.add(`焦点${ok ? '已回到键盘层' : '没要到'}（${why}）`);
    }, 60);
  }

  private closeSelf(): void {
    const c: common.UIAbilityContext | undefined =
      AppStorage.get<common.UIAbilityContext>('selectAbilityContext');
    if (c === undefined) {
      this.say('拿不到 selectAbilityContext，关不掉自己');
      return;
    }
    try {
      c.terminateSelf();
    } catch (e) {
      const err = e as BusinessError;
      this.say(`terminateSelf 失败 code=${err.code} msg=${err.message}`);
    }
  }

  private cancel(restore: boolean = true): void {
    if (this.working) {
      return;
    }
    this.stopScrollTimer();
    setScrollStopHook(null);
    this.scrolling = false;
    this.scrollDone = false;
    this.resetBand();
    cancelSelect((line: string): void => {
      ProbeLog.add(line);
    }, restore);
    this.closeSelf();
  }

  // 窗口被别的窗口顶掉后，Esc 和 onPageHide 都到不了这里，流程会一直挂着不放锁。
  // 出图中（working）返回，那条路自己会放锁并关窗。用户是主动切走的，主窗不唤回。
  private onAbandon(): void {
    ProbeLog.add('框选层收到放弃信号，按取消处理（不唤回主窗）');
    this.cancel(false);
  }

  private resetBand(): void {
    this.drawing = false;
    this.marking = false;
    this.colorMore = false;
    this.boxMode = '';
    this.discardMarks();
    this.decided = false;
    this.wide = 0;
    this.high = 0;
  }

  // vp 换算成图上的 px 并夹在图内：desiredRegion 要求区域不超出图片，四舍五入也可能越界。
  private toPxX(vp: number): number {
    const k: number = this.areaW > 0 ? this.imgW / this.areaW : 1;
    return Math.max(0, Math.min(this.imgW, Math.round(vp * k)));
  }

  private toPxY(vp: number): number {
    const k: number = this.areaH > 0 ? this.imgH / this.areaH : 1;
    return Math.max(0, Math.min(this.imgH, Math.round(vp * k)));
  }

  private pxW(): number {
    const x: number = this.toPxX(this.left);
    return Math.min(this.toPxX(this.left + this.wide) - x, this.imgW - x);
  }

  private pxH(): number {
    const y: number = this.toPxY(this.top);
    return Math.min(this.toPxY(this.top + this.high) - y, this.imgH - y);
  }

  // 尺寸条上的字：左上和右下的四角坐标加尺寸。坐标是图上的 px，和保存下来的图对得上。
  private bandLabel(): string {
    const x0: number = this.toPxX(this.left);
    const y0: number = this.toPxY(this.top);
    const size: string = `${this.pxW()}x${this.pxH()} px`;
    if (cornersNow()) {
      return `${x0},${y0} → ${this.toPxX(this.left + this.wide)},${this.toPxY(this.top + this.high)}`
        + ` · ${size}`;
    }
    return `${x0},${y0} · ${size}`;
  }

  // 松手只结束拖动，不定稿：框留在屏幕上并出现工具条，之后由工具条按钮或 Esc、右键推进。
  private decide(): void {
    const w: number = this.pxW();
    const h: number = this.pxH();
    // 框太窄太扁等于没框住：只点了一下没拖、或者拖歪成一条线，都算「不要这次」，直接收场。
    // 触屏没有 Esc 也没有右键，这一处就是唯一的出口。
    if (w < 4 || h < 4) {
      this.cancel();
      return;
    }
    this.decided = true;
    // 记忆框选：定下来就把这个框记到设置里（开关没开时 noteBand 自己什么都不做）。
    noteBand(this.toPxX(this.left), this.toPxY(this.top), this.pxW(), this.pxH(), this.imgW, this.imgH,
      (line: string): void => {
        ProbeLog.add(line);
      });
    // “框选后自动动作”：设置里选了复制/保存/贴图就直接走，默认停在工具条上等；
    // 中键按过则跳过这一次，让用户先标一笔。
    const auto: string = autoDoNow();
    const skip: boolean = this.autoSkip;
    this.autoSkip = false;
    if (!skip && auto !== 'none' && this.marks.length === 0) {
      this.say(`框选好了，按设置直接${autoDoLabel(auto)}`);
      if (auto === 'copy') {
        void this.autoRun('copy');
      } else if (auto === 'save') {
        void this.autoRun('save');
      } else if (auto === 'pin') {
        void this.autoRun('pin');
      }
    }
  }

  // 自动动作期间藏起工具条；失败就把它放回来，选区还留着可以手动重来。
  private async autoRun(kind: 'copy' | 'save' | 'pin'): Promise<void> {
    this.autoGoing = true;
    try {
      await this.act(kind);
    } finally {
      this.autoGoing = false;
    }
  }

  private toolLabel(): string {
    if (this.tool === 'rect') {
      return '矩形';
    }
    if (this.tool === 'ellipse') {
      return '椭圆';
    }
    if (this.tool === 'arrow') {
      return '箭头';
    }
    if (this.tool === 'line') {
      return '线';
    }
    if (this.tool === 'mask') {
      return '遮罩';
    }
    if (this.tool === 'brush') {
      return '画笔';
    }
    if (this.tool === 'text') {
      return '文字';
    }
    if (this.tool === 'num') {
      return '序号';
    }
    if (this.tool === 'pick') {
      return '选择';
    }
    if (this.tool === 'dropper') {
      return '取色';
    }
    if (this.tool === 'mosaic') {
      return '马赛克';
    }
    return '无';
  }

  private pickTool(kind: string): void {
    if (this.working) {
      return;
    }
    const next: string = this.tool === kind ? '' : kind;
    // 切到别的工具（或关掉文字）时，输入框里已经打好的字先落笔。
    if (this.textOn && next !== 'text') {
      this.commitText();
    }
    this.tool = next;
    this.colorMore = false;
    if (this.usesColor()) {
      this.markColor = this.colorOf(this.tool);
      this.lastDrawTool = this.tool;
    }
    if (this.tool !== 'dropper') {
      this.hexTip = '';
      this.hexCss = '';
    }
    if (this.tool !== 'pick') {
      this.selIndex = -1;
      this.pickMoving = false;
      this.pickBase = null;
    }
    if (this.tool === 'mosaic') {
      void this.loadBase();
    }
    if (next === '') {
      this.say('工具已关，选区内拖不会再画');
    } else if (next === 'text') {
      this.say('文字：点一下就地打字，点已有的字可以改，按住它拖着能挪位置');
    } else if (next === 'num') {
      this.say('序号：在选区内点一下落一个编号，按落笔顺序自动加 1');
    } else if (next === 'pick') {
      this.say('选择：点标注选中它，拖着挪位置 · 上方小条删/层级，调色板改它的颜色和线宽');
    } else if (next === 'dropper') {
      this.say('取色：在图上点一下，取到的颜色给当前画图工具用');
    } else {
      this.say(`${this.toolLabel()}：在选区内按住拖，松手落笔`);
    }
  }

  // 画图工具都吃颜色；马赛克盖像素、遮罩压暗，没有颜色可选。文字/序号也吃颜色，换色只影响
  // 下一笔。线是箭头的无头版，线宽和颜色都吃。
  private drawToolOn(): boolean {
    return this.tool === 'rect' || this.tool === 'ellipse' || this.tool === 'arrow'
      || this.tool === 'brush' || this.tool === 'line';
  }

  private usesColor(): boolean {
    return this.drawToolOn() || this.tool === 'text' || this.tool === 'num';
  }

  // 调色板此刻改谁：选择工具选着标注时是那一笔的种类，否则是当前工具，空串表示不摊。
  // 马赛克和遮罩没有颜色可改，选中时也不摊。
  private palKind(): string {
    if (this.tool === 'pick') {
      if (!this.selVisible()) {
        return '';
      }
      const k: string = this.marks[this.selIndex].kind;
      return k === 'mosaic' || k === 'mask' ? '' : k;
    }
    return this.usesColor() ? this.tool : '';
  }

  // 摊不摊线宽：这几种都有线宽（文字走字号、序号走直径、遮罩没有描边）。
  private widthKind(k: string): boolean {
    return k === 'rect' || k === 'ellipse' || k === 'arrow' || k === 'brush' || k === 'line';
  }

  // 调色板按工具摊不同数量的格子：颜色永远有，画图工具多三档线宽，矩形/椭圆再多空心/实心。
  private paletteWidth(): number {
    const k: string = this.palKind();
    if (k === 'text') {
      return PALETTE_W_TEXT;
    }
    if (k === 'rect' || k === 'ellipse') {
      return PALETTE_W_FILL;
    }
    if (k === 'arrow') {
      return PALETTE_W_ARROW;
    }
    if (k === 'brush' || k === 'line') {
      return PALETTE_W_DRAW;
    }
    return PALETTE_W;
  }

  // 选择工具选中的那一笔，没有则 null。改颜色、线宽、填充、头型、字号时都先问它改谁。
  private targetMark(): Mark | null {
    if (this.tool === 'pick' && this.selVisible()) {
      return this.marks[this.selIndex];
    }
    return null;
  }

  private pickW(n: number): void {
    const t: Mark | null = this.targetMark();
    if (t !== null) {
      this.pushHistory();
      t.w = n;
      this.markW = n;
      this.redraw();
      this.say(`选中的${this.kindLabel(t.kind)}换成${WIDTH_NAMES[WIDTHS.indexOf(n)]}线`);
      return;
    }
    this.markW = n;
    this.say(`线宽 ${WIDTH_NAMES[WIDTHS.indexOf(n)]}（${n}vp），下一笔生效`);
  }

  private pickFill(v: boolean): void {
    const t: Mark | null = this.targetMark();
    if (t !== null) {
      this.pushHistory();
      t.fill = v;
      this.markFill = v;
      this.redraw();
      this.say(v ? `选中的${this.kindLabel(t.kind)}改成实心` : `选中的${this.kindLabel(t.kind)}改成空心`);
      return;
    }
    this.markFill = v;
    this.say(v ? '实心填充，下一笔生效' : '只描边，下一笔生效');
  }

  private pickHead(h: number): void {
    const t: Mark | null = this.targetMark();
    if (t !== null) {
      this.pushHistory();
      t.head = h;
      this.markHead = h;
      this.redraw();
      this.say(`选中的箭头换成${HEAD_NAMES[HEADS.indexOf(h)]}头`);
      return;
    }
    this.markHead = h;
    this.say(`箭头头型 ${HEAD_NAMES[HEADS.indexOf(h)]}，下一笔生效`);
  }

  private pickSize(n: number): void {
    const t: Mark | null = this.targetMark();
    if (t !== null) {
      this.pushHistory();
      t.size = n;
      this.textSize = n;
      this.redraw();
      this.say(`选中的${this.kindLabel(t.kind)}字号改成 ${n}vp`);
      return;
    }
    this.textSize = n;
    this.say(this.textOn ? `字号改成 ${n}vp` : `文字字号 ${n}vp，下一段生效`);
  }

  // 记住这个工具的颜色，切走再切回来还是它；其它工具互不影响。
  private pickColor(css: string): void {
    const t: Mark | null = this.targetMark();
    this.markColor = css;
    this.toolColors.set(t === null ? this.tool : t.kind, css);
    this.colorMore = false;
    if (t !== null) {
      this.pushHistory();
      t.color = css;
      this.redraw();
      this.say(`选中的${this.kindLabel(t.kind)}换成 ${css}`);
      return;
    }
    const i: number = COMMON_COLORS.indexOf(css);
    this.say(`${this.toolLabel()}用${i >= 0 ? COMMON_NAMES[i] : css}色，`
      + (this.textOn ? '正在打的这段跟着变' : '下一笔生效'));
  }

  private colorOf(kind: string): string {
    const c: string | undefined = this.toolColors.get(kind);
    return c === undefined ? MARK_CSS : c;
  }

  // “更多”按钮本身就是当前颜色的色卡，不在九个常用色里也能看见当前色；字色按亮度翻黑白，
  // 黄/白底上才不会糊成一片。
  private inkOn(css: string): string {
    const rgb: number[] = parseRgb(css);
    return (rgb[0] * 299 + rgb[1] * 587 + rgb[2] * 114) / 1000 > 150
      ? '#FF101418' : '#FFF2F5F8';
  }

  // 同一个颜色压到半透明：就地打字的占位提示用，压在截图上不抢眼。
  private faint(css: string): string {
    const rgb: number[] = parseRgb(css);
    return `#80${hex2(rgb[0] / 255)}${hex2(rgb[1] / 255)}${hex2(rgb[2] / 255)}`;
  }

  // 工具条每个格子都经 barTap 分发，图标表保持平铺的一串，几何常量也只留一处。
  private barTap(key: string): void {
    // 输入框里还有没落笔的字：先落上，别让保存/复制把它漏掉。
    if (this.textOn) {
      this.commitText();
    }
    if (key === 'undo') {
      this.undo();
      return;
    }
    if (key === 'redo') {
      this.redo();
      return;
    }
    if (key === 'reset') {
      if (!this.working) {
        this.resetBand();
        this.say('选区已清掉，重新拖一个');
      }
      return;
    }
    if (key === 'close') {
      this.cancel();
      return;
    }
    if (key === 'ocr') {
      void this.ocrAct();
      return;
    }
    if (key === 'scroll') {
      void this.startScroll();
      return;
    }
    if (key === 'copy') {
      void this.act('copy');
      return;
    }
    if (key === 'save') {
      void this.act('save');
      return;
    }
    if (key === 'pin') {
      void this.act('pin');
      return;
    }
    this.pickTool(key);
  }

  // 一个格子：24vp 图形加 10vp 中文说明。状态读取放在 builder 内，高亮才能跟着当前选择走，
  // 参数只传不变的字符串。
  @Builder
  barBtn(key: string, label: string, cmd: string) {
    Column({ space: 3 }) {
      // Path 的 commands 单位是 px 不是 vp，密度 1.9 时 24 单位只覆盖约 12.6vp，图形挤在左上角。
      // 给 Shape 一个 px2vp(24) 的视口让它铺满盒子；放大同时放大描边，所以线宽除回密度。
      Shape() {
        Path()
          .commands(cmd)
          .fill('#00000000')
          .stroke('#FFF2F5F8')
          .strokeWidth(2.2 / vp2px(1))
          .strokeLineCap(LineCapStyle.Round)
          .strokeLineJoin(LineJoinStyle.Round)
      }
      .width(ICON_VP)
      .height(ICON_VP)
      .viewPort({ x: 0, y: 0, width: px2vp(ICON_VP), height: px2vp(ICON_VP) })
      Text(label)
        .fontSize(10)
        .fontColor(key === 'copy' || this.tool === key ? '#FFFFFFFF' : '#FFD7DEE7')
        .maxLines(1)
    }
    .width(BTN_W)
    .height(BTN_H)
    .justifyContent(FlexAlign.Center)
    .borderRadius(6)
    .backgroundColor(key === 'copy' ? '#FF2F6C49'
      : (this.tool === key ? '#FF2F6C49' : '#00000000'))
    .opacity((key === 'undo' && !this.hasUndo) || (key === 'redo' && !this.hasRedo) ? 0.4 : 1)
    .onClick(() => {
      this.barTap(key);
    })
  }

  // 一个色块：圆点加选中时的绿圈；当前色不在九个常用色里时，仍显示在“更多”按钮上。
  @Builder
  swatch(css: string, side: number) {
    Stack() {
      Column()
        .width(side - 4)
        .height(side - 4)
        .borderRadius((side - 4) / 2)
        .backgroundColor(css)
        .border({ width: 1, color: '#40FFFFFF' })
      if (this.markColor === css) {
        Column()
          .width(side)
          .height(side)
          .borderRadius(side / 2)
          .border({ width: 2, color: '#FF7FB77E' })
      }
    }
    .width(side)
    .height(side)
    .onClick(() => {
      this.pickColor(css);
    })
  }

  // 文字字号档位：28×22 的小格子，选中的那档是绿底。
  @Builder
  sizeChip(n: number) {
    Text(`${n}`)
      .fontSize(11)
      .fontColor(this.textSize === n ? '#FFFFFFFF' : '#FFD7DEE7')
      .textAlign(TextAlign.Center)
      .width(SIZE_W)
      .height(22)
      .borderRadius(6)
      .backgroundColor(this.textSize === n ? '#FF2F6C49' : '#00000000')
      .border({ width: 1, color: this.textSize === n ? '#FF7FB77E' : '#33FFFFFF' })
      .onClick(() => {
        this.pickSize(n);
      })
  }

  // 线宽档位：细/中/粗（3/6/10vp），只有画图工具才摊出来。
  @Builder
  wChip(n: number) {
    Text(WIDTH_NAMES[WIDTHS.indexOf(n)])
      .fontSize(11)
      .fontColor(this.markW === n ? '#FFFFFFFF' : '#FFD7DEE7')
      .textAlign(TextAlign.Center)
      .width(SIZE_W)
      .height(22)
      .borderRadius(6)
      .backgroundColor(this.markW === n ? '#FF2F6C49' : '#00000000')
      .border({ width: 1, color: this.markW === n ? '#FF7FB77E' : '#33FFFFFF' })
      .onClick(() => {
        this.pickW(n);
      })
  }

  // 空心/实心：只有矩形和椭圆有。
  @Builder
  fillChip(v: boolean) {
    Text(v ? '实心' : '空心')
      .fontSize(11)
      .fontColor(this.markFill === v ? '#FFFFFFFF' : '#FFD7DEE7')
      .textAlign(TextAlign.Center)
      .width(FILL_W)
      .height(22)
      .borderRadius(6)
      .backgroundColor(this.markFill === v ? '#FF2F6C49' : '#00000000')
      .border({ width: 1, color: this.markFill === v ? '#FF7FB77E' : '#33FFFFFF' })
      .onClick(() => {
        this.pickFill(v);
      })
  }

  // 箭头头型：只有箭头工具才摊出来（三档，28 宽，跟线宽一样）。
  @Builder
  headChip(h: number) {
    Text(HEAD_NAMES[HEADS.indexOf(h)])
      .fontSize(11)
      .fontColor(this.markHead === h ? '#FFFFFFFF' : '#FFD7DEE7')
      .textAlign(TextAlign.Center)
      .width(SIZE_W)
      .height(22)
      .borderRadius(6)
      .backgroundColor(this.markHead === h ? '#FF2F6C49' : '#00000000')
      .border({ width: 1, color: this.markHead === h ? '#FF7FB77E' : '#33FFFFFF' })
      .onClick(() => {
        this.pickHead(h);
      })
  }

  // 选中标注后浮在它上方：删除 / 上移 / 下移 / 置顶 / 置底，只对当前选中那一笔有效，跟着选区走。
  // 全部 focusable(false)：点一下按钮就会领走焦点，键盘事件到不了根 Stack，Esc 和 Ctrl+A 失效。
  @Builder
  selBar() {
    Row({ space: 6 }) {
      Button('删除')
        .fontSize(11)
        .height(22)
        .width(52)
        .padding(0)
        .focusable(false)
        .backgroundColor('#FF5A2626')
        .fontColor('#FFF3F5F7')
        .onClick(() => {
          this.deleteSelected();
        })
      Button('上移')
        .fontSize(11)
        .height(22)
        .width(52)
        .padding(0)
        .focusable(false)
        .backgroundColor('#FF2A313A')
        .fontColor('#FFE9EDF2')
        .onClick(() => {
          this.zStep(true);
        })
      Button('下移')
        .fontSize(11)
        .height(22)
        .width(52)
        .padding(0)
        .focusable(false)
        .backgroundColor('#FF2A313A')
        .fontColor('#FFE9EDF2')
        .onClick(() => {
          this.zStep(false);
        })
      Button('置顶')
        .fontSize(11)
        .height(22)
        .width(52)
        .padding(0)
        .focusable(false)
        .backgroundColor('#FF2A313A')
        .fontColor('#FFE9EDF2')
        .onClick(() => {
          this.zOrder(true);
        })
      Button('置底')
        .fontSize(11)
        .height(22)
        .width(52)
        .padding(0)
        .focusable(false)
        .backgroundColor('#FF2A313A')
        .fontColor('#FFE9EDF2')
        .onClick(() => {
          this.zOrder(false);
        })
    }
    .width(SEL_W)
    .height(SEL_H)
    .padding(8)
    .borderRadius(10)
    .backgroundColor('#F2101418')
    .border({ width: 1, color: '#33FFFFFF' })
    .position({ x: this.selRect().x, y: this.selRect().y })
  }

  private inBand(x: number, y: number): boolean {
    return x >= this.left && x <= this.left + this.wide
      && y >= this.top && y <= this.top + this.high;
  }

  private clearCanvas(): void {
    if (this.wide > 0 && this.high > 0) {
      this.ctx2d.clearRect(0, 0, this.wide, this.high);
    }
  }

  private discardMarks(): void {
    this.base = null;
    this.baseTried = false;
    this.draft = null;
    this.textOn = false;
    this.textDraft = '';
    this.editIndex = -1;
    this.textDragIndex = -1;
    this.textMoved = false;
    this.pickMoving = false;
    this.pickMoved = false;
    this.pickBase = null;
    this.selIndex = -1;
    this.hexTip = '';
    this.hexCss = '';
    this.marks = [];
    this.hasMarks = false;
    this.history = [];
    this.future = [];
    this.hasUndo = false;
    this.hasRedo = false;
    this.clearCanvas();
  }

  // 历史：撤销、重做、删除、移动、层级共用一套快照

  private cloneMark(m: Mark): Mark {
    return { kind: m.kind, x0: m.x0, y0: m.y0, x1: m.x1, y1: m.y1, pts: m.pts.slice(0),
      color: m.color, text: m.text, size: m.size, w: m.w, fill: m.fill, head: m.head };
  }

  private cloneMarks(): Mark[] {
    const out: Mark[] = [];
    for (let i = 0; i < this.marks.length; i++) {
      out.push(this.cloneMark(this.marks[i]));
    }
    return out;
  }

  // 任何会改动命令表的操作，改动前先调用一次。快照进历史后重做栈作废，与常见编辑器一致。
  private pushHistory(): void {
    this.history.push(this.cloneMarks());
    if (this.history.length > 50) {
      this.history.shift();
    }
    this.future = [];
    this.hasUndo = true;
    this.hasRedo = false;
  }

  private restore(list: Mark[]): void {
    this.marks = list;
    this.selIndex = -1;
    this.hasMarks = list.length > 0;
    this.hasUndo = this.history.length > 0;
    this.hasRedo = this.future.length > 0;
    this.redraw();
  }

  private undo(): void {
    if (this.working) {
      return;
    }
    const prev: Mark[] | undefined = this.history.pop();
    if (prev === undefined) {
      this.say('没有可撤销的了');
      return;
    }
    this.future.push(this.cloneMarks());
    this.restore(prev);
    this.say(`撤销一步，还剩 ${this.marks.length} 笔`);
  }

  private redo(): void {
    if (this.working) {
      return;
    }
    const next: Mark[] | undefined = this.future.pop();
    if (next === undefined) {
      this.say('没有可重做的了');
      return;
    }
    this.history.push(this.cloneMarks());
    this.restore(next);
    this.say(`重做一步，回到 ${this.marks.length} 笔`);
  }

  private kindLabel(kind: string): string {
    if (kind === 'rect') {
      return '矩形';
    }
    if (kind === 'ellipse') {
      return '椭圆';
    }
    if (kind === 'arrow') {
      return '箭头';
    }
    if (kind === 'brush') {
      return '画笔';
    }
    if (kind === 'text') {
      return '文字';
    }
    if (kind === 'num') {
      return '序号';
    }
    if (kind === 'line') {
      return '线';
    }
    if (kind === 'mask') {
      return '遮罩';
    }
    return '马赛克';
  }

  private deleteSelected(): void {
    if (this.working || this.selIndex < 0 || this.selIndex >= this.marks.length) {
      return;
    }
    this.pushHistory();
    const m: Mark = this.marks[this.selIndex];
    this.marks.splice(this.selIndex, 1);
    this.selIndex = -1;
    this.hasMarks = this.marks.length > 0;
    this.redraw();
    this.say(`删掉一个${this.kindLabel(m.kind)}，撤销能找回来`);
  }

  // 层级：置顶是挪到命令表末尾，后画的压在上面；置底是挪到最前。
  private zOrder(top: boolean): void {
    const i: number = this.selIndex;
    if (this.working || i < 0 || i >= this.marks.length) {
      return;
    }
    if (top ? i === this.marks.length - 1 : i === 0) {
      this.say(top ? '它已经在最上面了' : '它已经在最下面了');
      return;
    }
    this.pushHistory();
    const m: Mark = this.marks[i];
    this.marks.splice(i, 1);
    if (top) {
      this.marks.push(m);
      this.selIndex = this.marks.length - 1;
    } else {
      this.marks.unshift(m);
      this.selIndex = 0;
    }
    this.redraw();
    this.say(top ? `${this.kindLabel(m.kind)}已置顶` : `${this.kindLabel(m.kind)}已置底`);
  }

  // 上移/下移一层：跟相邻那一笔换位置。到顶/到底时说一声，不白按。
  private zStep(up: boolean): void {
    const i: number = this.selIndex;
    if (this.working || i < 0 || i >= this.marks.length) {
      return;
    }
    const j: number = up ? i + 1 : i - 1;
    if (j < 0 || j >= this.marks.length) {
      this.say(up ? '它已经在最上面了' : '它已经在最下面了');
      return;
    }
    this.pushHistory();
    const tmp: Mark = this.marks[i];
    this.marks[i] = this.marks[j];
    this.marks[j] = tmp;
    this.selIndex = j;
    this.redraw();
    this.say(up ? `${this.kindLabel(tmp.kind)}上移一层` : `${this.kindLabel(tmp.kind)}下移一层`);
  }

  // 选择工具：把标注当成可选中的对象

  private markAt(lx: number, ly: number): number {
    for (let i = this.marks.length - 1; i >= 0; i--) {
      if (hitMark(this.marks[i], lx, ly, this.wide)) {
        return i;
      }
    }
    return -1;
  }

  private pickPress(lx: number, ly: number): void {
    const hit: number = this.markAt(lx, ly);
    this.selIndex = hit;
    this.pickMoving = hit >= 0;
    this.pickMoved = false;
    if (hit >= 0) {
      this.pickBase = this.cloneMark(this.marks[hit]);
      this.pickGrabX = lx;
      this.pickGrabY = ly;
      // 调色板显示这一笔的属性（颜色、线宽、空心/实心、头型），改动时高亮落在它当前的值上。
      const m: Mark = this.pickBase;
      this.markColor = m.color;
      if (WIDTHS.indexOf(m.w) >= 0) {
        this.markW = m.w;
        this.markFill = m.fill;
        this.markHead = m.head;
      }
      if (m.kind === 'text') {
        this.textSize = m.size;
      }
      this.say(`选中${this.kindLabel(m.kind)} · 拖着挪位置 · 上方小条改层级/删除 · 调色板改外观`);
    } else {
      this.pickBase = null;
      this.say('点一下标注就能选中它');
    }
    this.redraw();
  }

  private pickDrag(lx: number, ly: number): void {
    const base: Mark | null = this.pickBase;
    const i: number = this.selIndex;
    if (base === null || i < 0 || i >= this.marks.length) {
      return;
    }
    const b: Box = markBounds(base, this.wide);
    const dx: number = Math.max(-b.x0, Math.min(this.wide - b.x1, lx - this.pickGrabX));
    const dy: number = Math.max(-b.y0, Math.min(this.high - b.y1, ly - this.pickGrabY));
    if (!this.pickMoved && Math.abs(dx) + Math.abs(dy) < 2) {
      return;
    }
    if (!this.pickMoved) {
      // 真正开始挪了才进历史：只点一下选中不占一步撤销。
      this.pushHistory();
      this.pickMoved = true;
    }
    const m: Mark = this.cloneMark(base);
    shiftMark(m, dx, dy);
    this.marks[i] = m;
    this.redraw();
  }

  private pickDrop(): void {
    this.pickMoving = false;
    this.pickBase = null;
    if (this.pickMoved) {
      this.say('标注挪好了，撤销能回去');
    }
    this.pickMoved = false;
  }

  // 选区调整：手柄、整块平移、方向键、Ctrl+A。
  // 标注记的是选区内 vp，框一动就按相反方向挪同样多，箭头始终指向图上的同一处。

  private handleCenter(dir: string): number[] {
    const x: number = dir.indexOf('w') >= 0 ? this.left
      : (dir.indexOf('e') >= 0 ? this.left + this.wide : this.left + this.wide / 2);
    const y: number = dir.indexOf('n') >= 0 ? this.top
      : (dir.indexOf('s') >= 0 ? this.top + this.high : this.top + this.high / 2);
    return [x, y];
  }

  // 手柄命中：八个点各自 ±HANDLE_HIT。四角排在列表前面，重叠时优先当角处理。
  private handleAt(x: number, y: number): string {
    for (let i = 0; i < HANDLE_DIRS.length; i++) {
      const dir: string = HANDLE_DIRS[i];
      const c: number[] = this.handleCenter(dir);
      if (Math.abs(x - c[0]) <= HANDLE_HIT && Math.abs(y - c[1]) <= HANDLE_HIT) {
        return dir;
      }
    }
    return '';
  }

  private beginBox(mode: string, x: number, y: number): void {
    this.boxMode = mode;
    this.boxBase = [this.left, this.top, this.wide, this.high];
    this.boxGrabX = x;
    this.boxGrabY = y;
    if (mode === 'move') {
      this.say('拖着挪选区 · 抓手柄改大小 · 方向键微调（Ctrl ×5 / Shift ×10）· Ctrl+A 全选');
    } else {
      this.say('拖着手柄改大小 · 方向键微调 · Ctrl+A 全选');
    }
  }

  // 全部按“按下那一刻的框 + 位移”重算，不累积误差；夹在屏幕内，边长不小于 BAND_MIN。
  private updateBox(x: number, y: number): void {
    const d: string = this.boxMode;
    if (d === '') {
      return;
    }
    const b: number[] = this.boxBase;
    const dx: number = x - this.boxGrabX;
    const dy: number = y - this.boxGrabY;
    let l: number = b[0];
    let t: number = b[1];
    let w: number = b[2];
    let h: number = b[3];
    if (d === 'move') {
      l = Math.max(0, Math.min(this.areaW - w, b[0] + dx));
      t = Math.max(0, Math.min(this.areaH - h, b[1] + dy));
    } else {
      if (d.indexOf('w') >= 0) {
        l = Math.max(0, Math.min(b[0] + b[2] - BAND_MIN, b[0] + dx));
        w = b[0] + b[2] - l;
      }
      if (d.indexOf('e') >= 0) {
        w = Math.max(BAND_MIN, Math.min(this.areaW - b[0], b[2] + dx));
      }
      if (d.indexOf('n') >= 0) {
        t = Math.max(0, Math.min(b[1] + b[3] - BAND_MIN, b[1] + dy));
        h = b[1] + b[3] - t;
      }
      if (d.indexOf('s') >= 0) {
        h = Math.max(BAND_MIN, Math.min(this.areaH - b[1], b[3] + dy));
      }
    }
    this.applyBand(l, t, w, h);
  }

  // 框变了：左/上沿动过就把标注按反方向挪回去；区域一变，马赛克底图作废。
  // Canvas 尺寸在同一帧改，内容会被布局清掉，所以立刻重画一次，下一帧再补一次。
  private applyBand(l: number, t: number, w: number, h: number): void {
    if (l === this.left && t === this.top && w === this.wide && h === this.high) {
      return;
    }
    const dl: number = this.left - l;
    const dt: number = this.top - t;
    if (dl !== 0 || dt !== 0) {
      for (let i = 0; i < this.marks.length; i++) {
        shiftMark(this.marks[i], dl, dt);
      }
    }
    this.base = null;
    this.baseTried = false;
    this.left = l;
    this.top = t;
    this.wide = w;
    this.high = h;
    this.redraw();
    setTimeout((): void => {
      this.redraw();
    }, 30);
  }

  private endBox(): void {
    if (this.boxMode === '') {
      return;
    }
    this.boxMode = '';
    // 拖手柄挪完也记成“这次的框”，下次记忆框选按最后这个走。
    noteBand(this.toPxX(this.left), this.toPxY(this.top), this.pxW(), this.pxH(), this.imgW, this.imgH,
      (line: string): void => {
        ProbeLog.add(line);
      });
    this.say(`选区 ${this.pxW()}x${this.pxH()} px · 左上 ${this.toPxX(this.left)},${this.toPxY(this.top)}`);
  }

  // 方向键微调：选中标注时挪标注，否则挪整个框（没定框时不动）。Ctrl ×5、Shift ×10。
  private nudge(dx: number, dy: number, mult: number): void {
    const t: Mark | null = this.targetMark();
    if (t !== null) {
      this.pushHistory();
      shiftMark(t, dx * mult, dy * mult);
      this.redraw();
      this.say(`标注挪到 ${Math.round(t.x0)},${Math.round(t.y0)}`);
      return;
    }
    if (!this.decided || this.tool !== '' || this.wide <= 0) {
      return;
    }
    const l: number = Math.max(0, Math.min(this.areaW - this.wide, this.left + dx * mult));
    const tp: number = Math.max(0, Math.min(this.areaH - this.high, this.top + dy * mult));
    this.applyBand(l, tp, this.wide, this.high);
  }

  // Ctrl+A：整屏都是选区。标注按 applyBand 的规矩留在原处（它们已经粘在图上）。
  private selectAll(): void {
    if (this.working || this.scrolling || this.scrollDone || this.areaW <= 0 || this.areaH <= 0) {
      return;
    }
    if (this.textOn) {
      this.commitText();
    }
    this.applyBand(0, 0, this.areaW, this.areaH);
    this.decided = true;
    this.say(`全选 ${this.pxW()}x${this.pxH()} px`);
  }

  // 记忆框选：进层后第一次拿到窗口尺寸时套用一次；之后用户自己拖的框不会被顶掉。
  // 按“px / 当时的图尺寸”还原，换了分辨率或窗口大小，框还在原来那块内容上。
  private applyRemembered(): void {
    if (this.bandApplied || this.decided || this.imgW <= 0 || this.imgH <= 0
      || this.areaW <= 0 || this.areaH <= 0) {
      return;
    }
    this.bandApplied = true;
    if (!rememberBandNow()) {
      return;
    }
    const b: number[] = lastBandNow();
    if (b.length < 6) {
      return;
    }
    const kx: number = this.areaW / b[4];
    const ky: number = this.areaH / b[5];
    const l: number = Math.max(0, Math.min(this.areaW - BAND_MIN, b[0] * kx));
    const t: number = Math.max(0, Math.min(this.areaH - BAND_MIN, b[1] * ky));
    const w: number = Math.max(BAND_MIN, Math.min(this.areaW - l, b[2] * kx));
    const h: number = Math.max(BAND_MIN, Math.min(this.areaH - t, b[3] * ky));
    this.left = l;
    this.top = t;
    this.wide = w;
    this.high = h;
    this.decided = true;
    ProbeLog.add(`框选层 记忆框选：上次 ${b[0]},${b[1]} ${b[2]}x${b[3]}px（图 ${b[4]}x${b[5]}）→ 这次 `
      + `${this.toPxX(l)},${this.toPxY(t)} ${this.pxW()}x${this.pxH()}px`);
    this.say('用的是上次的框 · 拖框外面可以重新拖');
  }

  // 修饰键：值来自自己记的状态（onKeyEvent 里跟着左右 Ctrl / Shift 的 Down/Up 走）。
  private modOn(key: string): boolean {
    return key === 'Ctrl' ? this.ctrlDown : this.shiftDown;
  }

  // 底图只解一次：马赛克预览要从真实像素取颗粒色，否则预览和存下来的图对不上；失败也不重试，
  // 否则每帧重绘都会再解一次。
  private async loadBase(): Promise<void> {
    if (this.baseTried || this.baseLoading || this.wide <= 0 || this.high <= 0) {
      return;
    }
    this.baseLoading = true;
    const rp: RegionPixels | null = await regionPixels(this.toPxX(this.left), this.toPxY(this.top),
      this.pxW(), this.pxH(), (line: string): void => {
        ProbeLog.add(line);
      });
    this.baseLoading = false;
    this.baseTried = true;
    if (rp !== null) {
      this.base = rp;
      this.redraw();
    }
  }

  private redraw(): void {
    if (this.wide <= 0 || this.high <= 0) {
      return;
    }
    this.ctx2d.clearRect(0, 0, this.wide, this.high);
    this.drawGuides();
    const d: Mark | null = this.draft;
    const list: Mark[] = d === null ? this.marks : this.marks.concat([d]);
    for (let i = 0; i < list.length; i++) {
      const m: Mark = list[i];
      // 正在就地编辑的文字由输入框绘制，否则会重影，落笔后改由 Canvas 绘制。
      if (this.textOn && i === this.editIndex) {
        continue;
      }
      // 拖拽中的马赛克不逐块绘制，6vp 的块在整屏选区上要上万次 fillRect，会卡，所以只画选框；
      // 松手提交后的整块马赛克走 paint()。
      if (d !== null && m === d && m.kind === 'mosaic') {
        continue;
      }
      this.paint(m);
    }
    if (d !== null && d.kind === 'mosaic') {
      this.paintMosaicFrame(d);
    }
    // 选中的一笔套一圈虚线框，四周留 3vp 余量，细线也能看出选的是谁。白虚线压在黑实线上，
    // 白底黑底都可见，只画白虚线会在浅色背景上消失。
    if (this.selIndex >= 0 && this.selIndex < this.marks.length) {
      const b: Box = markBounds(this.marks[this.selIndex], this.wide);
      const c: CanvasRenderingContext2D = this.ctx2d;
      c.beginPath();
      c.rect(b.x0 - 3, b.y0 - 3, b.x1 - b.x0 + 6, b.y1 - b.y0 + 6);
      c.lineWidth = 2;
      c.strokeStyle = 'rgba(0,0,0,0.75)';
      c.setLineDash([]);
      c.stroke();
      c.lineWidth = 1.5;
      c.strokeStyle = '#FFFFFFFF';
      c.setLineDash([5, 4]);
      c.stroke();
      c.setLineDash([]);
    }
  }

  // 参考线只画在预览 Canvas 上，不进命令表，也就不会烧进截图。三分线在 1/3、2/3，
  // 黄金线在 0.382、0.618。
  private drawGuides(): void {
    const g: string = guidesNow();
    if (g === 'none') {
      return;
    }
    const f1: number = g === 'golden' ? 0.382 : 1 / 3;
    const f2: number = g === 'golden' ? 0.618 : 2 / 3;
    const c: CanvasRenderingContext2D = this.ctx2d;
    c.beginPath();
    c.moveTo(this.wide * f1, 0);
    c.lineTo(this.wide * f1, this.high);
    c.moveTo(this.wide * f2, 0);
    c.lineTo(this.wide * f2, this.high);
    c.moveTo(0, this.high * f1);
    c.lineTo(this.wide, this.high * f1);
    c.moveTo(0, this.high * f2);
    c.lineTo(this.wide, this.high * f2);
    c.lineWidth = 1;
    c.strokeStyle = 'rgba(255,59,48,0.85)';
    c.setLineDash([]);
    c.stroke();
  }

  private paint(m: Mark): void {
    const c: CanvasRenderingContext2D = this.ctx2d;
    const lw: number = m.w > 0 ? m.w : MARK_W_VP;
    c.strokeStyle = m.color;
    c.fillStyle = m.color;
    c.lineWidth = lw;
    c.lineCap = 'round';
    c.lineJoin = 'round';
    if (m.kind === 'mosaic') {
      this.paintMosaic(m);
      return;
    }
    if (m.kind === 'num') {
      // 序号：圆底加白色数字，字号与出图同比例（NUM_FONT），数字居中。
      c.beginPath();
      c.arc(m.x0, m.y0, m.size / 2, 0, Math.PI * 2);
      c.fill();
      c.fillStyle = '#FFFFFFFF';
      c.font = `${Math.max(1, Math.round(m.size * NUM_FONT))}vp sans-serif`;
      c.textAlign = 'center';
      c.textBaseline = 'middle';
      c.fillText(m.text, m.x0, m.y0);
      c.textAlign = 'left';
      c.textBaseline = 'alphabetic';
      c.fillStyle = m.color;
      return;
    }
    if (m.kind === 'text') {
      if (m.text.length > 0) {
        // 字号按 vp 给，官方 Canvas 的 font 示例为“30vp sans-serif”，基线按 0.85 字号的比
        // 例定位，见 MarkService.TEXT_BASE；超宽按 wrapText 折行，行距为 TEXT_LINE_H。
        c.font = `${m.size}vp sans-serif`;
        c.textBaseline = 'alphabetic';
        const rows: string[] = wrapText(m.text, textMaxEm(m.x0, m.size, this.wide));
        for (let i = 0; i < rows.length; i++) {
          if (rows[i].length > 0) {
            c.fillText(rows[i], m.x0, m.y0 + m.size * TEXT_BASE + i * m.size * TEXT_LINE_H);
          }
        }
      }
      return;
    }
    if (m.kind === 'rect') {
      c.beginPath();
      c.rect(Math.min(m.x0, m.x1), Math.min(m.y0, m.y1),
        Math.abs(m.x1 - m.x0), Math.abs(m.y1 - m.y0));
      if (m.fill) {
        c.fill();
      } else {
        c.stroke();
      }
      return;
    }
    if (m.kind === 'ellipse') {
      c.beginPath();
      c.ellipse((m.x0 + m.x1) / 2, (m.y0 + m.y1) / 2,
        Math.abs(m.x1 - m.x0) / 2, Math.abs(m.y1 - m.y0) / 2, 0, 0, Math.PI * 2);
      if (m.fill) {
        c.fill();
      } else {
        c.stroke();
      }
      return;
    }
    if (m.kind === 'arrow') {
      c.beginPath();
      c.moveTo(m.x0, m.y0);
      c.lineTo(m.x1, m.y1);
      c.stroke();
      if (m.head === HEAD_OPEN) {
        // 空心头：两条回折斜边，不封口，比例与实心三角共用（arrowBarbs）。
        const bb: number[] = arrowBarbs(m.x0, m.y0, m.x1, m.y1, lw);
        c.beginPath();
        c.moveTo(m.x1, m.y1);
        c.lineTo(bb[0], bb[1]);
        c.moveTo(m.x1, m.y1);
        c.lineTo(bb[2], bb[3]);
        c.stroke();
      } else {
        const hp: number[] = headPoints(m.x0, m.y0, m.x1, m.y1, lw);
        c.beginPath();
        c.moveTo(hp[0], hp[1]);
        c.lineTo(hp[2], hp[3]);
        c.lineTo(hp[4], hp[5]);
        c.closePath();
        c.fill();
        if (m.head === HEAD_BOTH) {
          const hq: number[] = headPoints(m.x1, m.y1, m.x0, m.y0, lw);
          c.beginPath();
          c.moveTo(hq[0], hq[1]);
          c.lineTo(hq[2], hq[3]);
          c.lineTo(hq[4], hq[5]);
          c.closePath();
          c.fill();
        }
      }
      return;
    }
    if (m.kind === 'line') {
      c.beginPath();
      c.moveTo(m.x0, m.y0);
      c.lineTo(m.x1, m.y1);
      c.stroke();
      return;
    }
    if (m.kind === 'mask') {
      // 半透明黑块：出图按同一比例压暗像素（见 MarkService.maskBox），预览与成品深浅一致。
      c.fillStyle = `rgba(0,0,0,${MASK_ALPHA})`;
      c.fillRect(Math.min(m.x0, m.x1), Math.min(m.y0, m.y1),
        Math.abs(m.x1 - m.x0), Math.abs(m.y1 - m.y0));
      return;
    }
    const p: number[] = m.pts;
    if (p.length < 4) {
      if (p.length === 2) {
        c.beginPath();
        c.arc(p[0], p[1], lw / 2, 0, Math.PI * 2);
        c.fill();
      }
      return;
    }
    c.beginPath();
    c.moveTo(p[0], p[1]);
    for (let i = 2; i + 1 < p.length; i += 2) {
      c.lineTo(p[i], p[i + 1]);
    }
    c.stroke();
  }

  // 拖马赛克时只画这个框，暗罩加虚线，不画块；松手提交后整块马赛克走 paintMosaic。
  private paintMosaicFrame(m: Mark): void {
    const c: CanvasRenderingContext2D = this.ctx2d;
    const x0: number = Math.min(m.x0, m.x1);
    const x1: number = Math.max(m.x0, m.x1);
    const y0: number = Math.min(m.y0, m.y1);
    const y1: number = Math.max(m.y0, m.y1);
    c.fillStyle = 'rgba(0,0,0,0.18)';
    c.fillRect(x0, y0, x1 - x0, y1 - y0);
    c.beginPath();
    c.rect(x0, y0, x1 - x0, y1 - y0);
    c.lineWidth = 3;
    c.strokeStyle = 'rgba(0,0,0,0.55)';
    c.setLineDash([]);
    c.stroke();
    c.lineWidth = 1.5;
    c.strokeStyle = '#FFFFFFFF';
    c.setLineDash([6, 4]);
    c.stroke();
    c.setLineDash([]);
  }

  // 预览里的马赛克按底图像素逐块取色，块大小与出图一致，均为 MOSAIC_VP 见方。
  private paintMosaic(m: Mark): void {
    const c: CanvasRenderingContext2D = this.ctx2d;
    const x0: number = Math.min(m.x0, m.x1);
    const x1: number = Math.max(m.x0, m.x1);
    const y0: number = Math.min(m.y0, m.y1);
    const y1: number = Math.max(m.y0, m.y1);
    const base: RegionPixels | null = this.base;
    if (base === null) {
      c.fillStyle = '#88485050';
      c.fillRect(x0, y0, x1 - x0, y1 - y0);
      void this.loadBase();
      return;
    }
    const sx: number = base.w / this.wide;
    const sy: number = base.h / this.high;
    for (let y = y0; y < y1; y += MOSAIC_VP) {
      for (let x = x0; x < x1; x += MOSAIC_VP) {
        let px: number = Math.round((x + MOSAIC_VP / 2) * sx);
        let py: number = Math.round((y + MOSAIC_VP / 2) * sy);
        px = Math.max(0, Math.min(base.w - 1, px));
        py = Math.max(0, Math.min(base.h - 1, py));
        const o: number = (py * base.w + px) * 4;
        c.fillStyle = `rgb(${base.data[o]},${base.data[o + 1]},${base.data[o + 2]})`;
        c.fillRect(x, y, Math.min(MOSAIC_VP, x1 - x), Math.min(MOSAIC_VP, y1 - y));
      }
    }
  }

  // 序号：点一下落一个编号，取现有序号最大值加 1。删掉中间的号不会重排后面的号，要重排就撤销。
  // 圆心夹在选区内，圆底不会被裁掉一半。
  private placeNum(x: number, y: number): void {
    const lx: number = Math.min(Math.max(x - this.left, 0), this.wide);
    const ly: number = Math.min(Math.max(y - this.top, 0), this.high);
    let max: number = 0;
    for (let i = 0; i < this.marks.length; i++) {
      const m: Mark = this.marks[i];
      if (m.kind !== 'num') {
        continue;
      }
      const n: number = Number.parseInt(m.text, 10);
      if (!Number.isNaN(n) && n > max) {
        max = n;
      }
    }
    const n: number = max + 1;
    const r: number = NUM_D_VP / 2;
    const cx: number = Math.min(Math.max(lx, r), Math.max(r, this.wide - r));
    const cy: number = Math.min(Math.max(ly, r), Math.max(r, this.high - r));
    this.pushHistory();
    this.marks.push({ kind: 'num', x0: cx, y0: cy, x1: cx, y1: cy, pts: [],
      color: this.colorOf('num'), text: `${n}`, size: NUM_D_VP, w: 0, fill: false, head: HEAD_SOLID });
    this.hasMarks = true;
    this.redraw();
    this.say(`序号 ${n}（${this.colorOf('num')}），再点一下接着加`);
  }

  // 取色器：从全屏快照上读一个像素。readPixels 对非 YUV 的 PixelMap 输出 BGRA_8888，
  // 通道顺序是 B、G、R、A。取到后切回上一个画图工具。
  private async pickColorAt(x: number, y: number): Promise<void> {
    const pm: image.PixelMap | null = this.shot;
    if (pm === null) {
      this.say('没有快照，取不了色');
      return;
    }
    const px: number = Math.min(Math.max(this.toPxX(x), 0), Math.max(0, this.imgW - 1));
    const py: number = Math.min(Math.max(this.toPxY(y), 0), Math.max(0, this.imgH - 1));
    const buf: ArrayBuffer = new ArrayBuffer(4);
    const area: image.PositionArea = {
      pixels: buf,
      offset: 0,
      stride: 4,
      region: { size: { width: 1, height: 1 }, x: px, y: py }
    };
    try {
      await pm.readPixels(area);
    } catch (e) {
      const err = e as BusinessError;
      this.say(`取色失败 code=${err.code} msg=${err.message}`);
      return;
    }
    const d: Uint8Array = new Uint8Array(buf);
    const css: string = `#${hex2(d[2] / 255)}${hex2(d[1] / 255)}${hex2(d[0] / 255)}`;
    const target: string = this.lastDrawTool;
    this.toolColors.set(target, css);
    this.markColor = css;
    this.tool = target;
    this.hexTip = `${css} 点这里复制`;
    this.hexCss = css;
    this.say(`取到 ${css}（${px},${py}），已切回${this.kindLabel(target)}，下一笔就用它`);
  }

  private startMark(x: number, y: number): void {
    const lx: number = Math.min(Math.max(x - this.left, 0), this.wide);
    const ly: number = Math.min(Math.max(y - this.top, 0), this.high);
    this.marking = true;
    this.draft = { kind: this.tool, x0: lx, y0: ly, x1: lx, y1: ly, pts: [lx, ly],
      color: this.colorOf(this.tool), text: '', size: 0, w: this.markW, fill: this.markFill,
      head: this.markHead };
    if (this.tool === 'mosaic' && this.base === null) {
      void this.loadBase();
    }
    this.redraw();
  }

  private updateMark(x: number, y: number): void {
    const m: Mark | null = this.draft;
    if (m === null) {
      return;
    }
    const lx: number = Math.min(Math.max(x - this.left, 0), this.wide);
    const ly: number = Math.min(Math.max(y - this.top, 0), this.high);
    m.x1 = lx;
    m.y1 = ly;
    if (m.kind === 'brush') {
      const p: number[] = m.pts;
      const n: number = p.length;
      if (n < 2 || Math.abs(p[n - 2] - lx) + Math.abs(p[n - 1] - ly) >= 2) {
        p.push(lx);
        p.push(ly);
      }
    }
    this.redraw();
  }

  private commitMark(): void {
    const m: Mark | null = this.draft;
    this.draft = null;
    this.marking = false;
    if (m === null) {
      return;
    }
    const dx: number = Math.abs(m.x1 - m.x0);
    const dy: number = Math.abs(m.y1 - m.y0);
    const tiny: boolean = m.kind === 'brush' ? m.pts.length < 4 : (dx < 3 && dy < 3);
    if (tiny) {
      this.redraw();
      this.say('这一笔太小，没用上');
      return;
    }
    this.pushHistory();
    this.marks.push(m);
    this.hasMarks = true;
    this.redraw();
    this.say(`${this.toolLabel()} 第 ${this.marks.length} 笔，撤销退一步`);
  }

  // 文字
  // 文字不走拖动，也不另开面板：在选区内点一下，输入框贴在落点长出来，字号和颜色与烧进底图
  // 的那段字一致。点已有的文字是把它装回输入框接着改，清空后落笔即删除。

  // 命中哪一段文字时从后往前找，后落的盖住先落的。范围框与选中框、拖动共用 markBounds，
  // 上下各留 4vp 余量，折行后的第二行也算在内。
  private textMarkAt(lx: number, ly: number): number {
    for (let i = this.marks.length - 1; i >= 0; i--) {
      const m: Mark = this.marks[i];
      if (m.kind !== 'text' || m.text.length === 0) {
        continue;
      }
      const b: Box = markBounds(m, this.wide);
      if (lx >= b.x0 - 4 && lx <= b.x1 + 6 && ly >= b.y0 - 4 && ly <= b.y1 + 4) {
        return i;
      }
    }
    return -1;
  }

  // 输入框左上角对齐落点 x0、y0。宽度取折行宽度 maxEm × 字号，输入框的换行位置才与预览、出图
  // 一致；高度是折行数 × 行距，但不越出选区下沿，越界的行出图本来也会被裁掉，盒子压到工具条
  // 或色板上还会挡住按钮。
  private editorRect(): BarRect {
    const size: number = this.textSize;
    const maxEm: number = textMaxEm(this.textAt[0], size, this.wide);
    const lineH: number = Math.max(1, Math.round(size * TEXT_LINE_H));
    const rows: number = Math.max(1, wrapText(this.textDraft, maxEm).length);
    const x: number = Math.min(this.left + this.textAt[0], Math.max(0, this.areaW - 8));
    const y: number = Math.max(0, this.top + this.textAt[1] - Math.round(size * TEXT_EDIT_LIFT));
    const room: number = Math.max(lineH, this.top + this.high - y);
    const h: number = Math.max(20, Math.min(lineH * rows, room));
    const w: number = Math.max(size * 2, maxEm * size);
    return { x: x, y: y, w: w, h: h };
  }

  private inEditor(x: number, y: number): boolean {
    return this.textOn && this.inRect(this.editorRect(), x, y);
  }

  private beginText(x: number, y: number): void {
    const lx: number = Math.min(Math.max(x - this.left, 0), this.wide);
    const ly: number = Math.min(Math.max(y - this.top, 0), this.high);
    const hit: number = this.textMarkAt(lx, ly);
    if (hit >= 0) {
      this.editText(hit);
      return;
    }
    this.newText(lx, ly);
  }

  // 按住已有的文字：先记下抓点，拖过阈值才挪；松开时没挪就是点击，走 editText。
  private grabText(hit: number, lx: number, ly: number): void {
    const m: Mark = this.marks[hit];
    this.textDragIndex = hit;
    this.textGrabX = lx - m.x0;
    this.textGrabY = ly - m.y0;
    this.textMoved = false;
    this.textPressMs = Date.now();
    this.say('按住这段字可以拖着挪位置 · 只点不拖是改字');
  }

  private dragText(lx: number, ly: number): void {
    if (this.textDragIndex < 0 || this.textDragIndex >= this.marks.length) {
      return;
    }
    const m: Mark = this.marks[this.textDragIndex];
    const nx: number = Math.min(Math.max(lx - this.textGrabX, 0), this.wide);
    const ny: number = Math.min(Math.max(ly - this.textGrabY, 0), this.high);
    if (!this.textMoved && Math.abs(nx - m.x0) + Math.abs(ny - m.y0) < 3) {
      return;
    }
    if (!this.textMoved) {
      this.pushHistory();
    }
    this.textMoved = true;
    m.x0 = nx;
    m.y0 = ny;
    m.x1 = nx;
    m.y1 = ny;
    this.redraw();
  }

  // 松开：挪过就落位；没挪且按得不久才算点它改字。合成的触屏 Up 也会走这条路径，
  // 用时间门槛与真拖动区分开。
  private dropText(): void {
    const idx: number = this.textDragIndex;
    this.textDragIndex = -1;
    if (idx < 0 || idx >= this.marks.length) {
      return;
    }
    if (this.textMoved) {
      const m: Mark = this.marks[idx];
      this.say(`文字挪到 ${Math.round(m.x0)},${Math.round(m.y0)}`);
      return;
    }
    if (Date.now() - this.textPressMs > 500) {
      return;
    }
    this.editText(idx);
  }

  private editText(hit: number): void {
    const m: Mark = this.marks[hit];
    this.editIndex = hit;
    this.textAt = [m.x0, m.y0];
    this.textDraft = m.text;
    this.textSize = m.size;
    this.toolColors.set('text', m.color);
    this.markColor = m.color;
    this.textOn = true;
    const r: BarRect = this.editorRect();
    ProbeLog.add(`框选层 改第 ${hit + 1} 段文字 @${r.x.toFixed(0)},${r.y.toFixed(0)} `
      + `${r.w}x${r.h}，原文「${m.text}」`);
    this.say('在原来的位置改 · 回车或点外面落笔 · Esc 不改了');
    this.redraw();
    this.focusEditor();
  }

  private newText(lx: number, ly: number): void {
    this.editIndex = -1;
    this.textAt = [lx, ly];
    this.textDraft = '';
    this.textOn = true;
    const r: BarRect = this.editorRect();
    ProbeLog.add(`框选层 就地打字 @${r.x.toFixed(0)},${r.y.toFixed(0)} ${r.w}x${r.h}`);
    this.say('在这里打字 · 回车或点外面落笔 · Esc 不要这段');
    this.redraw();
    this.focusEditor();
  }

  // 输入框刚挂上组件树时还拿不到焦点，稍等片刻再请求；拿不到就让用户点一下框，不额外报警。
  private focusEditor(): void {
    setTimeout((): void => {
      if (!this.textOn) {
        return;
      }
      try {
        this.getUIContext().getFocusController().requestFocus(TEXT_INPUT_ID);
      } catch (e) {
        const err = e as BusinessError;
        ProbeLog.add(`框选层 文字输入框没自动获焦 code=${err.code}，点一下再打字`);
      }
    }, 40);
  }

  private commitText(): void {
    if (!this.textOn) {
      return;
    }
    this.textOn = false;
    this.grabKeys('文字落笔');
    const idx: number = this.editIndex;
    this.editIndex = -1;
    const s: string = this.textDraft.trim();
    this.textDraft = '';
    if (idx >= 0 && idx < this.marks.length) {
      // 改已有的那段：清空即删除，否则原地换文字、字号和颜色。
      if (s.length === 0) {
        this.pushHistory();
        this.marks.splice(idx, 1);
        this.hasMarks = this.marks.length > 0;
        this.redraw();
        this.say('这段文字删掉了');
        return;
      }
      this.pushHistory();
      const m: Mark = this.marks[idx];
      m.text = s;
      m.size = this.textSize;
      m.color = this.colorOf('text');
      this.redraw();
      this.say(`文字已改成「${s.length > 10 ? `${s.substring(0, 10)}…` : s}」`);
      return;
    }
    if (s.length === 0) {
      this.redraw();
      return;
    }
    const m: Mark = { kind: 'text', x0: this.textAt[0], y0: this.textAt[1], x1: this.textAt[0],
      y1: this.textAt[1], pts: [], color: this.colorOf('text'), text: s, size: this.textSize,
      w: 0, fill: false, head: HEAD_SOLID };
    this.pushHistory();
    this.marks.push(m);
    this.hasMarks = true;
    this.redraw();
    this.say(`文字「${s.length > 10 ? `${s.substring(0, 10)}…` : s}」已落笔，撤销退一步`);
  }

  private cancelText(): void {
    if (!this.textOn) {
      return;
    }
    this.textOn = false;
    this.grabKeys('放弃这段文字');
    this.editIndex = -1;
    this.textDraft = '';
    this.redraw();
    this.say('这一段文字不要了');
  }

  // 出图分两条路：没有标注直接裁切，有标注则把命令表按整屏分辨率烧进底图。
  private async cutBytes(): Promise<ArrayBuffer | null> {
    const x: number = this.toPxX(this.left);
    const y: number = this.toPxY(this.top);
    const w: number = this.pxW();
    const h: number = this.pxH();
    const log: (line: string) => void = (line: string): void => {
      ProbeLog.add(line);
    };
    if (this.marks.length === 0) {
      return await cropRegionPng(x, y, w, h, log);
    }
    const kx: number = this.areaW > 0 ? this.imgW / this.areaW : 1;
    const ky: number = this.areaH > 0 ? this.imgH / this.areaH : 1;
    ProbeLog.add(`选区带 ${this.marks.length} 笔标注，按整屏分辨率烧进底图`);
    return await annotatedPng(x, y, w, h, this.marks, kx, ky, log);
  }

  private async act(kind: 'copy' | 'save' | 'pin'): Promise<void> {
    if (this.working || !this.decided) {
      return;
    }
    const x: number = this.toPxX(this.left);
    const y: number = this.toPxY(this.top);
    const w: number = this.pxW();
    const h: number = this.pxH();
    this.working = true;
    this.say('出图中…');
    const bytes: ArrayBuffer | null = await this.cutBytes();
    if (bytes === null) {
      // 失败时保持锁和图层：快照字节还在，可以重拖或重新导出，不必再截一次屏。
      this.working = false;
      this.say('选区没出图成功，选区还在');
      return;
    }
    if (kind === 'pin') {
      // 贴图窗贴着选区：x/y 是图像 px，覆盖层全屏且位于 (0,0)，所以等于屏幕 px。失败时选区留在
      // 屏幕上以便重试。
      stagePin(bytes, w, h, x, y);
      const c: common.UIAbilityContext | null = this.ctx();
      if (c === null) {
        this.working = false;
        return;
      }
      const want: Want = { bundleName: BUNDLE_NAME, abilityName: 'PinAbility' };
      try {
        await c.startAbility(want);
      } catch (e) {
        const err = e as BusinessError;
        this.working = false;
        this.say(`贴图窗没起来 code=${err.code} msg=${err.message}，选区还在`);
        return;
      }
      dropSelectLock((line: string): void => {
        ProbeLog.add(line);
      });
      this.closeSelf();
      return;
    }
    let ok: boolean = false;
    if (kind === 'copy') {
      ok = await copyShot(bytes, (line: string): void => {
        ProbeLog.add(line);
      });
    } else {
      const c: common.UIAbilityContext | null = this.ctx();
      if (c === null) {
        this.working = false;
        return;
      }
      ok = await saveShot(bytes, c, (line: string): void => {
        ProbeLog.add(line);
      });
    }
    if (!ok) {
      this.working = false;
      this.say(kind === 'copy' ? '复制没成功，选区还在' : '保存没成功，选区还在');
      return;
    }
    dropSelectLock((line: string): void => {
      ProbeLog.add(line);
    });
    this.closeSelf();
  }

  // 取词不关层：结果直接进剪贴板，用户还能接着保存/复制/贴图。
  private async ocrAct(): Promise<void> {
    if (this.working || !this.decided) {
      return;
    }
    this.working = true;
    this.say('取词中…');
    const bytes: ArrayBuffer | null = await this.cutBytes();
    if (bytes === null) {
      this.working = false;
      this.say('选区没出图，取不了词');
      return;
    }
    const text: string | null = await ocrFromPng(bytes, (line: string): void => {
      ProbeLog.add(line);
    });
    if (text === null) {
      this.working = false;
      this.say('没认出文字，选区还在');
      return;
    }
    const lines: number = text.split('\n').length;
    const ok: boolean = await copyText(text, (line: string): void => {
      ProbeLog.add(line);
    });
    this.working = false;
    this.say(ok ? `取词 ${lines} 行，已进剪贴板` : `取词 ${lines} 行，但复制没成功`);
  }

  // 长截图（滚动截图）
  // 系统没有第三方可用的滚动出图接口，@ohos.screenshot 只有 pick 和 capture，滚轮注入又要系统
  // 权限，所以滚动由用户手动做，本页按节拍对同一条选区 capture，按行重叠把新内容接上。
  // 采集期间全屏窗必须缩成角落的小面板，铺满屏幕会吃掉滚轮，也会被拍进每一帧。

  private stopScrollTimer(): void {
    if (this.scrollTimer >= 0) {
      clearTimeout(this.scrollTimer);
      this.scrollTimer = -1;
    }
  }

  // 每接上一段就换一张缩小的累积图给面板左下角。旧图留一帧再释放，换 @State 的同一帧里
  // Image 可能还在画它。
  private async refreshPreview(): Promise<void> {
    if (this.previewBusy) {
      return;
    }
    this.previewBusy = true;
    const next: image.PixelMap | null = await longPreview();
    this.previewBusy = false;
    if (next === null) {
      return;
    }
    const old: image.PixelMap | null = this.preview;
    this.preview = next;
    if (this.previewPrev !== null) {
      disposeShot(this.previewPrev);
    }
    this.previewPrev = old;
  }

  private dropPreview(): void {
    const cur: image.PixelMap | null = this.preview;
    if (cur !== null) {
      disposeShot(cur);
      this.preview = null;
    }
    if (this.previewPrev !== null) {
      disposeShot(this.previewPrev);
      this.previewPrev = null;
    }
  }

  // 面板放在哪个角：四个角里挑不压住选区、且离选区中心最远的那个。面板是自家窗口，capture()
  // 会把它一起拍进选区，压上就没法采集。
  private panelOrigin(): number[] | null {
    const pw: number = Math.round(vp2px(PANEL_W_VP));
    const ph: number = Math.round(vp2px(PANEL_H_VP));
    const bx: number = this.bandPx[0];
    const by: number = this.bandPx[1];
    const bw: number = this.bandPx[2];
    const bh: number = this.bandPx[3];
    const cands: number[][] = [[0, 0], [this.imgW - pw, 0],
      [0, this.imgH - ph], [this.imgW - pw, this.imgH - ph]];
    let best: number[] | null = null;
    let bestD: number = -1;
    for (let i = 0; i < cands.length; i++) {
      const px: number = cands[i][0];
      const py: number = cands[i][1];
      if (px < 0 || py < 0) {
        continue;
      }
      if (px < bx + bw && px + pw > bx && py < by + bh && py + ph > by) {
        continue;
      }
      const d: number = Math.abs(px + pw / 2 - (bx + bw / 2)) + Math.abs(py + ph / 2 - (by + bh / 2));
      if (d > bestD) {
        bestD = d;
        best = [px, py];
      }
    }
    return best;
  }

  private scrollWindow(): window.Window | null {
    const win: window.Window | undefined = AppStorage.get<window.Window>('selectWindow');
    if (win === undefined) {
      this.say('拿不到框选窗句柄，长截图开不了');
      return null;
    }
    return win;
  }

  private async toPanel(origin: number[]): Promise<boolean> {
    const win: window.Window | null = this.scrollWindow();
    if (win === null) {
      return false;
    }
    const pw: number = Math.round(vp2px(PANEL_W_VP));
    const ph: number = Math.round(vp2px(PANEL_H_VP));
    try {
      await win.resizeAsync(pw, ph);
      await win.moveWindowToAsync(origin[0], origin[1]);
      ProbeLog.add(`长截图：窗已缩成面板 ${pw}x${ph}px @${origin[0]},${origin[1]}，选区 `
        + `${this.bandPx[2]}x${this.bandPx[3]}px 已让开`);
      return true;
    } catch (e) {
      const err = e as BusinessError;
      this.say(`面板没缩成 code=${err.code} msg=${err.message}`);
      return false;
    }
  }

  private async toFullscreen(): Promise<void> {
    const win: window.Window | null = this.scrollWindow();
    if (win === null) {
      return;
    }
    try {
      await win.resizeAsync(this.imgW, this.imgH);
      await win.moveWindowToAsync(0, 0);
      ProbeLog.add('长截图：窗已铺回全屏，选区和工具条还在');
    } catch (e) {
      const err = e as BusinessError;
      ProbeLog.add(`长截图：铺回全屏失败 code=${err.code} msg=${err.message}`);
    }
  }

  private async startScroll(): Promise<void> {
    if (this.working || !this.decided || this.scrolling || this.scrollDone) {
      return;
    }
    if (this.marks.length > 0) {
      this.say('长截图不叠标注，先撤销或重选');
      return;
    }
    const x: number = this.toPxX(this.left);
    const y: number = this.toPxY(this.top);
    const w: number = this.pxW();
    const h: number = this.pxH();
    if (w < 40 || h < 40) {
      this.say('选区太窄/太矮，长截图接不上，重新拖一条');
      return;
    }
    this.bandPx = [x, y, w, h];
    const origin: number[] | null = this.panelOrigin();
    if (origin === null) {
      this.say('选区快铺满整屏了，四个角都放不下控制面板：把选区缩小一点再长截图');
      return;
    }
    resetLong(w, h);
    this.dropPreview();
    this.longBytes = null;
    this.scrollW = w;
    this.scrollH = h;
    this.scrollSegs = 0;
    this.scrollMsg = '去要截的窗口里往下滚，停一下就自动接上；不想滚就点「再抓一屏」';
    this.scrolling = true;
    this.scrollDone = false;
    if (!await this.toPanel(origin)) {
      this.scrolling = false;
      return;
    }
    setScrollStopHook((): void => {
      void this.finishScroll();
    });
    void this.scrollTick();
  }

  private async scrollTick(): Promise<void> {
    if (!this.scrolling) {
      return;
    }
    if (!this.scrollBusy) {
      this.scrollBusy = true;
      const code: string = await grabBand(this.bandPx[0], this.bandPx[1], this.bandPx[2],
        this.bandPx[3], (line: string): void => {
          ProbeLog.add(line);
        });
      this.scrollBusy = false;
      if (!this.scrolling) {
        return;
      }
      this.applyGrab(code);
    }
    if (this.scrolling) {
      this.scrollTimer = setTimeout((): void => {
        void this.scrollTick();
      }, SCROLL_TICK_MS);
    }
  }

  private async manualGrab(): Promise<void> {
    if (!this.scrolling || this.scrollBusy) {
      return;
    }
    this.scrollBusy = true;
    const code: string = await grabBand(this.bandPx[0], this.bandPx[1], this.bandPx[2],
      this.bandPx[3], (line: string): void => {
        ProbeLog.add(line);
      });
    this.scrollBusy = false;
    if (this.scrolling) {
      this.applyGrab(code);
    }
  }

  private applyGrab(code: string): void {
    this.scrollSegs = longSegs();
    this.scrollH = longHeight();
    if (code === 'first' || code === 'added' || code === 'full') {
      void this.refreshPreview();
    }
    if (code === 'first') {
      this.scrollMsg = '第一屏接上了，继续往下滚';
    } else if (code === 'added') {
      this.scrollMsg = `已拼 ${this.scrollSegs} 屏 · 现在 ${this.scrollW}×${this.scrollH} 像素`;
    } else if (code === 'same') {
      this.scrollMsg = '画面没变化，再往下滚一点';
    } else if (code === 'nomatch') {
      // 判定细节直接摊在面板上，日志里是同一句：最好那一处合上几行、静止位合上几行、与上一帧
      // 同几行。与上一帧相同却对不上说明累积图尾巴不对，差很多说明还在滚动。
      this.scrollMsg = `这一屏没接上：${longDiag()}`;
    } else if (code === 'full') {
      this.scrollMsg = '到长度上限了，自动收尾';
      void this.finishScroll();
    } else {
      this.scrollMsg = '这一屏没抓到（原因在日志里），可以再点一次「再抓一屏」，或点「完成」';
    }
  }

  private async finishScroll(): Promise<void> {
    if (!this.scrolling) {
      return;
    }
    this.stopScrollTimer();
    setScrollStopHook(null);
    // 先把 scrolling 放掉，让在途的那次 tick 收完就退出，它取到的帧照常进拼接器。
    this.scrolling = false;
    const waitUntil: number = Date.now() + FINISH_WAIT_MS;
    while (this.scrollBusy && Date.now() < waitUntil) {
      await new Promise<void>((resolve: () => void) => {
        setTimeout((): void => {
          resolve();
        }, 50);
      });
    }
    // 收尾前再拍一帧：用户可能滚了一段就点完成，最后那一屏还没轮到定时器。画面没动时这一帧
    // 只返回 same，无损。
    this.scrollBusy = true;
    const code: string = await grabBand(this.bandPx[0], this.bandPx[1], this.bandPx[2],
      this.bandPx[3], (line: string): void => {
        ProbeLog.add(line);
      });
    this.scrollBusy = false;
    ProbeLog.add(`长截图收尾：补拍一帧返回 ${code}`);
    const bytes: ArrayBuffer | null = await longPng((line: string): void => {
      ProbeLog.add(line);
    });
    this.scrollDone = true;
    this.scrollSegs = longSegs();
    this.scrollW = longWidth();
    this.scrollH = longHeight();
    this.longBytes = bytes;
    this.scrollMsg = bytes === null ? '长图没编出来，日志里有原因'
      : `拼好了：${this.scrollW}×${this.scrollH} 像素，共 ${this.scrollSegs} 屏`;
    void this.refreshPreview();
  }

  private cancelScroll(): void {
    this.stopScrollTimer();
    setScrollStopHook(null);
    this.scrolling = false;
    this.scrollDone = false;
    this.longBytes = null;
    this.dropPreview();
    void this.toFullscreen();
    this.say('已退出长截图，选区和工具条还在');
  }

  private async longAct(kind: 'copy' | 'save'): Promise<void> {
    const bytes: ArrayBuffer | null = this.longBytes;
    if (bytes === null) {
      this.scrollMsg = '长图字节不在了，出不了';
      return;
    }
    this.scrollMsg = '处理中…';
    let ok: boolean = false;
    if (kind === 'copy') {
      ok = await copyShot(bytes, (line: string): void => {
        ProbeLog.add(line);
      });
    } else {
      const c: common.UIAbilityContext | null = this.ctx();
      if (c === null) {
        this.scrollMsg = '拿不到宿主 context，保存不了';
        return;
      }
      ok = await saveShot(bytes, c, (line: string): void => {
        ProbeLog.add(line);
      });
    }
    if (!ok) {
      this.scrollMsg = kind === 'copy' ? '复制没成功，长图还在，可以再点' : '保存没成功，长图还在，可以再点';
      return;
    }
    dropSelectLock((line: string): void => {
      ProbeLog.add(line);
    });
    this.closeSelf();
  }

  @Builder
  scrollPanel() {
    Row({ space: 8 }) {
      // 左下角的实时预览：累积图按最近邻缩到这块里，接一段长一截。用户不用等出图就能判断拼接
      // 是否正确。
      Column({ space: 4 }) {
        Column() {
          if (this.preview !== null) {
            Image(this.preview)
              .width('100%')
              .height('100%')
              .objectFit(ImageFit.Contain)
              .interpolation(ImageInterpolation.High)
              .draggable(false)
              .copyOption(CopyOptions.None)
          } else {
            Text('等第一屏')
              .fontSize(10)
              .fontColor('#FF6B747D')
          }
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)

        Text(this.scrollSegs > 0 ? `已拼 ${this.scrollSegs} 屏` : '预览')
          .fontSize(10)
          .fontColor('#FF8B949E')
      }
      .width(84)
      .height('100%')
      .padding(6)
      .borderRadius(8)
      .backgroundColor('#FF191F26')
      .border({ width: 1, color: '#33FFFFFF' })

      Column({ space: 5 }) {
        Text(this.scrollDone ? '长图拼好了' : '正在拼长图')
          .fontSize(13)
          .fontColor('#FFE9EDF2')
        Text(`选区 ${this.bandPx[2]}×${this.bandPx[3]} 像素 · 长图 ${this.scrollW}×${this.scrollH} 像素`)
          .fontSize(11)
          .fontColor('#FF9AA4AF')
        Text(this.scrollMsg)
          .fontSize(11)
          .fontColor('#FF7FB77E')
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (!this.scrollDone) {
          Row({ space: 6 }) {
            Button('再抓一屏')
              .fontSize(11)
              .height(30)
              .padding({ left: 2, right: 2 })
              .focusable(false)
              .layoutWeight(1)
              .backgroundColor('#FF2A313A')
              .fontColor('#FFE9EDF2')
              .onClick((): void => {
                void this.manualGrab();
              })
            Button('完成')
              .fontSize(11)
              .height(30)
              .padding({ left: 2, right: 2 })
              .focusable(false)
              .layoutWeight(1)
              .backgroundColor('#FF2F6C49')
              .fontColor('#FFE9EDF2')
              .onClick((): void => {
                void this.finishScroll();
              })
            Button('取消')
              .fontSize(11)
              .height(30)
              .padding({ left: 2, right: 2 })
              .focusable(false)
              .layoutWeight(1)
              .backgroundColor('#FF2A313A')
              .fontColor('#FFE9EDF2')
              .onClick((): void => {
                this.cancelScroll();
              })
          }
          .width('100%')
        } else {
          Row({ space: 6 }) {
            Button('复制')
              .fontSize(11)
              .height(30)
              .padding({ left: 2, right: 2 })
              .focusable(false)
              .layoutWeight(1)
              .backgroundColor('#FF2F6C49')
              .fontColor('#FFE9EDF2')
              .onClick((): void => {
                void this.longAct('copy');
              })
            Button('保存')
              .fontSize(11)
              .height(30)
              .padding({ left: 2, right: 2 })
              .focusable(false)
              .layoutWeight(1)
              .backgroundColor('#FF2A313A')
              .fontColor('#FFE9EDF2')
              .onClick((): void => {
                void this.longAct('save');
              })
            Button('关闭')
              .fontSize(11)
              .height(30)
              .padding({ left: 2, right: 2 })
              .focusable(false)
              .layoutWeight(1)
              .backgroundColor('#FF2A313A')
              .fontColor('#FFE9EDF2')
              .onClick((): void => {
                this.cancel();
              })
          }
          .width('100%')
        }
        Text(`在要截的窗口里往下滚，停一下就自动接上 · 再按一次 ${hotkeyText(hotkeyModsNow(), hotkeyKeyNow())} 结束`)
          .fontSize(10)
          .fontColor('#FF7A828B')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .height('100%')
      .alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .height('100%')
    .padding(10)
    .alignItems(VerticalAlign.Top)
    .backgroundColor('#FF0F1317')
  }

  private barRect(): BarRect {

    let x: number = this.left + this.wide / 2 - BAR_W / 2;
    x = Math.max(8, Math.min(this.areaW - BAR_W - 8, x));
    let y: number = this.top + this.high + 12;
    if (y + BAR_H > this.areaH - 8) {
      y = this.top - BAR_H - 12;
    }
    if (y < 8) {
      y = 8;
    }
    return { x: x, y: y, w: BAR_W, h: BAR_H };
  }

  // 调色板贴着工具条：工具条在选区下方就往下排，在上方就往上排；两头都塞不下就夹进屏幕，
  // 宁可压住选区一角，也不能出屏点不到。
  private bottomLimit(): number {
    return this.areaH - 8;
  }

  private colorRect(): BarRect {
    const b: BarRect = this.barRect();
    let y: number = b.y > this.top ? b.y + b.h + 6 : b.y - PALETTE_H - 6;
    if (y < 8) {
      y = b.y + b.h + 6;
    }
    if (y + PALETTE_H > this.bottomLimit() - 4) {
      y = Math.max(8, b.y - PALETTE_H - 6);
    }
    const x: number = Math.max(8, Math.min(this.areaW - this.paletteWidth() - 8,
      b.x + (b.w - this.paletteWidth()) / 2));
    return { x: x, y: y, w: this.paletteWidth(), h: PALETTE_H };
  }

  // 大色板优先排在调色板外侧；外侧塞不下就翻到内侧，宁可压住选区一角，也别盖住工具条。
  private moreRect(): BarRect {
    const c: BarRect = this.colorRect();
    const down: number = c.y + c.h + 6;
    const up: number = c.y - MORE_H - 6;
    const max: number = this.bottomLimit() - 4 - MORE_H;
    let y: number = c.y > this.top ? down : up;
    if (y < 8 || y > max) {
      y = c.y > this.top ? up : down;
    }
    y = Math.max(8, Math.min(max, y));
    const x: number = Math.max(8, Math.min(this.areaW - MORE_W - 8, c.x + (c.w - MORE_W) / 2));
    return { x: x, y: y, w: MORE_W, h: MORE_H };
  }

  private inBar(px: number, py: number): boolean {
    if (!this.decided) {
      return false;
    }
    if (this.inRect(this.barRect(), px, py)) {
      return true;
    }
    if (this.selVisible() && this.inRect(this.selRect(), px, py)) {
      return true;
    }
    if (this.hexTip !== '' && this.inRect(this.hexRect(), px, py)) {
      return true;
    }
    if (this.palKind() === '') {
      return false;
    }
    if (this.inRect(this.colorRect(), px, py)) {
      return true;
    }
    return this.colorMore && this.inRect(this.moreRect(), px, py);
  }

  private inRect(r: BarRect, px: number, py: number): boolean {
    return px >= r.x && px <= r.x + r.w && py >= r.y && py <= r.y + r.h;
  }

  private selVisible(): boolean {
    return this.decided && this.selIndex >= 0 && this.selIndex < this.marks.length;
  }

  // 选中标注上方那排小按钮的位置：贴着选中笔的上沿，上面塞不下就翻到下方，两头都夹进屏幕。
  private selRect(): BarRect {
    let x: number = this.barRect().x + 20;
    let y: number = this.barRect().y + BAR_H + 6;
    if (this.selIndex >= 0 && this.selIndex < this.marks.length) {
      const mb: Box = markBounds(this.marks[this.selIndex], this.wide);
      x = this.left + mb.x0;
      y = this.top + mb.y0 - SEL_H - 6;
      if (y < 8) {
        y = this.top + mb.y1 + 6;
      }
      x = Math.max(8, Math.min(this.areaW - SEL_W - 8, x));
      y = Math.max(8, Math.min(this.bottomLimit() - SEL_H - 8, y));
    }
    return { x: x, y: y, w: SEL_W, h: SEL_H };
  }

  // 取色结果条：挂在工具条上方一行，点一下复制这个 HEX。
  private hexRect(): BarRect {
    const b: BarRect = this.barRect();
    return { x: b.x, y: Math.max(8, b.y - 32), w: 160, h: 26 };
  }

  // 提示条排在工具条上方，取色条占着那一行就再抬高一格；上方顶到屏幕边就翻到工具条下面。
  private toastY(): number {
    const b: BarRect = this.barRect();
    const y: number = b.y - 34 - (this.hexTip !== '' ? 32 : 0);
    if (y < 8) {
      return Math.min(b.y + BAR_H + 8, this.bottomLimit() - 30);
    }
    return y;
  }

  // Press/Down：只有 Move 之后才画出框，单纯点一下不会留下多余选区。按在工具条或底部提示条上
  // 什么都不做；工具已选且按在选区内则开始落笔；其余位置按下会丢掉当前框和标注，重新拖。
  private pressStart(x: number, y: number): void {
    // 采集面板上按按钮也会送到根 Stack，这个 SDK 上子控件不吞父事件。那时窗口已不在全屏坐标系
    // 里，任何按下都不该起框选。
    if (this.scrolling || this.scrollDone) {
      return;
    }
    // 一次鼠标按下会同时送来 onMouse.Press 和合成的 onTouch.Down，正在落笔时第二个 Down 不能
    // 把这一笔的起点冲掉。
    if (this.marking) {
      return;
    }
    // 文字没有 marking 挡第二份事件：第一份打开了输入框，第二份落点已在框外，会被当成点外面
    // 而空落笔收掉框，表现为输入框只闪一下。所以按同一点、同一瞬间去重，真人第二下要么时间
    // 晚得多，要么位置差得远。
    const now: number = Date.now();
    if (now - this.lastPressMs < 150 && Math.abs(x - this.lastPressX) < 6
      && Math.abs(y - this.lastPressY) < 6) {
      return;
    }
    this.lastPressMs = now;
    this.lastPressX = x;
    this.lastPressY = y;
    // 上一次拖字如果没收到松开（比如松在窗口外），这一次按下就把它作废，不留半截拖动状态。
    this.textDragIndex = -1;
    this.textMoved = false;
    this.ignoring = this.inBar(x, y) || this.inEditor(x, y);
    if (this.ignoring) {
      return;
    }
    // 大色板开着时点外面就是收起，这一下不落笔也不重新框选，与弹层的习惯一致。
    if (this.colorMore) {
      this.colorMore = false;
      return;
    }
    // 输入框开着时点别处就是落笔，这一下同样不干别的，免得想点确认却画出一条线。
    if (this.textOn) {
      this.commitText();
      return;
    }
    // 没选工具时框本身可以动：手柄改大小，按框里整块平移。按框外则丢掉这个框重新拖。
    if (this.decided && this.tool === '') {
      const dir: string = this.handleAt(x, y);
      if (dir !== '') {
        this.beginBox(dir, x, y);
        return;
      }
      if (this.inBand(x, y)) {
        this.beginBox('move', x, y);
        return;
      }
    }
    if (this.decided && this.tool !== '' && this.inBand(x, y)) {
      if (this.tool === 'text') {
        // 按在已有的字上：先只是抓住，拖起来才挪位置；没拖就是点它改字（见 dropText）。
        const lx: number = Math.min(Math.max(x - this.left, 0), this.wide);
        const ly: number = Math.min(Math.max(y - this.top, 0), this.high);
        const hit: number = this.textMarkAt(lx, ly);
        if (hit >= 0) {
          this.grabText(hit, lx, ly);
          return;
        }
        this.beginText(x, y);
        return;
      }
      if (this.tool === 'pick' || this.tool === 'num' || this.tool === 'dropper') {
        const lx: number = Math.min(Math.max(x - this.left, 0), this.wide);
        const ly: number = Math.min(Math.max(y - this.top, 0), this.high);
        if (this.tool === 'pick') {
          this.pickPress(lx, ly);
        } else if (this.tool === 'num') {
          this.placeNum(x, y);
        } else {
          void this.pickColorAt(x, y);
        }
        return;
      }
      this.startMark(x, y);
      return;
    }
    this.discardMarks();
    this.decided = false;
    this.anchorX = x;
    this.anchorY = y;
    this.drawing = true;
  }

  // 拖动中：当前指针是框的对角。
  private updateDrag(x: number, y: number): void {
    const dx: number = Math.min(Math.max(x, 0), this.areaW);
    const dy: number = Math.min(Math.max(y, 0), this.areaH);
    this.left = Math.min(this.anchorX, dx);
    this.top = Math.min(this.anchorY, dy);
    this.wide = Math.abs(dx - this.anchorX);
    this.high = Math.abs(dy - this.anchorY);
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.shot === null) {
        Text('全屏快照解码中…').fontSize(14).fontColor('#FF9AA4AF')
      } else {
        Image(this.shot)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Fill)
          // 橡皮筋必须独占拖动。Image 默认的 copyOption 下，按下再移动会起 ArkUI 系统拖拽，
          // 跟着光标走一张快照缩略图，Move 事件也不再进 onMouse，框只在松手时才出现。
          // 两个开关都关掉，这个拖拽会话就不会起来。
          .draggable(false)
          .copyOption(CopyOptions.None)
      }

      if (this.wide > 0 && this.high > 0) {
        Column()
          .width(this.wide)
          .height(this.high)
          .position({ x: this.left, y: this.top })
          // 拖动时给一层绿蒙版当反馈，定稿后只留边框。标注要按真实颜色判断，20% 的绿洗会让预览
          // 和出图看出两个颜色。
          .backgroundColor(this.decided ? '#00000000' : '#335BB98B')
          .border({ width: 2, color: '#FF5BB98B' })
      }

      // 标注画布：尺寸就是选区，坐标按选区内的 vp 记。挂在选区之上、工具条之下，所以画在选区
      // 里的笔不会被绿色蒙版染色，工具条始终压在最上面。
      if (this.decided && this.wide > 0 && this.high > 0) {
        Canvas(this.ctx2d)
          .width(this.wide)
          .height(this.high)
          .position({ x: this.left, y: this.top })
          .onReady(() => {
            this.redraw();
          })
      }

      // 尺寸和坐标条：拖框时跟着走，定稿后也留在选区上方。四角坐标在设置里可关，关掉只报尺寸。
      if ((this.drawing || (this.decided && !this.autoGoing)) && (this.wide > 0 || this.high > 0)) {
        Text(this.bandLabel())
          .fontSize(11)
          .fontColor('#FFE9EDF2')
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .borderRadius(4)
          .backgroundColor('#CC000000')
          .maxLines(1)
          .position({
            x: Math.max(0, Math.min(this.left, Math.max(0, this.areaW - 200))),
            y: this.top >= 30 ? this.top - 26 : Math.min(this.top + 6, Math.max(0, this.areaH - 26))
          })
      }

      // 八个手柄（四角加四边中点）：只有框已定稿、没选工具时出现，是改大小和挪框的入口。
      if (this.decided && this.tool === '' && !this.autoGoing && !this.scrolling && !this.scrollDone
        && this.wide > 0 && this.high > 0) {
        ForEach(HANDLE_DIRS, (dir: string) => {
          Column()
            .width(HANDLE_VP)
            .height(HANDLE_VP)
            .borderRadius(2)
            .backgroundColor('#FFF3F5F7')
            .border({ width: 1, color: '#99000000' })
            .position({
              x: this.handleCenter(dir)[0] - HANDLE_VP / 2,
              y: this.handleCenter(dir)[1] - HANDLE_VP / 2
            })
        }, (dir: string) => `hdl-${dir}`)
      }

      if (this.decided && !this.autoGoing && this.wide > 0 && this.high > 0) {
        Row({ space: 2 }) {
          this.barBtn('rect', '矩形', 'M2 3.5 L22 3.5 L22 21 L2 21 Z')
          this.barBtn('ellipse', '椭圆', 'M2 12 A10 7.5 0 1 0 22 12 A10 7.5 0 1 0 2 12')
          // “线”：一条斜线，两头各一道短垂线当端点，用来和箭头区分。
          this.barBtn('line', '线', 'M3 21 L21 3 M1.4 19.4 L4.6 22.6 M19.4 1.4 L22.6 4.6')
          this.barBtn('arrow', '箭头', 'M2 22 L22 2 M22 2 L11 2 M22 2 L22 13')
          this.barBtn('brush', '画笔', 'M2 22 L4.5 14.5 L15.5 3.5 L21 9.5 L9.5 19.5 Z M13 6 L18.5 11.5')
          // “文字”：一个大写 T 立在基线上，笔画两端带一点衬线，和别的图标区分开。
          this.barBtn('text', '文字', 'M3 6 L3 3 L21 3 L21 6 M12 3 L12 21 M7.5 21 L16.5 21')
          // “序号”：圆圈里一个 1。
          this.barBtn('num', '序号',
            'M3 12 A9 9 0 1 0 21 12 A9 9 0 1 0 3 12 M12 7.5 L12 16 M9.5 9.5 L12 7.5')
          this.barBtn('mosaic', '马赛克',
            'M2 2 L10.5 2 L10.5 10.5 L2 10.5 Z M13.5 2 L22 2 L22 10.5 L13.5 10.5 Z '
              + 'M2 13.5 L10.5 13.5 L10.5 22 L2 22 Z M13.5 13.5 L22 13.5 L22 22 L13.5 22 Z')
          // “遮罩”：一个方框加几道斜线，排线表示把这块压暗。
          this.barBtn('mask', '遮罩',
            'M3 3 L21 3 L21 21 L3 21 Z M4 16 L16 4 M8 20 L20 8 M3 21 L21 3')
          // “选择”：一只鼠标指针。
          this.barBtn('pick', '选择',
            'M6 3 L6 19 L10.5 14.8 L13.5 21 L16.5 19.6 L13.6 13.6 L19.5 13.6 Z')
          // “取色”：一支吸管，从右上往左下。
          this.barBtn('dropper', '取色',
            'M15 3 L21 9 L18 12 L12 6 Z M12.8 7.2 L4 16 L3 21 L8 20 L16.8 11.2')
          this.barBtn('undo', '撤销', 'M8 3.5 L2 9.5 L8 15.5 M2 9.5 L14.5 9.5 A5.5 5.5 0 0 1 14.5 20.5 L7 20.5')
          this.barBtn('redo', '重做', 'M16 3.5 L22 9.5 L16 15.5 M22 9.5 L9.5 9.5 A5.5 5.5 0 0 1 9.5 20.5 L17 20.5')
          this.barBtn('scroll', '长截图',
            'M3 8 L3 3.5 L8 3.5 M16 3.5 L21 3.5 L21 8 M3 16 L3 20.5 L8 20.5 M16 20.5 L21 20.5 L21 16 '
              + 'M8.5 9 L12 12.5 L15.5 9 M8.5 13.5 L12 17 L15.5 13.5')
          this.barBtn('ocr', '取词',
            'M2 7 L2 2 L7 2 M17 2 L22 2 L22 7 M22 17 L22 22 L17 22 M7 22 L2 22 L2 17 '
              + 'M8 8 L16 8 M12 8 L12 16')
          this.barBtn('pin', '贴图',
            'M8 2 L16 2 M8.5 2 L8.5 10.5 L4 14.5 L20 14.5 L15 10.5 L15 2 M12 14.5 L12 22')
          this.barBtn('save', '保存', 'M12 2 L12 16 M5 8.5 L12 16 L19 8.5 M2 22 L22 22')
          this.barBtn('copy', '复制', 'M7 7 L21 7 L21 21 L7 21 Z M2.5 16 L2.5 2.5 L16.5 2.5')
          this.barBtn('reset', '重选', 'M7 2 L7 17 L22 17 M2 7 L17 7 L17 22')
          this.barBtn('close', '关闭', 'M4.5 4.5 L19.5 19.5 M19.5 4.5 L4.5 19.5')
        }
        .width(BAR_W)
        .height(BAR_H)
        .padding(8)
        .borderRadius(10)
        .backgroundColor('#E6101418')
        .border({ width: 1, color: '#33FFFFFF' })
        .position({ x: this.barRect().x, y: this.barRect().y })
      }

      // 选工具或选中某一笔时摊开调色板：九个常用色加“更多”，那块本身就是当前颜色的色卡。
      // 点“更多”摊开 12 × 5 加 12 级灰的大色板，点色块或点外面收起。编辑选中标注时，格子里
      // 显示的是那一笔的属性，点下去改的也是它。
      if (this.decided && this.wide > 0 && this.high > 0 && this.palKind() !== '') {
        Row({ space: 6 }) {
          ForEach(COMMON_COLORS, (css: string) => {
            this.swatch(css, 22)
          }, (css: string) => css)
          Text(this.colorMore ? '收起' : '更多')
            .fontSize(10)
            .fontColor(this.inkOn(this.markColor))
            .textAlign(TextAlign.Center)
            .width(36)
            .height(22)
            .borderRadius(6)
            .backgroundColor(this.markColor)
            .border({ width: this.colorMore ? 2 : 1, color: this.colorMore ? '#FF7FB77E' : '#66FFFFFF' })
            .onClick(() => {
              this.colorMore = !this.colorMore;
            })
          if (this.palKind() === 'text') {
            ForEach(TEXT_SIZES, (n: number) => {
              this.sizeChip(n)
            }, (n: number) => `${n}`)
          }
          // 线宽三档：能画出线的工具才有，序号的大小跟直径走，文字走字号。
          if (this.widthKind(this.palKind())) {
            ForEach(WIDTHS, (n: number) => {
              this.wChip(n)
            }, (n: number) => `w-${n}`)
          }
          // 空心/实心：只有矩形和椭圆有填充。
          if (this.palKind() === 'rect' || this.palKind() === 'ellipse') {
            this.fillChip(false)
            this.fillChip(true)
          }
          // 箭头头型三档。
          if (this.palKind() === 'arrow') {
            ForEach(HEADS, (h: number) => {
              this.headChip(h)
            }, (h: number) => `h-${h}`)
          }
        }
        .width(this.paletteWidth())
        .height(PALETTE_H)
        .padding(8)
        .borderRadius(10)
        .backgroundColor('#E6101418')
        .border({ width: 1, color: '#33FFFFFF' })
        .position({ x: this.colorRect().x, y: this.colorRect().y })
      }

      if (this.decided && this.wide > 0 && this.high > 0 && this.palKind() !== '' && this.colorMore) {
        Column({ space: 4 }) {
          ForEach(MORE_COLORS, (row: string[]) => {
            Row({ space: 4 }) {
              ForEach(row, (css: string) => {
                this.swatch(css, 20)
              }, (css: string) => css)
            }
          }, (row: string[], ri: number) => `${ri}`)
        }
        .width(MORE_W)
        .height(MORE_H)
        .padding(8)
        .borderRadius(10)
        .backgroundColor('#F2101418')
        .border({ width: 1, color: '#33FFFFFF' })
        .position({ x: this.moreRect().x, y: this.moreRect().y })
      }

      // 取色结果：一行小条，点一下复制这个 HEX。状态栏里的字选不中，复制只能靠它。
      if (this.hexTip !== '') {
        Text(this.hexTip)
          .fontSize(11)
          .fontColor('#FFE9EDF2')
          .textAlign(TextAlign.Center)
          .width(this.hexRect().w)
          .height(this.hexRect().h)
          .borderRadius(6)
          .backgroundColor('#E6101418')
          .border({ width: 1, color: '#33FFFFFF' })
          .position({ x: this.hexRect().x, y: this.hexRect().y })
          .onClick(() => {
            const css: string = this.hexCss;
            void copyText(css, (line: string): void => {
              ProbeLog.add(line);
            });
            this.say(`已复制 ${css}`);
          })
      }

      // 一句话提示：取词、撤销、失败原因这些没有别的出口的话，都从这里说一句，几秒后自己消失。
      // 长截图期间窗口缩成角落面板，判定结果由面板自己显示，这里不再插一句。
      if (this.toast !== '' && !this.scrolling && !this.scrollDone) {
        Row() {
          Text(this.toast)
            .fontSize(11)
            .fontColor('#FFE9EDF2')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 620 })
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .borderRadius(8)
            .backgroundColor('#E6101418')
            .border({ width: 1, color: '#33FFFFFF' })
        }
        .width(BAR_W)
        .justifyContent(FlexAlign.Center)
        .position({ x: this.barRect().x, y: this.toastY() })
      }

      // 选中标注的那排小按钮，跟着选中笔走。
      if (this.selVisible()) {
        this.selBar()
      }

      // 就地打字的输入框：无底色无边框，字号和文字色与出图一致，贴在落点上，打字时看到的就是
      // 出图那段字。按在框里由 inEditor 让路，这个 SDK 上子控件不吞父事件，只能自己算；回车或
      // 点外面落笔。
      if (this.textOn && this.wide > 0 && this.high > 0) {
        TextArea({ text: this.textDraft, placeholder: '输入文字' })
          .id(TEXT_INPUT_ID)
          .width(this.editorRect().w)
          .height(this.editorRect().h)
          .padding(0)
          .backgroundColor('#00000000')
          .borderRadius(0)
          .fontSize(`${this.textSize}vp`)
          .fontColor(this.colorOf('text'))
          .placeholderColor(this.faint(this.colorOf('text')))
          .placeholderFont({ size: `${this.textSize}vp` })
          .caretColor(this.colorOf('text'))
          // 行距和断行规则与出图同一套，wrapText 逐字符贪心等于 BREAK_ALL，打字时看到的就是落笔
          // 后的样子。
          .lineHeight(`${Math.round(this.textSize * TEXT_LINE_H)}vp`)
          .wordBreak(WordBreak.BREAK_ALL)
          .enterKeyType(EnterKeyType.Done)
          .defaultFocus(true)
          .onChange((v: string): void => {
            this.textDraft = v;
          })
          .onSubmit((): void => {
            this.commitText();
          })
          // 焦点在这个框里时 Esc 先落到它身上，由它自己吃掉；否则文本组件吞键，“放弃这一段”
          // 就不起作用。
          .onKeyEvent((ev: KeyEvent): boolean => {
            if (ev.type === KeyType.Down && ev.keyCode === KEYCODE_ESCAPE) {
              this.cancelText();
              return true;
            }
            return false;
          })
          .position({ x: this.editorRect().x, y: this.editorRect().y })
      }

      // 采集面板放在最后一个孩子：它铺满缩小的窗口且不透明，底下那套全屏内容整块被盖住，不用
      // 给每个分支再加模式判断。
      if (this.scrolling || this.scrollDone) {
        this.scrollPanel()
      }
    }
    .width('100%')
    .height('100%')
    // 内容铺到屏幕最顶：底图里那一条系统状态栏必须和屏上真实的那条重合，内容区一旦从状态栏
    // 下沿开始，两条就并排出现了。
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
    .id(ROOT_ID)
    .backgroundColor('#FF000000')
    .focusable(true)
    // 失焦时把修饰键状态清干净：Ctrl 按着时切走、在外面松开，回来不该还当成按着。
    .onBlur(() => {
      this.ctrlDown = false;
      this.shiftDown = false;
    })
    .onAreaChange((_oldValue: Area, newValue: Area): void => {
      const w: number = Number(newValue.width);
      const h: number = Number(newValue.height);
      if (w !== this.areaW || h !== this.areaH) {
        this.areaW = w;
        this.areaH = h;
        this.logMapping();
        // 记忆框选要等窗口尺寸和图尺寸都有了才能按比例摆回去。
        this.applyRemembered();
      }
    })
    .onKeyEvent((ev: KeyEvent): boolean => {
      // 修饰键先自己记账：Down 置位、Up 清位，然后照常放行，不进下面的快捷键判定。
      const kc: number = ev.keyCode;
      if (kc === KEYCODE_CTRL_LEFT || kc === KEYCODE_CTRL_RIGHT) {
        this.ctrlDown = ev.type === KeyType.Down;
        return false;
      }
      if (kc === KEYCODE_SHIFT_LEFT || kc === KEYCODE_SHIFT_RIGHT) {
        this.shiftDown = ev.type === KeyType.Down;
        return false;
      }
      if (ev.type !== KeyType.Down) {
        return false;
      }
      if (ev.keyCode === KEYCODE_ESCAPE) {
        // 先把当时的状态记进日志。Esc 不先收起大色板，提示条上写着“Esc 或右键取消”，就得真的
        // 退出。只有两种情况先办眼前的事：采集途中收尾出图、正在打字先丢草稿。
        ProbeLog.add(`Esc：scrolling=${this.scrolling} textOn=${this.textOn} colorMore=${this.colorMore} working=${this.working}`);
        if (this.scrolling) {
          void this.finishScroll();
        } else if (this.textOn && (this.textDraft !== '' || this.editIndex >= 0)) {
          this.cancelText();
        } else {
          this.cancel();
        }
        return true;
      }
      // 输入框有焦点时，字母键和方向键归它，用于移动光标和选择，页面不抢。
      if (this.textOn) {
        return false;
      }
      // Delete 删掉选择工具选中的那一笔。
      if (ev.keyCode === KEYCODE_FORWARD_DEL) {
        if (this.selIndex >= 0 && this.selIndex < this.marks.length) {
          this.deleteSelected();
          return true;
        }
        return false;
      }
      const ctrl: boolean = this.modOn('Ctrl');
      const shift: boolean = this.modOn('Shift');
      if (ctrl) {
        if (ev.keyCode === KEYCODE_Z) {
          if (shift) {
            this.redo();
          } else {
            this.undo();
          }
          return true;
        }
        if (ev.keyCode === KEYCODE_Y) {
          this.redo();
          return true;
        }
        if (ev.keyCode === KEYCODE_C) {
          if (!this.decided) {
            this.say('还没框选，先拖一个框再复制');
            return true;
          }
          void this.act('copy');
          return true;
        }
        if (ev.keyCode === KEYCODE_S) {
          if (!this.decided) {
            this.say('还没框选，先拖一个框再保存');
            return true;
          }
          void this.act('save');
          return true;
        }
        if (ev.keyCode === KEYCODE_A) {
          this.selectAll();
          return true;
        }
      }
      // 方向键微调：选中标注时挪标注，否则挪整个框。Ctrl ×5、Shift ×10，两个都按时取 ×5。
      const mult: number = ctrl ? 5 : (shift ? 10 : 1);
      if (ev.keyCode === KEYCODE_DPAD_UP) {
        this.nudge(0, -1, mult);
        return true;
      }
      if (ev.keyCode === KEYCODE_DPAD_DOWN) {
        this.nudge(0, 1, mult);
        return true;
      }
      if (ev.keyCode === KEYCODE_DPAD_LEFT) {
        this.nudge(-1, 0, mult);
        return true;
      }
      if (ev.keyCode === KEYCODE_DPAD_RIGHT) {
        this.nudge(1, 0, mult);
        return true;
      }
      return false;
    })
    .onMouse((ev: MouseEvent): void => {
      // 鼠标事件流。左键拖拽给出 Press、Move、Release，Release 带真实的松开点。Move 事件的
      // ev.button 是 MouseButton.None，所以 Left 判断只用于 Press 和 Release。
      if (this.working) {
        return;
      }
      // 采集面板只有按钮，左右键的其余动作都不当成框选层的操作。
      if (this.scrolling || this.scrollDone) {
        return;
      }
      if (ev.action === MouseAction.Press) {
        if (ev.button === MouseButton.Right) {
          if (this.textOn) {
            this.cancelText();
          } else if (this.colorMore) {
            this.colorMore = false;
          } else {
            this.cancel();
          }
        } else if (ev.button === MouseButton.Middle) {
          // 中键表示本次不自动执行。自动动作在松手定框时立刻触发，因此中键要在松手前按下，
          // 拖着框时按最顺手；在工具条上按则记给下一个框。
          this.autoSkip = true;
          const a: string = autoDoNow();
          this.say(a === 'none' ? '这次框完不自动执行，会停在工具条上'
            : `这次框完不自动${autoDoLabel(a)}，会停在工具条上`);
        } else if (ev.button === MouseButton.Left) {
          this.mouseHeld = true;
          this.pressStart(ev.x, ev.y);
        }
      } else if (ev.action === MouseAction.Move && this.marking) {
        this.updateMark(ev.x, ev.y);
      } else if (ev.action === MouseAction.Move && this.boxMode !== '') {
        this.updateBox(ev.x, ev.y);
      } else if (ev.action === MouseAction.Move && this.pickMoving) {
        this.pickDrag(ev.x - this.left, ev.y - this.top);
      } else if (ev.action === MouseAction.Move && this.textDragIndex >= 0) {
        this.dragText(ev.x - this.left, ev.y - this.top);
      } else if (ev.action === MouseAction.Move && this.drawing && !this.ignoring) {
        this.updateDrag(ev.x, ev.y);
      } else if (ev.action === MouseAction.Release && ev.button === MouseButton.Left) {
        this.mouseHeld = false;
        if (this.marking) {
          this.updateMark(ev.x, ev.y);
          this.commitMark();
        } else if (this.boxMode !== '') {
          this.updateBox(ev.x, ev.y);
          this.endBox();
        } else if (this.pickMoving) {
          this.pickDrag(ev.x - this.left, ev.y - this.top);
          this.pickDrop();
        } else if (this.textDragIndex >= 0) {
          this.dragText(ev.x - this.left, ev.y - this.top);
          this.dropText();
        } else if (this.drawing && !this.ignoring) {
          this.drawing = false;
          this.updateDrag(ev.x, ev.y);
          this.decide();
        }
      }
    })
    .onTouch((ev: TouchEvent): void => {
      // 触摸事件流，结构与鼠标一致：Down 记锚点，Move 收窄，Up 定框。鼠标拖拽时这条流只在按下
      // 点附近给出类似点击的 Down、Up，那时 mouse Release 已跑完并清掉 drawing，后续分支会挡掉。
      // 不从 Up 点反推矩形：合成的 Up 报的是按下位置，会在 decide() 之前把框压扁。
      if (this.working) {
        return;
      }
      const pts: TouchObject[] = ev.changedTouches.length > 0 ? ev.changedTouches : ev.touches;
      if (pts.length === 0) {
        return;
      }
      const x: number = pts[0].x;
      const y: number = pts[0].y;
      if (ev.type === TouchType.Down) {
        this.pressStart(x, y);
      } else if (this.marking) {
        if (ev.type === TouchType.Move) {
          this.updateMark(x, y);
        } else if (ev.type === TouchType.Up) {
          this.updateMark(x, y);
          this.commitMark();
        }
      } else if (this.pickMoving && !this.mouseHeld) {
        if (ev.type === TouchType.Move) {
          this.pickDrag(x - this.left, y - this.top);
        } else if (ev.type === TouchType.Up) {
          this.pickDrag(x - this.left, y - this.top);
          this.pickDrop();
        }
      } else if (this.textDragIndex >= 0 && !this.mouseHeld) {
        if (ev.type === TouchType.Move) {
          this.dragText(x - this.left, y - this.top);
        } else if (ev.type === TouchType.Up) {
          this.dragText(x - this.left, y - this.top);
          this.dropText();
        }
      } else if (this.boxMode !== '' && !this.mouseHeld) {
        if (ev.type === TouchType.Move) {
          this.updateBox(x, y);
        } else if (ev.type === TouchType.Up) {
          this.updateBox(x, y);
          this.endBox();
        }
      } else if (this.ignoring) {
        return;
      } else if (ev.type === TouchType.Move && this.drawing) {
        this.updateDrag(x, y);
      } else if (ev.type === TouchType.Up && this.drawing) {
        this.drawing = false;
        this.decide();
      }
    })
  }
}
