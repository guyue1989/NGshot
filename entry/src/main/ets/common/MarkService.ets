import { image } from '@kit.ImageKit';
import { drawing, common2D } from '@kit.ArkGraphics2D';

// 标注命令表与像素光栅器。
//
// 预览走 ArkUI Canvas（vp，跟手），出图走这里（px）：Canvas 的 getPixelMap 单位是 vp，3120px 的屏
// 导出来只有 1642px 宽，截图工具不能接受这个分辨率，所以出图自己按 px 扫底图像素。
// 两边共用同一套形状参数和每笔自己的颜色，看到的与存下来的一致。
//
// 文字要排版，像素扫不出来：预览仍用 Canvas 的 fillText，出图改用 Drawing 的 Canvas 绑在 PixelMap
// 上画，坐标同为 px，drawTextBlob 的 (x, y) 是基线左端点。命令表存选区内部的 vp 坐标，与选区
// 在屏幕上的位置无关，重选和撤销都不必换算。
export interface Mark {
  kind: string;
  x0: number;
  y0: number;
  x1: number;
  y1: number;
  pts: number[];
  // '#RRGGBB'，颜色随每一笔保存，换色不影响已画好的笔。
  color: string;
  // 文字标注用：内容与字号（vp）。序号（kind 为 'num'）的 text 是数字，size 是圆直径。
  // 其它形状为空串 / 0，像素光栅器遇到 text 直接跳过。
  text: string;
  size: number;
  // 线宽（vp），0 表示用 MARK_W_VP；矩形和椭圆可选实心（fill）。
  w: number;
  fill: boolean;
  // 箭头头型，见 HEAD_*；其它形状固定 0。
  head: number;
}

export const MARK_CSS: string = '#FF3B30';
export const MARK_W_VP: number = 3;
// 序号：圆底直径取每笔的 size，数字字号为直径的 NUM_FONT，基线抬 NUM_BASE 个字号让墨迹中心落在
// 圆心，与预览的 textAlign/Baseline=center 对齐。
export const NUM_FONT: number = 0.58;
export const NUM_BASE: number = 0.36;
// 马赛克块边长（vp）。6vp 在本机约合 11px，能盖住文字又保留底下内容的轮廓；12vp 颗粒过粗。
export const MOSAIC_VP: number = 6;
// 遮罩不透明度：0.55 能压住内容，底下的字仍看得出轮廓，0.66 以上接近涂黑。
// 预览用 rgba(0,0,0,MASK_ALPHA)，出图按同一比例压暗像素，两边深浅一致。
export const MASK_ALPHA: number = 0.55;
const ARROW_HEAD: number = 4;
const ARROW_HALF: number = 0.42;
// 箭头头型：实心三角（默认）、空心两撇、双向（两头都是实心三角）。
export const HEAD_SOLID: number = 0;
export const HEAD_OPEN: number = 1;
export const HEAD_BOTH: number = 2;
// 基线在文字框顶部往下 TEXT_BASE 个字号处。ArkUI Canvas 与 Drawing 都按 alphabetic 基线画，
// 共用这个比例落点才一致；不用 FontMetrics，其字段名未在文档中确认。
export const TEXT_BASE: number = 0.85;
// 行距（字号的倍数）：折行后第二行基线等于上一行加字号乘 1.4。预览、就地输入框、出图三处同值，
// 否则落笔前后行距会跳。
export const TEXT_LINE_H: number = 1.4;
const DEF_R: number = 255;
const DEF_G: number = 59;
const DEF_B: number = 48;

// 画布用 CSS 串，出图用 0~255。接受 '#RRGGBB' 和带 alpha 的 '#AARRGGBB'，alpha 忽略，
// 标注始终不透明。
function hexDigit(c: string): number {
  const n: number = c.charCodeAt(0);
  if (n >= 48 && n <= 57) {
    return n - 48;
  }
  if (n >= 65 && n <= 70) {
    return n - 55;
  }
  if (n >= 97 && n <= 102) {
    return n - 87;
  }
  return -1;
}

