/*
 * NGshot 应用图标生成脚本：暖橙色 “N” 记号，粗圆角笔画加相机光圈与光点。产物为四份：
 * foreground.png（透明底墨色，主体在安全圆内）、background.png（不透明纯色底，华为要求
 * 背景无透明像素）、app_layered_image.json（app.json5 引用的分层配置）、app_icon.png
 * （压平的单层合成图，供能力图标与 startWindowIcon）。
 * 几何用有符号距离场，PNG 本地编码，不依赖图像库；运行 ELECTRON_RUN_AS_NODE=1 <electron-binary> tools/make-icon.js
 */
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

const T = (() => {
  const t = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c;
  }
  return t;
})();
function crc32(b) {
  let c = -1;
  for (let i = 0; i < b.length; i++) c = T[(c ^ b[i]) & 0xff] ^ (c >>> 8);
  return (c ^ -1) >>> 0;
}
function chunk(type, body) {
  const out = Buffer.alloc(8 + body.length + 4);
  out.writeUInt32BE(body.length, 0);
  out.write(type, 4, 'ascii');
  body.copy(out, 8);
  out.writeUInt32BE(crc32(Buffer.concat([Buffer.from(type, 'ascii'), body])), 8 + body.length);
  return out;
}
function writePng(file, data, n) {
  const s = n * 4;
  const raw = Buffer.alloc((s + 1) * n);
  for (let y = 0; y < n; y++) {
    raw[y * (s + 1)] = 0;
    data.copy(raw, y * (s + 1) + 1, y * s, y * s + s);
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(n, 0);
  ihdr.writeUInt32BE(n, 4);
  ihdr[8] = 8;
  ihdr[9] = 6;
  fs.writeFileSync(file, Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', zlib.deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0)),
  ]));
}
function readSize(file) {
  const b = fs.readFileSync(file);
  return { w: b.readUInt32BE(16), h: b.readUInt32BE(20), depth: b[24], color: b[25] };
}

const V = 1024;
const AA = 6;

// 背景必须完全不透明（华为规定），记号用奶油色画在上面
const BG = [238, 116, 14];
const C_TOP = [255, 248, 236];
const C_BOT = [255, 231, 199];
const C_BEVEL = [196, 82, 6];
const C_OUTLINE = [164, 66, 5];
const C_CREAM = [255, 243, 227];
const C_DOT1 = [255, 243, 227];
const C_DOT2 = [255, 208, 146];

function clamp01(v) { return Math.max(0, Math.min(1, v)); }
function cover(d) { return clamp01(0.5 - d / AA); }

// 圆角矩形：(cx,cy) 为中心，(hx,hy) 为半宽半高，r 为圆角半径
function box(x, y, cx, cy, hx, hy, r) {
  const qx = Math.abs(x - cx) - (hx - r);
  const qy = Math.abs(y - cy) - (hy - r);
  const ax = Math.max(qx, 0), ay = Math.max(qy, 0);
  return Math.sqrt(ax * ax + ay * ay) + Math.min(Math.max(qx, qy), 0) - r;
}
// 胶囊体：从 (ax,ay) 到 (bx,by)，半宽 w
function capsule(x, y, ax, ay, bx, by, w) {
  const px = x - ax, py = y - ay;
  const ex = bx - ax, ey = by - ay;
  const l2 = ex * ex + ey * ey;
  let t = l2 ? (px * ex + py * ey) / l2 : 0;
  t = Math.max(0, Math.min(1, t));
  const dx = px - ex * t, dy = py - ey * t;
  return Math.sqrt(dx * dx + dy * dy) - w;
}
function ring(x, y, cx, cy, r, sw) {
  const d = Math.sqrt((x - cx) * (x - cx) + (y - cy) * (y - cy));
  return Math.abs(d - r) - sw / 2;
}

// N 字形：两根圆角竖笔加一根圆角斜笔
function dN(x, y) {
  const stemL = box(x, y, 383, 528, 86, 288, 42);
  const stemR = box(x, y, 697, 528, 86, 288, 42);
  const diag = capsule(x, y, 372, 252, 708, 804, 84);
  return Math.min(stemL, stemR, diag);
}

