import { image } from '@kit.ImageKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { pasteboard, BusinessError } from '@kit.BasicServicesKit';
import {
  ShotFormat,
  formatMime,
  formatExt,
  formatLabel,
  qualityApplies,
  saveTargetDir,
  saveFormatNow,
  saveQualityNow,
  clipFormatNow,
  clipQualityNow
} from './ShotSettings';
import { Mark, rasterize, drawTexts, hasText } from './MarkService';

export type ShotLog = (line: string) => void;

function stamp(): string {
  const d = new Date();
  const p = (n: number, w: number): string => n.toString().padStart(w, '0');
  return `${d.getFullYear()}${p(d.getMonth() + 1, 2)}${p(d.getDate(), 2)}`
    + `-${p(d.getHours(), 2)}${p(d.getMinutes(), 2)}${p(d.getSeconds(), 2)}`;
}

// packToData() 会消耗传入的 PixelMap，文档写明打包后不能再次使用，一张图只能出一次结果。
// 因此整个流程只在截图时留一份 canonical PNG，各条导出路径都从它解码出新的 map。
export async function canonicalPng(pm: image.PixelMap, log: ShotLog): Promise<ArrayBuffer | null> {
  const t0: number = Date.now();
  const packer = image.createImagePacker();
  try {
    const buf: ArrayBuffer = await packer.packToData(pm, { format: 'image/png', quality: 100 });
    log(`原图已固化为 PNG 字节 ${buf.byteLength} 字节，耗时 ${Date.now() - t0}ms`);
    return buf;
  } catch (e) {
    const err = e as BusinessError;
    log(`固化失败 code=${err.code} msg=${err.message}`);
    return null;
  } finally {
    packer.release();
    releaseQuietly(pm);
  }
}

// 已被打包消耗的 map 再 release 会抛异常，这类失败对日志没有意义，故有意吞掉。
function releaseQuietly(pm: image.PixelMap): void {
  try {
    pm.release();
  } catch (e) {
    // packToData 已消耗该 map，重复释放会抛异常
  }
}

// canonical buffer 放在模块级而不是 AppStorage：ArrayBuffer 经 AppStorage 存取后会变成非原生对象，
// image.createImageSource() 随之返回 undefined。结果窗与本模块同进程，模块级变量直接送达；
// 状态、尺寸这类字符串仍走 AppStorage。
let canonicalBuffer: ArrayBuffer | null = null;

export function setShotBuffer(buf: ArrayBuffer | null): void {
  canonicalBuffer = buf;
}

export function shotBufferNow(): ArrayBuffer | null {
  return canonicalBuffer;
}

export function disposeShot(pm: image.PixelMap): void {
  releaseQuietly(pm);
}

async function decodeBytes(buf: ArrayBuffer): Promise<image.PixelMap> {
  const src = image.createImageSource(buf);
  if (src === undefined || src === null) {
    // buffer 不是原生 ArrayBuffer 时 createImageSource 返回 undefined 而不抛异常，
    // finally 里直接 release() 会把错误掩盖成“Cannot read property release of undefined”。
    throw new Error(`createImageSource 返回 undefined（byteLength=${buf.byteLength}），字节不是原生 ArrayBuffer`);
  }
  try {
    return await src.createPixelMap();
  } finally {
    try {
      src.release();
    } catch (e) {
      // 已产出 map 的 ImageSource 可能拒绝 release，不值得占一行日志
    }
  }
}

// 从 canonical buffer 解码出新 map，再按目标格式重新打包。
async function repack(buf: ArrayBuffer, fmt: ShotFormat, quality: number): Promise<ArrayBuffer> {
  const pm: image.PixelMap = await decodeBytes(buf);
  const packer = image.createImagePacker();
  try {
    return await packer.packToData(pm, { format: formatMime(fmt), quality: quality });
  } finally {
    packer.release();
    releaseQuietly(pm);
  }
}

// 保存走 packToFile()（API 11 起，fd 为 0~65535 的普通数字），直接写入文件句柄：
// 内存里不留整图 ArrayBuffer，也不受 packToData 的缓冲区上限约束。
async function repackToFd(buf: ArrayBuffer, fmt: ShotFormat, quality: number, fd: number): Promise<void> {
  const pm: image.PixelMap = await decodeBytes(buf);
  const packer = image.createImagePacker();
  try {
    await packer.packToFile(pm, fd, { format: formatMime(fmt), quality: quality });
  } finally {
    packer.release();
    releaseQuietly(pm);
  }
}