function hexPair(s: string, i: number): number {
  const hi: number = hexDigit(s.charAt(i));
  const lo: number = hexDigit(s.charAt(i + 1));
  return hi < 0 || lo < 0 ? -1 : hi * 16 + lo;
}

export function parseRgb(css: string): number[] {
  let s: string = css.charAt(0) === '#' ? css.substring(1) : css;
  if (s.length === 8) {
    s = s.substring(2);
  }
  if (s.length !== 6) {
    return [DEF_R, DEF_G, DEF_B];
  }
  const r: number = hexPair(s, 0);
  const g: number = hexPair(s, 2);
  const b: number = hexPair(s, 4);
  if (r < 0 || g < 0 || b < 0) {
    return [DEF_R, DEF_G, DEF_B];
  }
  return [r, g, b];
}

// 箭头三角形：尖端 (x1, y1)，底边落在尖端回退 sw*ARROW_HEAD 处。返回尖端与两个底边点。
export function headPoints(x0: number, y0: number, x1: number, y1: number, sw: number): number[] {
  const dx: number = x1 - x0;
  const dy: number = y1 - y0;
  const len: number = Math.sqrt(dx * dx + dy * dy);
  if (len < 0.001) {
    return [x1, y1, x1, y1, x1, y1];
  }
  const ux: number = dx / len;
  const uy: number = dy / len;
  const hl: number = Math.max(sw * ARROW_HEAD, 6);
  const hw: number = hl * ARROW_HALF;
  const bx: number = x1 - ux * hl;
  const by: number = y1 - uy * hl;
  return [x1, y1, bx + uy * hw, by - ux * hw, bx - uy * hw, by + ux * hw];
}

// 空心箭头的两条回折斜边，尖端固定在 (x1, y1)，不封口。
// 返回两个端点，与 headPoints 共用长度和宽度比例，三种头型大小一致。
export function arrowBarbs(x0: number, y0: number, x1: number, y1: number, sw: number): number[] {
  const dx: number = x1 - x0;
  const dy: number = y1 - y0;
  const len: number = Math.sqrt(dx * dx + dy * dy);
  if (len < 0.001) {
    return [x1, y1, x1, y1];
  }
  const ux: number = dx / len;
  const uy: number = dy / len;
  const hl: number = Math.max(sw * ARROW_HEAD, 6);
  const hw: number = hl * ARROW_HALF;
  const bx: number = x1 - ux * hl;
  const by: number = y1 - uy * hl;
  return [bx + uy * hw, by - ux * hw, bx - uy * hw, by + ux * hw];
}