// 相机：手机轮廓加听筒槽加快门。快门是圆环加六条约 96° 的弦，比例取自 Feather 光圈图标，
// 弦长接近直径会编成一张网。
function dCam(x, y) {
  const phone = Math.abs(box(x, y, 763, 606, 112, 178, 54)) - 11;
  const slot = capsule(x, y, 712, 478, 752, 478, 6.5);
  const acx = 763, acy = 648, R = 88;
  let d = Math.min(phone, slot, ring(x, y, acx, acy, R, 18));
  for (let i = 0; i < 6; i++) {
    const a1 = (i * 60 * Math.PI) / 180;
    const a2 = ((i * 60 + 96) * Math.PI) / 180;
    d = Math.min(d, capsule(x, y,
      acx + R * Math.cos(a1), acy + R * Math.sin(a1),
      acx + R * Math.cos(a2), acy + R * Math.sin(a2), 7.5));
  }
  return d;
}

function dot(x, y, cx, cy, r) {
  return Math.sqrt((x - cx) * (x - cx) + (y - cy) * (y - cy)) - r;
}

// 设计坐标系里的图层，自下而上，每项是 (覆盖率, 颜色)
function layersAt(x, y) {
  const layers = [];
  const dBev = dN(x - 16, y - 18);
  const cN = cover(dN(x, y));
  const cBev = cover(dBev) * (1 - cN);
  if (cBev > 0) layers.push([cBev, C_BEVEL]);
  if (cN > 0) {
    const t = clamp01((y - 240) / 580);
    layers.push([cN, [
      Math.round(C_TOP[0] + (C_BOT[0] - C_TOP[0]) * t),
      Math.round(C_TOP[1] + (C_BOT[1] - C_TOP[1]) * t),
      Math.round(C_TOP[2] + (C_BOT[2] - C_TOP[2]) * t),
    ]]);
  }
  const cCam = cover(dCam(x, y));
  const cCamOut = cover(dCam(x, y) - 5) * (1 - cCam);
  if (cCamOut > 0) layers.push([cCamOut, C_OUTLINE]);
  if (cCam > 0) layers.push([cCam, C_CREAM]);
  const cD1 = cover(dot(x, y, 874, 868, 26));
  if (cD1 > 0) layers.push([cD1, C_DOT1]);
  const cD2 = cover(dot(x, y, 916, 812, 14));
  if (cD2 > 0) layers.push([cD2, C_DOT2]);
  return layers;
}

function glyphMask(x, y) {
  return Math.min(dN(x, y), dCam(x, y), dot(x, y, 874, 868, 26), dot(x, y, 916, 812, 14));
}

// 华为图标网格：安全区是 324 画布里的 216，即 1024 下的 683。主体要落在遮罩圆内，
// 所以按距 bbox 中心的最大距离约束，只看外框不够。
const SAFE = Math.round((V * 216) / 324) - 6;
const fit = (() => {
  let x0 = 1e9, y0 = 1e9, x1 = -1e9, y1 = -1e9;
  for (let y = 0; y < V; y += 2) {
    for (let x = 0; x < V; x += 2) {
      if (glyphMask(x, y) > 0) continue;
      if (x < x0) x0 = x;
      if (x > x1) x1 = x;
      if (y < y0) y0 = y;
      if (y > y1) y1 = y;
    }
  }
  const cx = x0 + (x1 - x0) / 2, cy = y0 + (y1 - y0) / 2;
  let r = 0;
  for (let y = 0; y < V; y += 2) {
    for (let x = 0; x < V; x += 2) {
      if (glyphMask(x, y) > 0) continue;
      r = Math.max(r, Math.hypot(x - cx, y - cy));
    }
  }
  const k = SAFE / 2 / r;
  console.log('design bbox ' + Math.round(x1 - x0) + 'x' + Math.round(y1 - y0) +
    ' r=' + Math.round(r) + ' -> scale ' + k.toFixed(4) + ' (safe radius ' + SAFE / 2 + ')');
  return { cx, cy, k };
})();