export async function saveShot(buf: ArrayBuffer, ctx: common.UIAbilityContext, log: ShotLog): Promise<boolean> {
  const fmt: ShotFormat = saveFormatNow();
  const q: number = saveQualityNow();
  const dir: string = saveTargetDir(ctx);
  const path: string = `${dir}/NGshot-${stamp()}.${formatExt(fmt)}`;
  try {
    if (!fs.accessSync(dir)) {
      // 用递归创建：新选的公共目录可能还差一层，非递归形式只建最后一级。
      fs.mkdirSync(dir, true);
    }
  } catch (e) {
    log(`目录检查/创建失败 ${dir}: ${JSON.stringify(e)}`);
  }
  try {
    const t0: number = Date.now();
    const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      await repackToFd(buf, fmt, q, file.fd);
    } finally {
      fs.closeSync(file);
    }
    const size: number = fs.statSync(path).size;
    log(`已保存 ${path} ${formatLabel(fmt)}${qualityApplies(fmt) ? ` q=${q}` : ''} `
      + `${size} 字节，耗时 ${Date.now() - t0}ms`);
    return true;
  } catch (e) {
    const err = e as BusinessError;
    log(`保存失败 code=${err.code} msg=${err.message} 路径=${path}`);
    return false;
  }
}

// 剪贴板图像通道（MIMETYPE_PIXELMAP）传的是解码后的位图，不是文件字节。要落实格式与质量设置，
// 只能先打包再解码回位图：压缩真实生效，接收方拿到的是有损版本。
export async function copyShot(buf: ArrayBuffer, log: ShotLog): Promise<boolean> {
  const fmt: ShotFormat = clipFormatNow();
  const q: number = clipQualityNow();
  try {
    const t0: number = Date.now();
    const packed: ArrayBuffer = await repack(buf, fmt, q);
    const repainted: image.PixelMap = await decodeBytes(packed);
    const data = pasteboard.createData(pasteboard.MIMETYPE_PIXELMAP, repainted);
    // 有意不读返回值：setData 的签名在不同 SDK 版本间不一致，复制失败只会抛异常。
    await pasteboard.getSystemPasteboard().setData(data);
    log(`已复制进剪贴板 ${formatLabel(fmt)}${qualityApplies(fmt) ? ` q=${q}` : ''} `
      + `${packed.byteLength} 字节，耗时 ${Date.now() - t0}ms`);
    return true;
  } catch (e) {
    const err = e as BusinessError;
    log(`复制失败 code=${err.code} msg=${err.message}`);
    return false;
  }
}

export async function previewShot(buf: ArrayBuffer, log: ShotLog): Promise<image.PixelMap | null> {
  try {
    return await decodeBytes(buf);
  } catch (e) {
    const err = e as BusinessError;
    log(`预览解码失败 code=${err.code} msg=${err.message}`);
    return null;
  }
}

// 两个持有者，因为框选层不再等编码完成。captureMap 是框选层绘制的原始截图 PixelMap，也是热键到
// 上屏这条路上唯一需要的数据；screenBuffer 是后台几百毫秒后编好的 PNG，供裁选区解码。
// 两者都放模块级：ArrayBuffer 过 AppStorage 会失去原生性，PixelMap 根本无法序列化。
let captureMap: image.PixelMap | null = null;
let screenBuffer: ArrayBuffer | null = null;
let screenGen: number = 0;

export function setCaptureMap(pm: image.PixelMap | null): void {
  captureMap = pm;
}

export function captureMapNow(): image.PixelMap | null {
  return captureMap;
}

// 每次截图取一个新的代数，后台编码只有在代数仍匹配时才落地。
// 否则上一张的慢编码会写进新框选层的会话，裁选区会静默裁到上一屏。
export function beginScreenBuffer(): number {
  screenGen++;
  screenBuffer = null;
  return screenGen;
}

export function endScreenBuffer(buf: ArrayBuffer | null, gen: number, log: ShotLog): void {
  if (gen !== screenGen) {
    log('这张全屏 PNG 已过期（选区已关或新一张已开场），丢掉');
    return;
  }
  screenBuffer = buf;
}

export function dropScreenBuffer(): void {
  screenGen++;
  screenBuffer = null;
}

function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(resolve, ms);
  });
}

// 用户可能在后台编码落地前就开始裁选区。这里的等待是编码移出关键路径换来的，
// 几百毫秒属正常情况，不是错误。
async function waitScreenBuffer(log: ShotLog): Promise<ArrayBuffer | null> {
  if (screenBuffer !== null) {
    return screenBuffer;
  }
  const t0: number = Date.now();
  log('全屏 PNG 还在后台编，等它一下');
  for (let i = 0; i < 250 && screenBuffer === null; i++) {
    await delay(20);
  }
  const buf: ArrayBuffer | null = screenBuffer;
  log(buf === null ? '等了 5s 全屏 PNG 还没到，放弃'
    : `全屏 PNG 等到了，多等 ${Date.now() - t0}ms`);
  return buf;
}