export function rasterize(data: Uint8Array, w: number, h: number, marks: Mark[],
  kx: number, ky: number): void {
  const k: number = (kx + ky) / 2;
  for (let i = 0; i < marks.length; i++) {
    const m: Mark = marks[i];
    if (m.kind === 'text') {
      // 文字不在这条路上画，需要排版，见 drawTexts。
      continue;
    }
    if (m.kind === 'num') {
      // 序号由实心圆底加白色数字组成。圆底是纯色，先在这里铺上；数字等 PixelMap 建好后再由
      // drawTexts 画在最上层。
      const cr: number = Math.max(1, m.size * k / 2);
      const ccx: number = m.x0 * kx;
      const ccy: number = m.y0 * ky;
      fillEllipse(data, w, h, ccx - cr, ccy - cr, ccx + cr, ccy + cr, parseRgb(m.color));
      continue;
    }
    if (m.kind === 'mosaic') {
      mosaicize(data, w, h, m, kx, ky);
      continue;
    }
    const rgb: number[] = parseRgb(m.color);
    const sw: number = Math.max(1, (m.w > 0 ? m.w : MARK_W_VP) * k);
    if (m.kind === 'rect') {
      const ax: number = m.x0 * kx;
      const ay: number = m.y0 * ky;
      const bx: number = m.x1 * kx;
      const by: number = m.y1 * ky;
      if (m.fill) {
        fillBox(data, w, h, ax, ay, bx, by, rgb);
      } else {
        strokeSeg(data, w, h, ax, ay, bx, ay, sw, rgb);
        strokeSeg(data, w, h, bx, ay, bx, by, sw, rgb);
        strokeSeg(data, w, h, bx, by, ax, by, sw, rgb);
        strokeSeg(data, w, h, ax, by, ax, ay, sw, rgb);
      }
    } else if (m.kind === 'ellipse') {
      if (m.fill) {
        fillEllipse(data, w, h, m.x0 * kx, m.y0 * ky, m.x1 * kx, m.y1 * ky, rgb);
      } else {
        strokeEllipse(data, w, h, m.x0 * kx, m.y0 * ky, m.x1 * kx, m.y1 * ky, sw, rgb);
      }
    } else if (m.kind === 'arrow') {
      const ax: number = m.x0 * kx;
      const ay: number = m.y0 * ky;
      const bx: number = m.x1 * kx;
      const by: number = m.y1 * ky;
      strokeSeg(data, w, h, ax, ay, bx, by, sw, rgb);
      if (m.head === HEAD_OPEN) {
        // 空心头：两条回折斜边，不封口也不填。
        const bb: number[] = arrowBarbs(ax, ay, bx, by, sw);
        strokeSeg(data, w, h, bx, by, bb[0], bb[1], sw, rgb);
        strokeSeg(data, w, h, bx, by, bb[2], bb[3], sw, rgb);
      } else {
        const hp: number[] = headPoints(ax, ay, bx, by, sw);
        fillTri(data, w, h, hp[0], hp[1], hp[2], hp[3], hp[4], hp[5], rgb);
        if (m.head === HEAD_BOTH) {
          const hq: number[] = headPoints(bx, by, ax, ay, sw);
          fillTri(data, w, h, hq[0], hq[1], hq[2], hq[3], hq[4], hq[5], rgb);
        }
      }
    } else if (m.kind === 'line') {
      // 直线：和箭头同一根圆头线段，只是不带箭头。
      strokeSeg(data, w, h, m.x0 * kx, m.y0 * ky, m.x1 * kx, m.y1 * ky, sw, rgb);
    } else if (m.kind === 'mask') {
      // 遮罩压暗底图：不叠颜色，直接把像素乘 (1 - alpha)，所以下层内容变成灰而不是被涂成纯黑。
      maskBox(data, w, h, m.x0 * kx, m.y0 * ky, m.x1 * kx, m.y1 * ky);
    } else {
      const p: number[] = m.pts;
      if (p.length === 2) {
        strokeSeg(data, w, h, p[0] * kx, p[1] * ky, p[0] * kx, p[1] * ky, sw, rgb);
      } else {
        for (let j = 0; j + 3 < p.length; j += 2) {
          strokeSeg(data, w, h, p[j] * kx, p[j + 1] * ky, p[j + 2] * kx, p[j + 3] * ky, sw, rgb);
        }
      }
    }
  }
}

export function hasText(marks: Mark[]): boolean {
  for (let i = 0; i < marks.length; i++) {
    const m: Mark = marks[i];
    if ((m.kind === 'text' || m.kind === 'num') && m.text.length > 0) {
      return true;
    }
  }
  return false;
}

// 选区内 vp 坐标系的包围盒（x0<=x1, y0<=y1）。选中框、拖动、命中判定、外移夹取共用这一份定义，
// 预览和出图对同一笔的范围判断才一致。
export interface Box {
  x0: number;
  y0: number;
  x1: number;
  y1: number;
}

// 一行能放几个字号（em）：落点到选区右边，右侧留半个字，避免最后一个字被选区边切掉。
// 预览（vp）、就地输入框、出图（px）共用这套算法，折行位置才一致。
export function textMaxEm(x0: number, size: number, bandW: number): number {
  return Math.max(1, (bandW - x0 - size * 0.5) / size);
}