// 以记号自身 bbox 中心等比缩放，落到画布中心。withInk=false 只出底板，分层图的背景层用它。
function render(n, opaqueBg, withInk) {
  const data = Buffer.alloc(n * n * 4);
  const s = V / n;
  for (let py = 0; py < n; py++) {
    for (let px = 0; px < n; px++) {
      const x = fit.cx + ((px + 0.5) * s - V / 2) / fit.k;
      const y = fit.cy + ((py + 0.5) * s - V / 2) / fit.k;
      let r = 0, g = 0, b = 0, a = 0;
      if (opaqueBg) { r = BG[0]; g = BG[1]; b = BG[2]; a = 1; }
      if (withInk !== false) {
        for (const [c, col] of layersAt(x, y)) {
          r = col[0] * c + r * (1 - c);
          g = col[1] * c + g * (1 - c);
          b = col[2] * c + b * (1 - c);
          a = c + a * (1 - c);
        }
      }
      const i = (py * n + px) * 4;
      if (a > 0) {
        data[i] = Math.round(r / a);
        data[i + 1] = Math.round(g / a);
        data[i + 2] = Math.round(b / a);
      }
      data[i + 3] = Math.round(a * 255);
    }
  }
  return data;
}

function inkStats(data, n) {
  let opaque = 0, painted = 0;
  let x0 = 1e9, y0 = 1e9, x1 = -1, y1 = -1;
  for (let py = 0; py < n; py++) {
    for (let px = 0; px < n; px++) {
      const a = data[py * n * 4 + px * 4 + 3];
      if (a === 255) opaque++;
      if (a > 8) {
        painted++;
        if (px < x0) x0 = px;
        if (px > x1) x1 = px;
        if (py < y0) y0 = py;
        if (py > y1) y1 = py;
      }
    }
  }
  return { opaque, painted, bbox: { x0, y0, x1, y1, w: x1 - x0 + 1, h: y1 - y0 + 1 } };
}

const ROOT = path.resolve(__dirname, '..');
const MEDIA = path.join(ROOT, 'AppScope', 'resources', 'base', 'media');

const ink = render(V, false);
const flat = render(V, true);

const jobs = [
  { f: path.join(MEDIA, 'foreground.png'), buf: ink },
  { f: path.join(MEDIA, 'background.png'), buf: render(V, true, false) },
  { f: path.join(MEDIA, 'app_icon.png'), buf: flat },
];
for (const j of jobs) {
  writePng(j.f, j.buf, V);
  const st = fs.statSync(j.f);
  const hdr = readSize(j.f);
  const s = inkStats(j.buf, V);
  console.log(path.relative(ROOT, j.f) + ' ' + hdr.w + 'x' + hdr.h + ' c' + hdr.color +
    ' ' + st.size + ' B opaque=' + s.opaque + '/' + (V * V) +
    ' painted=' + s.painted + ' bbox=' + s.bbox.w + 'x' + s.bbox.h +
    ' @' + s.bbox.x0 + ',' + s.bbox.y0);
}
fs.writeFileSync(path.join(MEDIA, 'app_layered_image.json'),
  '{\n  "layered-image": {\n    "background": "$media:background",\n    "foreground": "$media:foreground"\n  }\n}\n');
console.log('app_layered_image.json written');

if (process.env.PREVIEW) {
  const dir = process.env.PREVIEW;
  const grey = Buffer.alloc(V * V * 4);
  for (let i = 0; i < V * V; i++) {
    const a = ink[i * 4 + 3] / 255;
    for (let c = 0; c < 3; c++) {
      grey[i * 4 + c] = Math.round(ink[i * 4 + c] * a + 70 * (1 - a));
    }
    grey[i * 4 + 3] = 255;
  }
  writePng(path.join(dir, 'fg-on-grey.png'), grey, V);
  for (const n of [48, 96, 256]) writePng(path.join(dir, 'flat-' + n + '.png'), render(n, true), n);
  console.log('previews -> ' + dir);
}