// 解码时按选区从全屏字节里裁切。字段名是 desiredRegion 而非 region，单位 px；
// 返回新生 map 而不改写原图，所以同一份 buffer 可以反复裁。
export async function cropRegionPng(x: number, y: number, w: number, h: number,
  log: ShotLog): Promise<ArrayBuffer | null> {
  const buf: ArrayBuffer | null = await waitScreenBuffer(log);
  if (buf === null) {
    log('全屏快照字节已经不在了，裁不了选区');
    return null;
  }
  const src = image.createImageSource(buf);
  if (src === undefined || src === null) {
    log(`createImageSource 返回 undefined（byteLength=${buf.byteLength}）`);
    return null;
  }
  let region: image.PixelMap | null = null;
  try {
    const opt: image.DecodingOptions = {
      desiredRegion: { x: x, y: y, size: { width: w, height: h } }
    };
    region = await src.createPixelMap(opt);
    log(`选区已解出 ${w}x${h}（起点 ${x},${y}）`);
    return await canonicalPng(region, log);
  } catch (e) {
    const err = e as BusinessError;
    log(`裁选区失败 code=${err.code} msg=${err.message}（区域不能超出图片宽高，单位 px）`);
    if (region !== null) {
      releaseQuietly(region);
    }
    return null;
  } finally {
    try {
      src.release();
    } catch (e) {
      // 已产出 map 的 ImageSource 可能拒绝 release
    }
  }
}

export interface RegionPixels {
  w: number;
  h: number;
  data: Uint8Array;
  bytes: ArrayBuffer;
}

// 选区底图的原始像素（RGBA_8888，px）：预览取马赛克的颗粒色、出图当画布都用它。
// 与 cropRegionPng 同源（同一份全屏 PNG 加 desiredRegion），预览和出图的底图是同一张。
export async function regionPixels(x: number, y: number, w: number, h: number,
  log: ShotLog): Promise<RegionPixels | null> {
  if (w <= 0 || h <= 0) {
    log(`选区尺寸不对 ${w}x${h}`);
    return null;
  }
  const buf: ArrayBuffer | null = await waitScreenBuffer(log);
  if (buf === null) {
    log('全屏快照字节已经不在了，取不到底图');
    return null;
  }
  const src = image.createImageSource(buf);
  if (src === undefined || src === null) {
    log(`createImageSource 返回 undefined（byteLength=${buf.byteLength}）`);
    return null;
  }
  let pm: image.PixelMap | null = null;
  try {
    pm = await src.createPixelMap({
      desiredRegion: { x: x, y: y, size: { width: w, height: h } },
      desiredPixelFormat: image.PixelMapFormat.RGBA_8888
    });
    const info: image.ImageInfo = pm.getImageInfoSync();
    const rw: number = info.size.width;
    const rh: number = info.size.height;
    const bytes: ArrayBuffer = new ArrayBuffer(rw * rh * 4);
    await pm.readPixelsToBuffer(bytes);
    return { w: rw, h: rh, data: new Uint8Array(bytes), bytes: bytes };
  } catch (e) {
    const err = e as BusinessError;
    log(`取选区底图失败 code=${err.code} msg=${err.message}`);
    return null;
  } finally {
    if (pm !== null) {
      releaseQuietly(pm);
    }
    try {
      src.release();
    } catch (e) {
      // 已产出 map 的 ImageSource 可能拒绝 release
    }
  }
}

// 带标注的选区：底图与命令表一起烧成一张 PNG。标注坐标是选区内 vp，乘 kx/ky 落到 px 底图，
// 出图保持整屏分辨率。没有标注时 SelectPage 直接走 cropRegionPng。
export async function annotatedPng(x: number, y: number, w: number, h: number, marks: Mark[],
  kx: number, ky: number, log: ShotLog): Promise<ArrayBuffer | null> {
  const rp: RegionPixels | null = await regionPixels(x, y, w, h, log);
  if (rp === null) {
    return null;
  }
  const t0: number = Date.now();
  rasterize(rp.data, rp.w, rp.h, marks, kx, ky);
  const texts: boolean = hasText(marks);
  let pm: image.PixelMap | null = null;
  try {
    const map: image.PixelMap = await image.createPixelMap(rp.bytes, {
      size: { width: rp.w, height: rp.h },
      srcPixelFormat: image.PixelMapFormat.RGBA_8888,
      pixelFormat: image.PixelMapFormat.RGBA_8888,
      alphaType: image.AlphaType.UNPREMUL,
      // 文字要用 Drawing 的 Canvas 叠加，该 PixelMap 必须可编辑；没有文字时保持原样。
      editable: texts
    });
    pm = map;
    log(`标注已烧进底图 ${rp.w}x${rp.h}，${marks.length} 笔，光栅耗时 ${Date.now() - t0}ms`);
    if (texts) {
      const t1: number = Date.now();
      try {
        const n: number = drawTexts(map, marks, kx, ky, rp.w);
        log(`文字 ${n} 段已画在形状之上，耗时 ${Date.now() - t1}ms`);
      } catch (e) {
        const err = e as BusinessError;
        log(`文字没画上 code=${err.code} msg=${err.message}`);
      }
    }
    const bytes: ArrayBuffer | null = await canonicalPng(map, log);
    pm = null;
    return bytes;
  } catch (e) {
    const err = e as BusinessError;
    log(`标注出图失败 code=${err.code} msg=${err.message}`);
    return null;
  } finally {
    if (pm !== null) {
      releaseQuietly(pm);
    }
  }
}