export function markBounds(m: Mark, bandW: number): Box {
  if (m.kind === 'text') {
    const rows: string[] = wrapText(m.text, textMaxEm(m.x0, m.size, bandW));
    let em: number = 0;
    for (let i = 0; i < rows.length; i++) {
      em = Math.max(em, emWidth(rows[i]));
    }
    const w: number = Math.max(em * m.size, m.size * 0.6);
    const h: number = Math.max(1, rows.length) * m.size * TEXT_LINE_H;
    return { x0: m.x0, y0: m.y0, x1: m.x0 + w, y1: m.y0 + h };
  }
  if (m.kind === 'num') {
    const r: number = m.size / 2;
    return { x0: m.x0 - r, y0: m.y0 - r, x1: m.x0 + r, y1: m.y0 + r };
  }
  const hw: number = (m.w > 0 ? m.w : MARK_W_VP) / 2;
  if (m.kind === 'brush' && m.pts.length >= 2) {
    let x0: number = m.pts[0];
    let x1: number = m.pts[0];
    let y0: number = m.pts[1];
    let y1: number = m.pts[1];
    for (let i = 2; i + 1 < m.pts.length; i += 2) {
      x0 = Math.min(x0, m.pts[i]);
      x1 = Math.max(x1, m.pts[i]);
      y0 = Math.min(y0, m.pts[i + 1]);
      y1 = Math.max(y1, m.pts[i + 1]);
    }
    return { x0: x0 - hw, y0: y0 - hw, x1: x1 + hw, y1: y1 + hw };
  }
  return { x0: Math.min(m.x0, m.x1) - hw, y0: Math.min(m.y0, m.y1) - hw,
    x1: Math.max(m.x0, m.x1) + hw, y1: Math.max(m.y0, m.y1) + hw };
}

// 点是否落在这一笔上，含 4vp 余量。所有形状按包围盒判定：细线做精确距离太挑，重叠时取最上面一笔。
export function hitMark(m: Mark, lx: number, ly: number, bandW: number): boolean {
  const b: Box = markBounds(m, bandW);
  return lx >= b.x0 - 4 && lx <= b.x1 + 4 && ly >= b.y0 - 4 && ly <= b.y1 + 4;
}

// 整笔平移（x0/y0/x1/y1 和折线点一起挪）。文字/序号只动原点，其余几何跟着走。
export function shiftMark(m: Mark, dx: number, dy: number): void {
  m.x0 += dx;
  m.y0 += dy;
  m.x1 += dx;
  m.y1 += dy;
  for (let i = 0; i + 1 < m.pts.length; i += 2) {
    m.pts[i] += dx;
    m.pts[i + 1] += dy;
  }
}

// 一个字符占几个字号宽：全角为 1，半角按类别估，数字 0.56、m/w/M/W 0.85、大写 0.66、小写 0.54、
// 标点 0.33、空格 0.32。折行、点选命中、输入框高度都用这一套；预览按 vp、出图按 px，两边算出的
// 每行 em 数相同，同一段文字落在同一处折行。
export function charEm(code: number): number {
  if (code === 32) {
    return 0.32;
  }
  if (code >= 0x2E80) {
    return 1;
  }
  if (code >= 48 && code <= 57) {
    return 0.56;
  }
  if (code === 109 || code === 119 || code === 77 || code === 87) {
    return 0.85;
  }
  if (code >= 65 && code <= 90) {
    return 0.66;
  }
  if (code >= 97 && code <= 122) {
    return 0.54;
  }
  return 0.33;
}

export function emWidth(s: string): number {
  let w: number = 0;
  for (let i = 0; i < s.length; i++) {
    w += charEm(s.charCodeAt(i));
  }
  return w;
}

