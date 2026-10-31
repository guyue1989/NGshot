import { image } from '@kit.ImageKit';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { textRecognition } from '@kit.CoreVisionKit';
import { ProbeLog } from '../probe/ProbeLog';

// OCR 取词走 CoreVisionKit 的 textRecognition：init()、recognizeText()、release()，全程免权限。
// 硬约束：跳过 init() 直接识别报 1001400001，init() 返回 false 表示设备没有端侧 OCR；
// 入参 PixelMap 必须是 RGBA_8888，否则不报错但 value 全是空串，所以从 PNG 字节重新解码；
// 同进程不能并发调用，用模块级 busy 挡住；
// 尺寸上短边不小于 720、长边不超过 10000，短边 <100px 的图报 1001400001，宽高比超 8:1 的长条
// 要垫白边；超宽画布会被引擎切成多个 block，需按 cornerPoints 的纵向重叠把同一行并回去。
let inited: boolean = false;
let busy: boolean = false;

const OCR_MIN_SHORT: number = 720;
const OCR_MAX_SIDE: number = 10000;
const OCR_MAX_RATIO: number = 8;
const OCR_ROW_OVERLAP: number = 0.7;

export async function ocrFromPng(buf: ArrayBuffer, log: (line: string) => void): Promise<string | null> {
  if (busy) {
    log('上一次取词还没跑完，OCR 不能并发');
    return null;
  }
  busy = true;
  try {
    if (!inited) {
      let ok: boolean = false;
      try {
        ok = await textRecognition.init();
      } catch (e) {
        const err = e as BusinessError;
        log(`textRecognition.init 异常 code=${err.code} msg=${err.message}`);
        return null;
      }
      inited = ok;
      ProbeLog.add(`OCR init=${ok}`);
      if (!ok) {
        log('这台设备没有端侧 OCR 能力');
        return null;
      }
    }
    let pm: image.PixelMap | null = null;
    try {
      const src: image.ImageSource = image.createImageSource(buf);
      // 两道尺寸关：短边 <100px 引擎直接报 1001400001；官方建议 720p 以上，小字号截图按原分辨率
      // 喂进去识字率差，反引号会被认成“、”这类标点，抬到短边 720 再识别。
      // 长边封顶 10000，超限的图按长边反算等比缩。
      const info: image.ImageInfo = await src.getImageInfo();
      const minSide: number = Math.min(info.size.width, info.size.height);
      const maxSide: number = Math.max(info.size.width, info.size.height);
      let scale: number = Math.max(OCR_MIN_SHORT / minSide, 1);
      scale = Math.min(scale, OCR_MAX_SIDE / maxSide);
      let dw: number = Math.round(info.size.width * scale);
      let dh: number = Math.round(info.size.height * scale);
      if (Math.round(scale * 100) !== 100) {
        log(`图 ${info.size.width}x${info.size.height} 缩放到 ${dw}x${dh} 再识别`);
      }
      // RGBA_8888 是 OCR 的硬前提，desiredPixelFormat 默认即此值，显式写出防呆。
      pm = await src.createPixelMap({
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
        desiredSize: { width: dw, height: dh }
      });
      void src.release();
      // 宽高比超 8:1 的长条垫白边到合规比例，均匀放大不改比例，只有补边有效。
      const ratio: number = Math.max(dw, dh) / Math.min(dw, dh);
      let padded: boolean = false;
      if (ratio > OCR_MAX_RATIO) {
        pm = await padToRatio(pm, dw, dh, log);
        padded = true;
      }
      const t0: number = Date.now();
      const visionInfo: textRecognition.VisionInfo = { pixelMap: pm };
      const result = await textRecognition.recognizeText(visionInfo);
      void pm.release();
      pm = null;
      const ms: number = Date.now() - t0;
      const lines: string[] = padded ? mergeByBaseline(result, log) : collectInOrder(result);
      ProbeLog.add(`OCR 完成 ${lines.length} 行 ${ms}ms，图 ${result.blocks.length} blocks`
        + (padded ? '（长条路径，已按基线合并）' : ''));
      if (lines.length === 0) {
        log('没认出文字（图里可能没有字，或都不是可识别语种）');
        return null;
      }
      log(`取词完成 ${lines.length} 行 ${ms}ms`);
      return lines.join('\n');
    } catch (e) {
      const err = e as BusinessError;
      log(`recognizeText 失败 code=${err.code} msg=${err.message}`);
      return null;
    } finally {
      if (pm !== null) {
        try {
          void pm.release();
        } catch (e) {
          // 已消费的 PixelMap 再 release 会抛，忽略即可
        }
      }
    }
  } finally {
    busy = false;
  }
}

