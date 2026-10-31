import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

export enum ShotFormat {
  PNG = 0,
  JPEG = 1,
  WEBP = 2
}

export function formatMime(f: ShotFormat): string {
  if (f === ShotFormat.JPEG) {
    return 'image/jpeg';
  }
  if (f === ShotFormat.WEBP) {
    return 'image/webp';
  }
  return 'image/png';
}

export function formatExt(f: ShotFormat): string {
  if (f === ShotFormat.JPEG) {
    return 'jpg';
  }
  if (f === ShotFormat.WEBP) {
    return 'webp';
  }
  return 'png';
}

export function formatLabel(f: ShotFormat): string {
  if (f === ShotFormat.JPEG) {
    return 'JPEG';
  }
  if (f === ShotFormat.WEBP) {
    return 'WebP';
  }
  return 'PNG';
}

// 打包文档写明质量参数只对 JPEG 有意义，PNG 和 WebP 都忽略，所以滑杆只在 JPEG 下可用。
// 取值仍是同一套范围，界面上只画一根滑杆，其余格式置灰。
export function qualityApplies(f: ShotFormat): boolean {
  return f === ShotFormat.JPEG;
}

// 质量项不生效时补一句说明，滑杆置灰后不至于没有任何解释。
export function qualityNote(f: ShotFormat): string {
  if (f === ShotFormat.JPEG) {
    return '';
  }
  if (f === ShotFormat.WEBP) {
    return '（WebP 打包时质量参数无效）';
  }
  return '（PNG 无质量参数）';
}

const STORE_NAME = 'ngshot';
const K_SAVE_DIR = 'saveDir';
const K_SAVE_DIR_URI = 'saveDirUri';
const K_SAVE_FORMAT = 'saveFormat';
const K_SAVE_QUALITY = 'saveQuality';
const K_CLIP_FORMAT = 'clipFormat';
const K_CLIP_QUALITY = 'clipQuality';
// 框选结束后的动作：“none”（默认，停在工具条）、“copy”、“save”、“pin”。
const K_AUTO_DO = 'autoDo';
// 记忆框选：记下上次定下的框，存 px 矩形和当时的图尺寸，下次启动按比例摆回。
const K_REMEMBER = 'rememberBand';
const K_BAND = 'lastBand';
// 参考线：“none”、“thirds”（九宫格）、“golden”（黄金比例）。
const K_GUIDES = 'guides';
// 框选时是否标出四角坐标，默认标。
const K_CORNERS = 'showCorners';
// 界面深浅色：“system”（默认，跟随系统）、“light”、“dark”。
const K_THEME = 'themeMode';
// 全局快捷键：修饰键集合（“ctrl”、“ctrl+shift”、“alt”）加主键（“A”、“1”、“F1”）。
// 和别的偏好一起初始化，开机即可用，所以放在本模块。
const K_HOTKEY_MODS = 'hotkeyMods';
const K_HOTKEY_KEY = 'hotkeyKey';

let store: preferences.Preferences | null = null;
let saveDir: string = '';
// 选择器返回 file://docs/... 形式的 URI，持久化授权以 URI 为准而不是纯路径，所以两份都存。
let saveDirUri: string = '';
let saveFormat: ShotFormat = ShotFormat.PNG;
let saveQuality: number = 90;
let clipFormat: ShotFormat = ShotFormat.PNG;
let clipQuality: number = 90;
let autoDo: string = 'none';
let rememberBand: boolean = false;
let lastBand: string = '';
let guides: string = 'none';
let corners: boolean = true;
let themeMode: string = 'system';
let hotkeyMods: string = 'ctrl';
let hotkeyKey: string = '1';

function asAutoDo(v: preferences.ValueType): string {
  const s: string = String(v);
  if (s === 'copy' || s === 'save' || s === 'pin') {
    return s;
  }
  return 'none';
}

// 设置页与框选层共用这份文案，日志和界面显示一致。
export function autoDoLabel(v: string): string {
  if (v === 'copy') {
    return '复制到剪贴板';
  }
  if (v === 'save') {
    return '保存成文件';
  }
  if (v === 'pin') {
    return '贴到屏幕上';
  }
  return '不做动作';
}

function asFormat(v: preferences.ValueType): ShotFormat {
  const n: number = typeof v === 'number' ? v : Number.parseInt(String(v), 10);
  if (n === ShotFormat.JPEG || n === ShotFormat.WEBP) {
    return n;
  }
  return ShotFormat.PNG;
}

function asQuality(v: preferences.ValueType): number {
  const n: number = typeof v === 'number' ? v : Number.parseInt(String(v), 10);
  if (Number.isNaN(n) || n < 10 || n > 100) {
    return 90;
  }
  return n;
}