// 按估宽把文字折成多行，maxEm 是每行允许的宽度（em，即几个字号），'\n' 为硬换行。
// 逐字符贪心，与 TextArea 的 WordBreak.BREAK_ALL 一致：中英文都能在任意字符处断开。
export function wrapText(text: string, maxEm: number): string[] {
  const rows: string[] = [];
  const hard: string[] = text.split('\n');
  for (let h = 0; h < hard.length; h++) {
    const line: string = hard[h];
    let cur: string = '';
    let curEm: number = 0;
    for (let i = 0; i < line.length; i++) {
      const em: number = charEm(line.charCodeAt(i));
      if (cur.length > 0 && curEm + em > maxEm) {
        rows.push(cur);
        cur = '';
        curEm = 0;
      }
      cur += line.charAt(i);
      curEm += em;
    }
    rows.push(cur);
  }
  return rows;
}

// 文字画在已烧好形状的 PixelMap 上：Drawing 的 Canvas 直接绑 PixelMap，坐标是物理 px。
// 基线左端点由 drawTextBlob 的 (x, y) 给出，y 要再加 0.85 个字号，与预览同口径。
// 调用方须保证这张 PixelMap 是 editable 的。bandW 是选区带宽（px），文字到右边就折行，否则会被裁掉。
// 返回画上去的段数。
export function drawTexts(pm: image.PixelMap, marks: Mark[], kx: number, ky: number,
  bandW: number): number {
  const canvas: drawing.Canvas = new drawing.Canvas(pm);
  const font: drawing.Font = new drawing.Font();
  const brush: drawing.Brush = new drawing.Brush();
  let drawn: number = 0;
  for (let i = 0; i < marks.length; i++) {
    const m: Mark = marks[i];
    if (m.kind === 'num') {
      if (m.text.length === 0) {
        continue;
      }
      // 序号：白字压在铺好的圆底正中。字号为直径乘 NUM_FONT，基线抬 NUM_BASE 个字号，
      // 数字的墨迹中心才落在圆心，与预览的 textAlign/Baseline=center 对齐。
      const fpx: number = Math.max(1, Math.round(m.size * NUM_FONT * kx));
      font.setSize(fpx);
      const white: common2D.Color = { alpha: 255, red: 255, green: 255, blue: 255 };
      brush.setColor(white);
      canvas.attachBrush(brush);
      const tw: number = emWidth(m.text) * fpx;
      const nb: drawing.TextBlob =
        drawing.TextBlob.makeFromString(m.text, font, drawing.TextEncoding.TEXT_ENCODING_UTF8);
      canvas.drawTextBlob(nb, m.x0 * kx - tw / 2, m.y0 * ky + fpx * NUM_BASE);
      canvas.detachBrush();
      drawn++;
      continue;
    }
    if (m.kind !== 'text' || m.text.length === 0) {
      continue;
    }
    const rgb: number[] = parseRgb(m.color);
    const col: common2D.Color = { alpha: 255, red: rgb[0], green: rgb[1], blue: rgb[2] };
    const px: number = Math.max(1, Math.round(m.size * kx));
    const left: number = m.x0 * kx;
    // 右边留半个字，最后一个字才不会贴着选区边被切一半。
    const maxEm: number = textMaxEm(m.x0, m.size, bandW / kx);
    const rows: string[] = wrapText(m.text, maxEm);
    font.setSize(px);
    brush.setColor(col);
    canvas.attachBrush(brush);
    for (let r = 0; r < rows.length; r++) {
      if (rows[r].length === 0) {
        continue;
      }
      const blob: drawing.TextBlob =
        drawing.TextBlob.makeFromString(rows[r], font, drawing.TextEncoding.TEXT_ENCODING_UTF8);
      canvas.drawTextBlob(blob, left, m.y0 * ky + px * TEXT_BASE + r * px * TEXT_LINE_H);
    }
    canvas.detachBrush();
    drawn++;
  }
  return drawn;
}

function clamp01(v: number): number {
  if (v <= 0) {
    return 0;
  }
  return v >= 1 ? 1 : v;
}

