import { screenshot } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ShotLog, canonicalPng } from './ShotService';

// 长截图拼接器：用户自己滚动，这里反复 capture() 同一条选区，只把底部新增的 dy 行接到累积图上。
//
// 系统没有对第三方开放滚动出图接口，注入滚轮又是系统权限，帧只能整屏 capture() 后 crop 选区，行步长按
// 像素总字节除以高反推。匹配以最后一帧成功接上的画面为参考，不在累积图里搜索，累积图只写不读。
// 相关用 NCC 求垂直位移，粗扫 4 行步长再在 ±3 行内细化到 1 行；相关低于 0.6 就丢帧。
// 尾校验：累积图末尾 32 行须对上本帧紧贴新增内容上方的那几行，位置由 dy 算出而非搜出。
// 逐行比较允许 ±1 行：真实滚动步长常含半行相位（本机 85.5 行），而错档是几十行级别，±1 挡不住它。
// 自相似页面会让 NCC 出现多个等高峰，保留前 6 个分别细化再过尾校验；连续 6 帧接不上就就地重锚。

// 一行切 32 块取块平均亮度，块亮度差在 9 以内算合上；24/32 块合上即认这一行相同。
// 块平均后同内容几乎零差，容差 9 够严，剩下的余量留给光标、滚动条、时钟这类局部变化。
const SIG_BLOCKS: number = 32;
const SIG_TOL: number = 9;
const SIG_BLOCK_RATIO: number = 0.75;
// 横向采样左右各让开这么多比例：滚动条、窗口边框、圆角只污染最边上一小条。
const EDGE_SKIP: number = 0.05;
// 与参考帧差 3 行以内直接算“画面没动”，不必再算相关。
const SNAP_SAME: number = 3;
// 粗扫每 4 行一个候选，行隔 4、列隔 2 取样；定下候选后在 ±3 行内按 2 行取样、全 32 列细化到 1 行。
// 861 行的一帧粗扫约 150 个候选、400 万次取值，单帧几十毫秒。
const NCC_COARSE_DY: number = 4;
const NCC_COARSE_ROW: number = 4;
const NCC_COARSE_COL: number = 2;
const NCC_FINE_ROW: number = 2;
// 细化后的 NCC 低于 0.6 不接：画面被重绘或亚像素重采样（滚到半途）、两帧之间不止垂直位移时都会掉到这里。
const NCC_MIN: number = 0.6;
// 一帧最多认带高 80% 的下移，再多重叠不足两成，任何相关都不可信。
const DY_RATIO: number = 0.8;
// 尾校验比对累积图最后 32 行，其中 70% 合上才算过。
const TAIL_ROWS: number = 32;
const TAIL_HIT_RATIO: number = 0.7;
// 粗扫保留前 6 个候选峰，彼此至少隔 12 行：自相似页面（Markdown 行距，本机约 85.5 行一个周期）的峰
// 几乎等高，只取 argmax 会挑到错周期，多留几个交给尾校验筛选。
const NCC_PEAKS: number = 6;
const NCC_PEAK_GAP: number = 12;
// 连续 6 帧接不上就重新起头，否则参考帧停在旧位置、dy 越滚越大直到卡死。重锚会丢掉中间内容，
// 门槛因此放高，先让多峰候选把能救的帧救回来。
const REANCHOR_MISSES: number = 6;
const MAX_ACC_H: number = 30000;
const MAX_SEGS: number = 80;
// 上限同时按字节限制：每接一段都要重开一块整份拷的 ArrayBuffer，瞬时峰值接近 2 倍。
const MAX_ACC_BYTES: number = 64 * 1024 * 1024;
// 面板预览图的像素上限，再大也显示不出来，每次接段还要多拷一遍。
const PREVIEW_MAX_W: number = 160;
const PREVIEW_MAX_H: number = 320;

let bandW: number = 0;
let bandH: number = 0;
let accBuf: ArrayBuffer = new ArrayBuffer(0);
let acc: Uint8Array = new Uint8Array(0);
let accH: number = 0;
let segs: number = 0;
let diagLogged: boolean = false;
// 最近一次判定的说明：接上和丢帧都要写出差多少，只说“接不上”下次仍然只能猜。
let lastDiag: string = '';
// 参考帧的行签名，取自最后一帧成功接上的画面，不是字面意义的上一帧。
let prevSig: Uint8Array = new Uint8Array(0);
let prevH: number = 0;
// 累积图最后 TAIL_ROWS 行的签名，只用于尾校验，接段后即等于新帧的最后几行。
let accTail: Uint8Array = new Uint8Array(0);
// 连续接不上的帧数，够 REANCHOR_MISSES 就重新起头。
let misses: number = 0;