// 把长条像素原样拷进涂白的画布并居中，重建成合规比例的 RGBA_8888 图。全 0xFF 在任何字节序下都是
// 不透明白，不用区分 RGBA / BGRA。垫边让 cornerPoints 整体平移固定偏移，纵向重叠只看相对关系。
async function padToRatio(pm: image.PixelMap, w: number, h: number,
  log: (line: string) => void): Promise<image.PixelMap> {
  const longSide: number = Math.max(w, h);
  const need: number = Math.ceil(longSide / OCR_MAX_RATIO);
  let padW: number = w;
  let padH: number = h;
  if (w >= h) {
    padH = need;
  } else {
    padW = need;
  }
  const rowBytes: number = w * 4;
  const srcBuf: ArrayBuffer = new ArrayBuffer(w * h * 4);
  await pm.readPixelsToBuffer(srcBuf);
  const canvas: ArrayBuffer = new ArrayBuffer(padW * padH * 4);
  const c8: Uint8Array = new Uint8Array(canvas);
  c8.fill(0xFF);
  const s8: Uint8Array = new Uint8Array(srcBuf);
  const offX: number = Math.floor((padW - w) / 2);
  const offY: number = Math.floor((padH - h) / 2);
  for (let y = 0; y < h; y++) {
    c8.set(s8.subarray(y * rowBytes, (y + 1) * rowBytes), ((offY + y) * padW + offX) * 4);
  }
  const out: image.PixelMap = await image.createPixelMap(canvas, {
    size: { width: padW, height: padH },
    srcPixelFormat: image.PixelMapFormat.RGBA_8888,
    pixelFormat: image.PixelMapFormat.RGBA_8888,
    alphaType: image.AlphaType.UNPREMUL,
    editable: false
  });
  void pm.release();
  log(`长宽比 ${(longSide / Math.min(w, h)).toFixed(1)}:1 超 8:1，已垫白边 ${w}x${h} → ${padW}x${padH}`);
  return out;
}

// 正常截图的组装：照引擎给的 block/line 顺序逐行输出，一个 TextLine 一行。
function collectInOrder(result: textRecognition.TextRecognitionResult): string[] {
  const lines: string[] = [];
  result.blocks.forEach((block: textRecognition.TextBlock): void => {
    block.lines.forEach((line: textRecognition.TextLine): void => {
      if (line.value !== '') {
        lines.push(line.value);
      }
    });
  });
  return lines;
}

interface OcrSeg {
  value: string;
  top: number;
  bottom: number;
  left: number;
}

interface OcrRow {
  top: number;
  bottom: number;
  items: OcrSeg[];
}

// 长条专用：纵向重叠超 70%（按较矮的一条算）的片段视为同一物理行，行内按 x 排序拼接。
// 只被 padToRatio 之后的路径调用，那种图只有一两个物理行，规则可以写死，不会误吞正常段落。
function mergeByBaseline(result: textRecognition.TextRecognitionResult,
  log: (line: string) => void): string[] {
  const segs: OcrSeg[] = [];
  result.blocks.forEach((block: textRecognition.TextBlock): void => {
    block.lines.forEach((line: textRecognition.TextLine): void => {
      if (line.value !== '') {
        segs.push(segOf(line));
      }
    });
  });
  const rows: OcrRow[] = [];
  segs.forEach((seg: OcrSeg): void => {
    let placed: boolean = false;
    for (let i = 0; i < rows.length; i++) {
      const row: OcrRow = rows[i];
      const overlap: number = Math.min(row.bottom, seg.bottom) - Math.max(row.top, seg.top);
      const limit: number = Math.min(row.bottom - row.top, seg.bottom - seg.top) * OCR_ROW_OVERLAP;
      if (seg.bottom > seg.top && overlap >= limit) {
        row.items.push(seg);
        row.top = Math.min(row.top, seg.top);
        row.bottom = Math.max(row.bottom, seg.bottom);
        placed = true;
        break;
      }
    }
    if (!placed) {
      const fresh: OcrRow = { top: seg.top, bottom: seg.bottom, items: [seg] };
      rows.push(fresh);
    }
  });
  rows.sort((a: OcrRow, b: OcrRow): number => a.top - b.top);
  const lines: string[] = [];
  rows.forEach((row: OcrRow): void => {
    row.items.sort((a: OcrSeg, b: OcrSeg): number => a.left - b.left);
    let text: string = '';
    row.items.forEach((seg: OcrSeg): void => {
      if (text !== '' && joinWithSpace(text, seg.value)) {
        text += ' ';
      }
      text += seg.value;
    });
    if (text !== '') {
      lines.push(text);
    }
  });
  log(`长条取词：${segs.length} 段按基线并成 ${lines.length} 行`);
  return lines;
}

// cornerPoints 为顺时针四角点、首个是左上角，单位是喂进去那张画布的像素。这里取轴对齐包盒，
// 图有轻微旋转也不影响纵向重叠判断。
function segOf(line: textRecognition.TextLine): OcrSeg {
  if (line.cornerPoints.length === 0) {
    return { value: line.value, top: 0, bottom: 1, left: 0 };
  }
  let top: number = Number.MAX_VALUE;
  let bottom: number = -Number.MAX_VALUE;
  let left: number = Number.MAX_VALUE;
  for (let i = 0; i < line.cornerPoints.length; i++) {
    top = Math.min(top, line.cornerPoints[i].y);
    bottom = Math.max(bottom, line.cornerPoints[i].y);
    left = Math.min(left, line.cornerPoints[i].x);
  }
  return { value: line.value, top: top, bottom: bottom, left: left };
}

// 只在两侧都是 ASCII 词字符时补空格，中文之间不补，否则代码和英文会被粘在一起。
function joinWithSpace(prev: string, next: string): boolean {
  const a: string = prev.charAt(prev.length - 1);
  const b: string = next.charAt(0);
  return isWordChar(a) && isWordChar(b);
}

function isWordChar(c: string): boolean {
  if (c === '') {
    return false;
  }
  const code: number = c.charCodeAt(0);
  return (code >= 0x30 && code <= 0x39) || (code >= 0x41 && code <= 0x5A) || (code >= 0x61 && code <= 0x7A);
}

export async function copyText(text: string, log: (line: string) => void): Promise<boolean> {
  try {
    const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    await pasteboard.getSystemPasteboard().setData(data);
    return true;
  } catch (e) {
    const err = e as BusinessError;
    log(`复制文本失败 code=${err.code} msg=${err.message}`);
    return false;
  }
}