function distSeg(px: number, py: number, ax: number, ay: number, bx: number, by: number): number {
  const dx: number = bx - ax;
  const dy: number = by - ay;
  const len2: number = dx * dx + dy * dy;
  let t: number = 0;
  if (len2 > 0.000001) {
    t = ((px - ax) * dx + (py - ay) * dy) / len2;
    t = t < 0 ? 0 : (t > 1 ? 1 : t);
  }
  const cx: number = ax + t * dx;
  const cy: number = ay + t * dy;
  return Math.sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy));
}

function blend(data: Uint8Array, o: number, cov: number, rgb: number[]): void {
  const a: number = clamp01(cov);
  if (a <= 0) {
    return;
  }
  const k: number = 1 - a;
  data[o] = Math.round(rgb[0] * a + data[o] * k);
  data[o + 1] = Math.round(rgb[1] * a + data[o + 1] * k);
  data[o + 2] = Math.round(rgb[2] * a + data[o + 2] * k);
  data[o + 3] = 255;
}

// 圆头线段：像素到线段的距离小于半宽就算满覆盖，边缘 1px 做线性抗锯齿。
function strokeSeg(data: Uint8Array, w: number, h: number, ax: number, ay: number,
  bx: number, by: number, sw: number, rgb: number[]): void {
  const r: number = sw / 2;
  const minX: number = Math.max(0, Math.floor(Math.min(ax, bx) - r - 1));
  const maxX: number = Math.min(w - 1, Math.ceil(Math.max(ax, bx) + r + 1));
  const minY: number = Math.max(0, Math.floor(Math.min(ay, by) - r - 1));
  const maxY: number = Math.min(h - 1, Math.ceil(Math.max(ay, by) + r + 1));
  for (let y = minY; y <= maxY; y++) {
    const py: number = y + 0.5;
    for (let x = minX; x <= maxX; x++) {
      const px: number = x + 0.5;
      const cov: number = r + 0.5 - distSeg(px, py, ax, ay, bx, by);
      if (cov > 0) {
        blend(data, (y * w + x) * 4, cov, rgb);
      }
    }
  }
}

// 椭圆描边：|q-1| / |grad q| 可近似像素到椭圆的距离，q = sqrt(((x-cx)/rx)^2 + ((y-cy)/ry)^2)，
// 只扫描椭圆外接框。
function strokeEllipse(data: Uint8Array, w: number, h: number, ax: number, ay: number,
  bx: number, by: number, sw: number, rgb: number[]): void {
  const cx: number = (ax + bx) / 2;
  const cy: number = (ay + by) / 2;
  const rx: number = Math.abs(bx - ax) / 2;
  const ry: number = Math.abs(by - ay) / 2;
  if (rx < 0.5 || ry < 0.5) {
    strokeSeg(data, w, h, ax, ay, bx, by, sw, rgb);
    return;
  }
  const r: number = sw / 2;
  const minX: number = Math.max(0, Math.floor(cx - rx - r - 1));
  const maxX: number = Math.min(w - 1, Math.ceil(cx + rx + r + 1));
  const minY: number = Math.max(0, Math.floor(cy - ry - r - 1));
  const maxY: number = Math.min(h - 1, Math.ceil(cy + ry + r + 1));
  for (let y = minY; y <= maxY; y++) {
    const dy: number = (y + 0.5 - cy) / ry;
    for (let x = minX; x <= maxX; x++) {
      const dx: number = (x + 0.5 - cx) / rx;
      const q: number = Math.sqrt(dx * dx + dy * dy);
      if (q < 0.0001) {
        continue;
      }
      const gx: number = dx / rx / q;
      const gy: number = dy / ry / q;
      const g: number = Math.sqrt(gx * gx + gy * gy);
      if (g < 0.000001) {
        continue;
      }
      const cov: number = r + 0.5 - Math.abs(q - 1) / g;
      if (cov > 0) {
        blend(data, (y * w + x) * 4, cov, rgb);
      }
    }
  }
}