export function resetLong(w: number, h: number): void {
  bandW = w;
  bandH = h;
  accBuf = new ArrayBuffer(0);
  acc = new Uint8Array(0);
  accH = 0;
  segs = 0;
  diagLogged = false;
  lastDiag = '';
  prevSig = new Uint8Array(0);
  prevH = 0;
  accTail = new Uint8Array(0);
  misses = 0;
}

export function longWidth(): number {
  return bandW;
}

export function longHeight(): number {
  return accH;
}

export function longSegs(): number {
  return segs;
}

export function longFull(): boolean {
  return accH >= MAX_ACC_H || segs >= MAX_SEGS || accBuf.byteLength >= MAX_ACC_BYTES;
}

// 给面板一句话：面板放不下整段，日志里是全文。
export function longDiag(): string {
  return lastDiag;
}

// 把一行压成 SIG_BLOCKS 个块平均亮度。单像素列会被光标、抗锯齿、亚像素重绘整列打飞，一块取平均后
// 这些噪声只剩几个灰阶。签名图同时就是求相关的灰度小图（每行 32 个值），不再单独降采样。
function buildSig(d: Uint8Array, stride: number, w: number, h: number): Uint8Array {
  const x0: number = Math.floor(w * EDGE_SKIP);
  const x1: number = Math.ceil(w * (1 - EDGE_SKIP));
  const span: number = Math.max(SIG_BLOCKS, x1 - x0);
  const out: Uint8Array = new Uint8Array(h * SIG_BLOCKS);
  for (let y = 0; y < h; y++) {
    const base: number = y * stride;
    const o: number = y * SIG_BLOCKS;
    for (let b = 0; b < SIG_BLOCKS; b++) {
      const bx0: number = x0 + Math.floor(b * span / SIG_BLOCKS);
      const bx1: number = x0 + Math.floor((b + 1) * span / SIG_BLOCKS);
      const step: number = Math.max(1, Math.floor((bx1 - bx0) / 8));
      let sum: number = 0;
      let n: number = 0;
      for (let x = bx0; x < bx1; x += step) {
        const p: number = base + x * 4;
        // 近似亮度（3:6:1），整数运算，够判断两行是否相同。
        sum += (d[p] * 3 + d[p + 1] * 6 + d[p + 2]) / 10;
        n++;
      }
      out[o + b] = n > 0 ? Math.round(sum / n) : 0;
    }
  }
  return out;
}

// 两行签名在同一位置合上几块，块亮度差在容差内即算一块命中。
function sigRowHits(a: Uint8Array, aRow: number, b: Uint8Array, bRow: number): number {
  const ao: number = aRow * SIG_BLOCKS;
  const bo: number = bRow * SIG_BLOCKS;
  let hit: number = 0;
  for (let k = 0; k < SIG_BLOCKS; k++) {
    const diff: number = a[ao + k] - b[bo + k];
    if (diff <= SIG_TOL && diff >= -SIG_TOL) {
      hit++;
    }
  }
  return hit;
}

// 签名行 a 的第 aRow 行与 b 中同位置及上下各一行比较，取最高命中数：真实滚动步长常是 x.5 行，
// 整数 dy 天生差半行，硬比会整片失配；错档差几十行，±1 行不会把它误判成正确。
function rowHitsNear(a: Uint8Array, aRow: number, b: Uint8Array, bRow: number, h: number,
  needBlocks: number): number {
  let best: number = 0;
  for (let s = -1; s <= 1; s++) {
    const row: number = bRow + s;
    if (row < 0 || row >= h) {
      continue;
    }
    const hit: number = sigRowHits(a, aRow, b, row);
    if (hit > best) {
      best = hit;
    }
    if (best >= needBlocks) {
      break;
    }
  }
  return best;
}