function asGuide(v: preferences.ValueType): string {
  const s: string = String(v);
  if (s === 'thirds' || s === 'golden') {
    return s;
  }
  return 'none';
}

function asTheme(v: preferences.ValueType): string {
  const s: string = String(v);
  if (s === 'light' || s === 'dark') {
    return s;
  }
  return 'system';
}

// 修饰键只认 ctrl / shift / alt，顺序固定为 ctrl、shift、alt，界面和日志里是同一个串。
export function asMods(v: string): string {
  const parts: string[] = v.split('+');
  const out: string[] = [];
  const order: string[] = ['ctrl', 'shift', 'alt'];
  for (let i = 0; i < order.length; i++) {
    if (parts.indexOf(order[i]) >= 0) {
      out.push(order[i]);
    }
  }
  if (out.length === 0) {
    return 'ctrl';
  }
  return out.slice(0, 2).join('+');
}

export function guideLabel(v: string): string {
  if (v === 'thirds') {
    return '九宫格';
  }
  if (v === 'golden') {
    return '黄金比例';
  }
  return '无';
}

// 启动时把各项开关写进一行日志，缺了记忆框选这类状态容易误判。
export async function initSettings(ctx: common.Context, log: (line: string) => void): Promise<void> {
  try {
    store = await preferences.getPreferences(ctx, STORE_NAME);
    saveDir = await store.get(K_SAVE_DIR, '') as string;
    saveDirUri = await store.get(K_SAVE_DIR_URI, '') as string;
    saveFormat = asFormat(await store.get(K_SAVE_FORMAT, ShotFormat.PNG));
    saveQuality = asQuality(await store.get(K_SAVE_QUALITY, 90));
    clipFormat = asFormat(await store.get(K_CLIP_FORMAT, ShotFormat.PNG));
    clipQuality = asQuality(await store.get(K_CLIP_QUALITY, 90));
    autoDo = asAutoDo(await store.get(K_AUTO_DO, 'none'));
    rememberBand = await store.get(K_REMEMBER, false) as boolean;
    lastBand = await store.get(K_BAND, '') as string;
    guides = asGuide(await store.get(K_GUIDES, 'none'));
    corners = await store.get(K_CORNERS, true) as boolean;
    themeMode = asTheme(await store.get(K_THEME, 'system'));
    hotkeyMods = asMods(String(await store.get(K_HOTKEY_MODS, 'ctrl')));
    hotkeyKey = String(await store.get(K_HOTKEY_KEY, '1'));
    log(`设置已载入 保存=${formatLabel(saveFormat)} q=${saveQuality} 目录=${saveDir === '' ? '(默认)' : saveDir}`
      + ` 剪贴板=${formatLabel(clipFormat)} q=${clipQuality} 框选后=${autoDoLabel(autoDo)}`
      + ` 记忆框选=${rememberBand ? '开' : '关'} 参考线=${guideLabel(guides)}`
      + ` 四角坐标=${corners ? '显示' : '不显示'} 主题=${themeMode}`
      + ` 快捷键=${hotkeyMods}+${hotkeyKey}`);
  } catch (e) {
    const err = e as BusinessError;
    log(`设置载入失败 code=${err.code} msg=${err.message}，用默认值`);
  }
}

function dirOf(ctx: common.Context): string {
  return saveDir === '' ? `${ctx.filesDir}/screenshots` : saveDir;
}

export async function persist(log: (line: string) => void): Promise<void> {
  if (store === null) {
    log('设置还没初始化，写入被忽略');
    return;
  }
  try {
    await store.put(K_SAVE_DIR, saveDir);
    await store.put(K_SAVE_DIR_URI, saveDirUri);
    await store.put(K_SAVE_FORMAT, saveFormat);
    await store.put(K_SAVE_QUALITY, saveQuality);
    await store.put(K_CLIP_FORMAT, clipFormat);
    await store.put(K_CLIP_QUALITY, clipQuality);
    await store.put(K_AUTO_DO, autoDo);
    await store.put(K_REMEMBER, rememberBand);
    await store.put(K_BAND, lastBand);
    await store.put(K_GUIDES, guides);
    await store.put(K_CORNERS, corners);
    await store.put(K_THEME, themeMode);
    await store.put(K_HOTKEY_MODS, hotkeyMods);
    await store.put(K_HOTKEY_KEY, hotkeyKey);
    await store.flush();
  } catch (e) {
    const err = e as BusinessError;
    log(`设置写入失败 code=${err.code} msg=${err.message}`);
  }
}

export function setSaveDir(ctx: common.Context, plainPath: string, uri: string,
  log: (line: string) => void): void {
  saveDir = plainPath;
  saveDirUri = uri;
  log(`保存目录 -> ${dirOf(ctx)}`);
  persist(log);
}