// 实心矩形：像素中心到四条边的距离取最小当覆盖率，边缘 1px 线性过渡。
function fillBox(data: Uint8Array, w: number, h: number, ax: number, ay: number,
  bx: number, by: number, rgb: number[]): void {
  const x0: number = Math.min(ax, bx);
  const x1: number = Math.max(ax, bx);
  const y0: number = Math.min(ay, by);
  const y1: number = Math.max(ay, by);
  const minX: number = Math.max(0, Math.floor(x0 - 1));
  const maxX: number = Math.min(w - 1, Math.ceil(x1 + 1));
  const minY: number = Math.max(0, Math.floor(y0 - 1));
  const maxY: number = Math.min(h - 1, Math.ceil(y1 + 1));
  for (let y = minY; y <= maxY; y++) {
    const py: number = y + 0.5;
    const covY: number = Math.min(py - y0, y1 - py);
    for (let x = minX; x <= maxX; x++) {
      const px: number = x + 0.5;
      const cov: number = Math.min(covY, Math.min(px - x0, x1 - px)) + 0.5;
      if (cov > 0) {
        blend(data, (y * w + x) * 4, cov, rgb);
      }
    }
  }
}

// 遮罩：框内像素乘 (1 - MASK_ALPHA) 压暗，边缘 1px 线性过渡，覆盖率算法与 fillBox 相同。
// 上面 blend() 盖的是不透明色，这里要乘系数，所以单独实现。
function maskBox(data: Uint8Array, w: number, h: number, ax: number, ay: number,
  bx: number, by: number): void {
  const x0: number = Math.min(ax, bx);
  const x1: number = Math.max(ax, bx);
  const y0: number = Math.min(ay, by);
  const y1: number = Math.max(ay, by);
  const minX: number = Math.max(0, Math.floor(x0 - 1));
  const maxX: number = Math.min(w - 1, Math.ceil(x1 + 1));
  const minY: number = Math.max(0, Math.floor(y0 - 1));
  const maxY: number = Math.min(h - 1, Math.ceil(y1 + 1));
  for (let y = minY; y <= maxY; y++) {
    const py: number = y + 0.5;
    const covY: number = Math.min(py - y0, y1 - py);
    for (let x = minX; x <= maxX; x++) {
      const px: number = x + 0.5;
      const cov: number = clamp01(Math.min(covY, Math.min(px - x0, x1 - px)) + 0.5);
      if (cov <= 0) {
        continue;
      }
      const k: number = 1 - cov * MASK_ALPHA;
      const o: number = (y * w + x) * 4;
      data[o] = Math.round(data[o] * k);
      data[o + 1] = Math.round(data[o + 1] * k);
      data[o + 2] = Math.round(data[o + 2] * k);
      data[o + 3] = 255;
    }
  }
}

// 实心椭圆：与 strokeEllipse 同一套 q / |grad q|，覆盖率换成离边界的内向距离。
function fillEllipse(data: Uint8Array, w: number, h: number, ax: number, ay: number,
  bx: number, by: number, rgb: number[]): void {
  const cx: number = (ax + bx) / 2;
  const cy: number = (ay + by) / 2;
  const rx: number = Math.abs(bx - ax) / 2;
  const ry: number = Math.abs(by - ay) / 2;
  if (rx < 0.5 || ry < 0.5) {
    fillBox(data, w, h, ax, ay, bx, by, rgb);
    return;
  }
  const minX: number = Math.max(0, Math.floor(cx - rx - 1));
  const maxX: number = Math.min(w - 1, Math.ceil(cx + rx + 1));
  const minY: number = Math.max(0, Math.floor(cy - ry - 1));
  const maxY: number = Math.min(h - 1, Math.ceil(cy + ry + 1));
  for (let y = minY; y <= maxY; y++) {
    const dy: number = (y + 0.5 - cy) / ry;
    for (let x = minX; x <= maxX; x++) {
      const dx: number = (x + 0.5 - cx) / rx;
      const q: number = Math.sqrt(dx * dx + dy * dy);
      if (q >= 1.5) {
        continue;
      }
      const gx: number = dx / rx / q;
      const gy: number = dy / ry / q;
      const g: number = Math.sqrt(gx * gx + gy * gy);
      if (g < 0.000001) {
        blend(data, (y * w + x) * 4, 1, rgb);
        continue;
      }
      const cov: number = (1 - q) / g + 0.5;
      if (cov > 0) {
        blend(data, (y * w + x) * 4, cov, rgb);
      }
    }
  }
}