// 同一位置的相邻两帧是否同一画面。必须允许 ±1 行：编辑器停下重绘时会按半像素重新光栅化整屏，
// 严格要求逐行相同会把静止帧判成“动了”。
function countSameRows(a: Uint8Array, b: Uint8Array, h: number, needBlocks: number): number {
  let n: number = 0;
  for (let y = 0; y < h; y++) {
    if (rowHitsNear(a, y, b, y, h, needBlocks) >= needBlocks) {
      n++;
    }
  }
  return n;
}

// 把 src 的连续若干行拷进累积图，顺带把宽行（stride）压成紧行（bandW x 4）。
function putRows(dst: Uint8Array, atRow: number, src: Uint8Array, srcStride: number,
  fromRow: number, count: number): void {
  const tight: number = bandW * 4;
  for (let i = 0; i < count; i++) {
    const s: number = (fromRow + i) * srcStride;
    dst.set(src.subarray(s, s + tight), (atRow + i) * tight);
  }
}

// 两张签名图在位移 dy 下的归一化互相关：本帧第 y 行对参考帧第 y+dy 行。
// 结果落在 -1~1，可直接当置信度；整带一起算，局部脏点只按所占面积扣分。
function corrAt(a: Uint8Array, b: Uint8Array, dy: number, h: number,
  rowStep: number, colStep: number): number {
  const rows: number = Math.floor((h - dy) / rowStep);
  if (rows < 8) {
    return -1;
  }
  let n: number = 0;
  let sa: number = 0;
  let sb: number = 0;
  let saa: number = 0;
  let sbb: number = 0;
  let sab: number = 0;
  for (let i = 0; i < rows; i++) {
    const ra: number = (i * rowStep + dy) * SIG_BLOCKS;
    const rb: number = (i * rowStep) * SIG_BLOCKS;
    for (let c = 0; c < SIG_BLOCKS; c += colStep) {
      const va: number = a[ra + c];
      const vb: number = b[rb + c];
      n += 1;
      sa += va;
      sb += vb;
      saa += va * va;
      sbb += vb * vb;
      sab += va * vb;
    }
  }
  const va2: number = n * saa - sa * sa;
  const vb2: number = n * sbb - sb * sb;
  if (va2 <= 0 || vb2 <= 0) {
    return -1;
  }
  return (n * sab - sa * sb) / Math.sqrt(va2 * vb2);
}

function tailRowCount(h: number): number {
  return Math.min(TAIL_ROWS, Math.floor(h / 4));
}

function copyTail(sig: Uint8Array, h: number): Uint8Array {
  const r: number = tailRowCount(h);
  return new Uint8Array(sig.subarray((h - r) * SIG_BLOCKS, h * SIG_BLOCKS));
}

// 累积图尾部与本帧紧贴新增内容上方的同样多行本该是同一段画面。这是全流程唯一以累积图为判据的
// 地方：dy 差一两行或相关峰挑错会立刻暴露，宁可丢帧也不硬接。
function tailHitsOf(sig: Uint8Array, h: number, dy: number, needBlocks: number): number {
  const r: number = tailRowCount(h);
  if (accTail.length < r * SIG_BLOCKS) {
    return -1;
  }
  const base: number = h - dy - r;
  if (base < 0) {
    return -1;
  }
  let hits: number = 0;
  for (let i = 0; i < r; i++) {
    if (rowHitsNear(accTail, i, sig, base + i, h, needBlocks) >= needBlocks) {
      hits += 1;
    }
  }
  return hits;
}

// 接不上的帧数达到 REANCHOR_MISSES 就重新起头：参考帧和累积图尾巴改认当前帧，中间那段内容丢失。
// 不重锚则参考帧停在旧位置，dy 越滚越大，最终卡在永远对不上的状态。
function afterMiss(sig: Uint8Array, h: number): string {
  misses += 1;
  if (misses >= REANCHOR_MISSES) {
    prevSig = sig;
    prevH = h;
    accTail = copyTail(sig, h);
    misses = 0;
    lastDiag += `；已连续 ${REANCHOR_MISSES} 帧接不上，就地重新起头（中间这段丢了）`;
  }
  return 'nomatch';
}