export function saveDirUriNow(): string {
  return saveDirUri;
}

export function setSaveFormat(ctx: common.Context, f: ShotFormat, log: (line: string) => void): void {
  saveFormat = f;
  log(`保存格式 -> ${formatLabel(f)} ${qualityNote(f) === '' ? `q=${saveQuality}` : qualityNote(f)}`);
  persist(log);
}

export function setSaveQuality(ctx: common.Context, q: number, log: (line: string) => void): void {
  saveQuality = q;
  log(`保存质量 -> ${q}`);
  persist(log);
}

export function setClipFormat(ctx: common.Context, f: ShotFormat, log: (line: string) => void): void {
  clipFormat = f;
  log(`剪贴板格式 -> ${formatLabel(f)} ${qualityNote(f) === '' ? `q=${clipQuality}` : qualityNote(f)}`);
  persist(log);
}

export function setClipQuality(ctx: common.Context, q: number, log: (line: string) => void): void {
  clipQuality = q;
  log(`剪贴板质量 -> ${q}`);
  persist(log);
}

export function saveTargetDir(ctx: common.Context): string {
  return dirOf(ctx);
}

export function saveFormatNow(): ShotFormat {
  return saveFormat;
}

export function saveQualityNow(): number {
  return saveQuality;
}

export function clipFormatNow(): ShotFormat {
  return clipFormat;
}

export function clipQualityNow(): number {
  return clipQuality;
}

export function autoDoNow(): string {
  return autoDo;
}

export function setAutoDo(ctx: common.Context, v: string, log: (line: string) => void): void {
  autoDo = asAutoDo(v);
  log(`框选后自动 -> ${autoDoLabel(autoDo)}`);
  persist(log);
}

export function rememberBandNow(): boolean {
  return rememberBand;
}

export function setRememberBand(ctx: common.Context, v: boolean, log: (line: string) => void): void {
  rememberBand = v;
  log(v ? `记忆框选 -> 开（现在记着 ${lastBand === '' ? '还没有框' : lastBand}）` : '记忆框选 -> 关');
  persist(log);
}

// 定下框时调用一次，开关打开才写盘，否则每次框选都要多一次 flush。
// 存 px 矩形和当时的图尺寸，下次按比例摆回，窗口或分辨率变了框也对得上。
export function noteBand(x: number, y: number, w: number, h: number, imgW: number, imgH: number,
  log: (line: string) => void): void {
  if (!rememberBand || w <= 0 || h <= 0 || imgW <= 0 || imgH <= 0) {
    return;
  }
  const s: string = `${x},${y},${w},${h},${imgW},${imgH}`;
  if (s === lastBand) {
    return;
  }
  lastBand = s;
  log(`记忆框选 -> ${s}`);
  persist(log);
}

// 返回 [x, y, w, h, imgW, imgH]；没记过就是空数组。
export function lastBandNow(): number[] {
  if (lastBand === '') {
    return [];
  }
  const parts: string[] = lastBand.split(',');
  if (parts.length !== 6) {
    return [];
  }
  const out: number[] = [];
  for (let i = 0; i < parts.length; i++) {
    const n: number = Number.parseInt(parts[i], 10);
    if (Number.isNaN(n)) {
      return [];
    }
    out.push(n);
  }
  return out;
}

export function guidesNow(): string {
  return guides;
}

export function setGuides(ctx: common.Context, v: string, log: (line: string) => void): void {
  guides = asGuide(v);
  log(`框选参考线 -> ${guideLabel(guides)}`);
  persist(log);
}

export function cornersNow(): boolean {
  return corners;
}

export function setCorners(ctx: common.Context, v: boolean, log: (line: string) => void): void {
  corners = v;
  log(`四角坐标 -> ${v ? '显示' : '不显示'}`);
  persist(log);
}

export function themeNow(): string {
  return themeMode;
}

export function setTheme(ctx: common.Context, v: string, log: (line: string) => void): void {
  themeMode = asTheme(v);
  log(`界面主题 -> ${themeMode === 'system' ? '跟随系统' : themeMode === 'dark' ? '深色' : '浅色'}`);
  persist(log);
}

export function hotkeyModsNow(): string {
  return hotkeyMods;
}

export function hotkeyKeyNow(): string {
  return hotkeyKey;
}

export function setHotkeySpec(ctx: common.Context, mods: string, key: string,
  log: (line: string) => void): void {
  hotkeyMods = asMods(mods);
  hotkeyKey = key;
  log(`快捷键 -> ${hotkeyMods}+${hotkeyKey}`);
  persist(log);
}