function fillTri(data: Uint8Array, w: number, h: number, ax: number, ay: number,
  bx: number, by: number, cx: number, cy: number, rgb: number[]): void {
  const area: number = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);
  if (Math.abs(area) < 0.001) {
    return;
  }
  const sign: number = area > 0 ? 1 : -1;
  const minX: number = Math.max(0, Math.floor(Math.min(ax, Math.min(bx, cx)) - 1));
  const maxX: number = Math.min(w - 1, Math.ceil(Math.max(ax, Math.max(bx, cx)) + 1));
  const minY: number = Math.max(0, Math.floor(Math.min(ay, Math.min(by, cy)) - 1));
  const maxY: number = Math.min(h - 1, Math.ceil(Math.max(ay, Math.max(by, cy)) + 1));
  for (let y = minY; y <= maxY; y++) {
    const py: number = y + 0.5;
    for (let x = minX; x <= maxX; x++) {
      const px: number = x + 0.5;
      const e0: number = ((bx - ax) * (py - ay) - (by - ay) * (px - ax)) * sign;
      const e1: number = ((cx - bx) * (py - by) - (cy - by) * (px - bx)) * sign;
      const e2: number = ((ax - cx) * (py - cy) - (ay - cy) * (px - cx)) * sign;
      if (e0 < 0 || e1 < 0 || e2 < 0) {
        continue;
      }
      const d: number = Math.min(distSeg(px, py, ax, ay, bx, by),
        Math.min(distSeg(px, py, bx, by, cx, cy), distSeg(px, py, cx, cy, ax, ay)));
      blend(data, (y * w + x) * 4, d + 0.5, rgb);
    }
  }
}

// 马赛克：矩形内的像素按块求平均再刷回。块大小取 MOSAIC_VP 个 vp 见方，与预览同口径，
// 颗粒感一致。就地修改，后面的笔可以叠在它上面。
function mosaicize(data: Uint8Array, w: number, h: number, m: Mark, kx: number, ky: number): void {
  const x0: number = Math.max(0, Math.round(Math.min(m.x0, m.x1) * kx));
  const x1: number = Math.min(w, Math.round(Math.max(m.x0, m.x1) * kx));
  const y0: number = Math.max(0, Math.round(Math.min(m.y0, m.y1) * ky));
  const y1: number = Math.min(h, Math.round(Math.max(m.y0, m.y1) * ky));
  if (x1 - x0 < 2 || y1 - y0 < 2) {
    return;
  }
  const block: number = Math.max(3, Math.round(MOSAIC_VP * kx));
  for (let by = y0; by < y1; by += block) {
    const endY: number = Math.min(y1, by + block);
    for (let bx = x0; bx < x1; bx += block) {
      const endX: number = Math.min(x1, bx + block);
      let r: number = 0;
      let g: number = 0;
      let b: number = 0;
      let n: number = 0;
      for (let y = by; y < endY; y++) {
        for (let x = bx; x < endX; x++) {
          const o: number = (y * w + x) * 4;
          r += data[o];
          g += data[o + 1];
          b += data[o + 2];
          n++;
        }
      }
      if (n === 0) {
        continue;
      }
      const rr: number = Math.round(r / n);
      const gg: number = Math.round(g / n);
      const bb: number = Math.round(b / n);
      for (let y = by; y < endY; y++) {
        for (let x = bx; x < endX; x++) {
          const o: number = (y * w + x) * 4;
          data[o] = rr;
          data[o + 1] = gg;
          data[o + 2] = bb;
          data[o + 3] = 255;
        }
      }
    }
  }
}