// 一帧进来，返回 first / added / same / nomatch / full / bad 之一。frame 的行步长是 st（字节）。
export function feedFrame(frame: Uint8Array, w: number, h: number, st: number): string {
  if (w !== bandW || h !== bandH) {
    lastDiag = `帧尺寸 ${w}x${h} 与选区 ${bandW}x${bandH} 不一致`;
    return 'bad';
  }
  const sig: Uint8Array = buildSig(frame, st, w, h);
  return feedCore(frame, sig, h, st);
}

function feedCore(frame: Uint8Array, sig: Uint8Array, h: number, st: number): string {
  const tight: number = bandW * 4;
  const needBlocks: number = Math.max(1, Math.ceil(SIG_BLOCKS * SIG_BLOCK_RATIO));
  if (accH === 0) {
    accBuf = new ArrayBuffer(h * tight);
    acc = new Uint8Array(accBuf);
    putRows(acc, 0, frame, st, 0, h);
    accH = h;
    segs = 1;
    accTail = copyTail(sig, h);
    prevSig = sig;
    prevH = h;
    misses = 0;
    lastDiag = `第 1 段已收 ${bandW}x${h}，行步长 ${st}`;
    return 'first';
  }
  const same: number = prevH === h ? countSameRows(sig, prevSig, h, needBlocks) : -1;
  const sameText: string = same < 0 ? '上帧没存' : `与参考帧同 ${same}/${h} 行`;
  // 画面没动：参考帧仍是最后一帧接上的画面，内容相同，不必再算相关。
  if (same >= h - SNAP_SAME) {
    lastDiag = `与参考帧几乎一样（${same}/${h} 行），画面没动`;
    misses = 0;
    return 'same';
  }
  const dyMax: number = Math.max(1, Math.floor(h * DY_RATIO));
  const coarseCount: number = Math.floor(dyMax / NCC_COARSE_DY) + 1;
  const coarse: number[] = [];
  let topIdx: number = 0;
  for (let i = 0; i < coarseCount; i++) {
    const s: number = corrAt(prevSig, sig, i * NCC_COARSE_DY, h, NCC_COARSE_ROW, NCC_COARSE_COL);
    coarse.push(s);
    if (s > coarse[topIdx]) {
      topIdx = i;
    }
  }
  if (coarse[topIdx] < 0) {
    // 整幅纯色或几乎无变化时任何位置都算不出相关，按“画面没动”处理，不报 nomatch
    lastDiag = '这一带没有可比的内容（整幅纯色），画面没动';
    misses = 0;
    return 'same';
  }
  const nccAtZero: number = coarse[0];
  // 取前几个局部极大当候选：自相似页面上它们几乎等高，排名先后只是噪声。
  const idx: number[] = [];
  for (let i = 0; i < coarseCount; i++) {
    const left: number = i > 0 ? coarse[i - 1] : -2;
    const right: number = i + 1 < coarseCount ? coarse[i + 1] : -2;
    if (coarse[i] >= left && coarse[i] >= right) {
      idx.push(i);
    }
  }
  if (idx.length === 0) {
    idx.push(topIdx);
  }
  idx.sort((a: number, b: number): number => coarse[b] - coarse[a]);
  const picks: number[] = [];
  for (let k = 0; k < idx.length && picks.length < NCC_PEAKS; k++) {
    let ok: boolean = true;
    for (let m = 0; m < picks.length; m++) {
      if (Math.abs(picks[m] - idx[k]) * NCC_COARSE_DY < NCC_PEAK_GAP) {
        ok = false;
        break;
      }
    }
    if (ok) {
      picks.push(idx[k]);
    }
  }
  const r: number = tailRowCount(h);
  const needTail: number = Math.max(1, Math.ceil(r * TAIL_HIT_RATIO));
  // 候选逐个细化到 1 行并各自过尾校验；尾校验是权威判据，NCC 只负责给出位置。
  let bestDy: number = -1;
  let bestNcc: number = -2;
  let bestTail: number = -1;
  let repDy: number = -1;
  let repNcc: number = -2;
  let repTail: number = -1;
  let tailBest: number = -1;
  let tailBestDy: number = -1;
  let tailBestNcc: number = -2;
  for (let k = 0; k < picks.length; k++) {
    const c: number = picks[k] * NCC_COARSE_DY;
    // 粗扫步长 4，真值最多落在 ±2 内，往两边各留 3 行细化到 1 行。
    const lo: number = Math.max(0, c - NCC_COARSE_DY + 1);
    const hi: number = Math.min(dyMax, c + NCC_COARSE_DY - 1);
    let d: number = c;
    let n: number = -2;
    for (let q = lo; q <= hi; q++) {
      const s: number = corrAt(prevSig, sig, q, h, NCC_FINE_ROW, 1);
      if (s > n) {
        n = s;
        d = q;
      }
    }
    const th: number = tailHitsOf(sig, h, d, needBlocks);
    if (th > tailBest) {
      tailBest = th;
      tailBestDy = d;
      tailBestNcc = n;
    }
    if (n > repNcc) {
      repNcc = n;
      repDy = d;
      repTail = th;
    }
    if (d > 0 && n >= NCC_MIN && (th < 0 || th >= needTail) && n > bestNcc) {
      bestNcc = n;
      bestDy = d;
      bestTail = th;
    }
  }
  if (bestDy <= 0) {
    const repText: string = repNcc.toFixed(3);
    if (repDy <= 0) {
      lastDiag = `本帧没有下移（相关 ${repText}），往下滚一点再接；${sameText}`;
      misses = 0;
      return 'same';
    }
    if (repNcc < NCC_MIN) {
      lastDiag = `相关不够：${picks.length} 个候选里最高的是下移 ${repDy} 行、相关 ${repText}`
        + `（要 ${NCC_MIN.toFixed(2)}），粗扫静止位 ${nccAtZero.toFixed(3)}；${sameText}`;
      return afterMiss(sig, h);
    }
    lastDiag = `尾校验不过：${picks.length} 个候选都没对上累积图尾（最好 ${repDy} 行、相关 ${repText}、`
      + `尾 ${repTail}/${r}；全场尾最好 ${tailBest}/${r}（${tailBestDy} 行、相关 `
      + `${tailBestNcc.toFixed(3)}），要 ${needTail}）；${sameText}`;
    return afterMiss(sig, h);
  }
  const nccText: string = bestNcc.toFixed(3);
  const tailText: string = bestTail < 0 ? '尾校验 跳过' : `尾校验 ${bestTail}/${r}`;
  const next: ArrayBuffer = new ArrayBuffer((accH + bestDy) * tight);
  const nv: Uint8Array = new Uint8Array(next);
  nv.set(acc, 0);
  putRows(nv, accH, frame, st, h - bestDy, bestDy);
  accBuf = next;
  acc = nv;
  accH += bestDy;
  segs += 1;
  prevSig = sig;
  prevH = h;
  accTail = copyTail(sig, h);
  misses = 0;
  lastDiag = `接上第 ${segs} 段：本帧下移 ${bestDy} 行，相关 ${nccText}，${tailText}；${sameText}`;
  if (longFull()) {
    return 'full';
  }
  return 'added';
}

// 抓一帧选区喂给拼接器。capture() 的整屏 map 先原地 crop 到选区，buffer 按 getPixelBytesNumber()
// 开（含行步长），再由总字节除以高反推行步长。
export async function grabBand(x: number, y: number, w: number, h: number,
  log: ShotLog): Promise<string> {
  let pm: image.PixelMap | null = null;
  try {
    pm = await screenshot.capture();
    const info: image.ImageInfo = pm.getImageInfoSync();
    if (x + w > info.size.width || y + h > info.size.height) {
      log(`长截图选区超出整屏 ${info.size.width}x${info.size.height}，这一帧丢掉`);
      return 'bad';
    }
    const region: image.Region = { x: x, y: y, size: { width: w, height: h } };
    await pm.crop(region);
    const cut: image.ImageInfo = pm.getImageInfoSync();
    if (cut.pixelFormat !== image.PixelMapFormat.RGBA_8888) {
      log(`长截图：帧的像素格式是 ${cut.pixelFormat}，不是 RGBA_8888，按 4 字节读会错色`);
      return 'bad';
    }
    const total: number = pm.getPixelBytesNumber();
    const st: number = Math.floor(total / cut.size.height);
    if (!diagLogged) {
      diagLogged = true;
      log(`长截图取帧：整屏 ${info.size.width}x${info.size.height}，格式 ${info.pixelFormat} → 选区 `
        + `${cut.size.width}x${cut.size.height}，像素总字节 ${total}，行步长 ${st}`
        + `（紧行 ${cut.size.width * 4}${st === cut.size.width * 4 ? '，一致' : '，crop 后没收窄，必须按步长走'}）`);
    }
    if (st < cut.size.width * 4 || st % 4 !== 0 || st * cut.size.height > total) {
      log(`长截图：行步长 ${st} 不成立（字节 ${total}、高 ${cut.size.height}），这一帧丢掉`);
      return 'bad';
    }
    const bytes: ArrayBuffer = new ArrayBuffer(total);
    await pm.readPixelsToBuffer(bytes);
    const code: string = feedFrame(new Uint8Array(bytes), cut.size.width, cut.size.height, st);
    if (code === 'added') {
      log(`长截图：${lastDiag}`);
    } else if (code === 'nomatch' || code === 'bad') {
      log(`长截图：${code === 'nomatch' ? '这一帧接不上' : '这一帧没用'}（${lastDiag}）`);
    }
    return code;
  } catch (e) {
    const err = e as BusinessError;
    log(`长截图取帧失败 code=${err.code} msg=${err.message}`);
    return 'bad';
  } finally {
    if (pm !== null) {
      try {
        pm.release();
      } catch (e) {
        // 重复 release 会抛异常，这里吞掉以免污染日志
      }
    }
  }
}

// 累积图转成 PNG 字节，与标注出图同走 createPixelMap(RGBA_8888) + canonicalPng，
// 因此累积图必须是压好的紧行（bandW x 4 一行）。
export async function longPng(log: ShotLog): Promise<ArrayBuffer | null> {
  if (accH === 0) {
    log('长截图还没接到任何一帧，出不了图');
    return null;
  }
  let pm: image.PixelMap | null = null;
  try {
    pm = await image.createPixelMap(accBuf, {
      size: { width: bandW, height: accH },
      srcPixelFormat: image.PixelMapFormat.RGBA_8888,
      pixelFormat: image.PixelMapFormat.RGBA_8888,
      alphaType: image.AlphaType.UNPREMUL,
      editable: false
    });
    log(`长图已合成 ${bandW}x${accH}px，${segs} 段，开始编 PNG`);
    const bytes: ArrayBuffer | null = await canonicalPng(pm, log);
    pm = null;
    return bytes;
  } catch (e) {
    const err = e as BusinessError;
    log(`长图出图失败 code=${err.code} msg=${err.message}`);
    if (pm !== null) {
      try {
        pm.release();
      } catch (e2) {
        // 同上，重复释放会抛异常
      }
    }
    return null;
  }
}

// 面板左下角的小预览：累积图按最近邻缩到 PREVIEW_MAX_W x PREVIEW_MAX_H 以内，返回新 map，
// 旧图由调用方在换图后释放。每行只读 pw 个像素，成本可忽略。
export async function longPreview(): Promise<image.PixelMap | null> {
  if (accH === 0 || bandW === 0) {
    return null;
  }
  const scale: number = Math.min(PREVIEW_MAX_W / bandW, PREVIEW_MAX_H / accH, 1);
  const pw: number = Math.max(1, Math.round(bandW * scale));
  const ph: number = Math.max(1, Math.round(accH * scale));
  const buf: ArrayBuffer = new ArrayBuffer(pw * ph * 4);
  const dst: Uint8Array = new Uint8Array(buf);
  const srcRowBytes: number = bandW * 4;
  for (let y = 0; y < ph; y++) {
    const sy: number = Math.min(accH - 1, Math.floor(y / scale));
    const sRow: number = sy * srcRowBytes;
    const dRow: number = y * pw * 4;
    for (let x = 0; x < pw; x++) {
      const sx: number = Math.min(bandW - 1, Math.floor(x / scale));
      const s: number = sRow + sx * 4;
      const d: number = dRow + x * 4;
      dst[d] = acc[s];
      dst[d + 1] = acc[s + 1];
      dst[d + 2] = acc[s + 2];
      dst[d + 3] = 255;
    }
  }
  try {
    return await image.createPixelMap(buf, {
      size: { width: pw, height: ph },
      srcPixelFormat: image.PixelMapFormat.RGBA_8888,
      pixelFormat: image.PixelMapFormat.RGBA_8888,
      alphaType: image.AlphaType.UNPREMUL,
      editable: false
    });
  } catch (e) {
    // 缩失败只是没有预览，不影响拼接，不向调用方抛错
    return null;
  }
}
