import { inputConsumer, KeyCode } from '@kit.InputKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { LogFn } from './ProbeLog';
import { hotkeyKeyNow, hotkeyModsNow } from '../common/ShotSettings';

// 全局快捷键走 inputConsumer.on('hotkeyChange')，文档无权限要求，PC/2in1 14+。preKeys 是修饰键集合
// （必填，1~4 个），finalKey 是被修饰的主键；4200002 表示被系统占用，4200003 表示已被别的应用订阅。
// 默认 Ctrl+1，可在“快捷键”里改成 Ctrl/Shift/Alt（最多两个）配 A~Z、0~9、F1~F12，只按存下的组合订阅。
// 左右修饰键的键码不同，每种修饰键左右各订一份（一个 2 组、两个 4 组），覆盖左 Ctrl 配右 Shift 这类混按。

const MOD_ORDER: string[] = ['ctrl', 'shift', 'alt'];
const MOD_LABEL: string[] = ['Ctrl', 'Shift', 'Alt'];
export const MOD_KEYS: string[] = MOD_ORDER;

export const KEY_LABELS: string[] = [
  'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M',
  'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z',
  '0', '1', '2', '3', '4', '5', '6', '7', '8', '9',
  'F1', 'F2', 'F3', 'F4', 'F5', 'F6', 'F7', 'F8', 'F9', 'F10', 'F11', 'F12'
];

const KEY_CODES: number[] = [
  KeyCode.KEYCODE_A, KeyCode.KEYCODE_B, KeyCode.KEYCODE_C, KeyCode.KEYCODE_D,
  KeyCode.KEYCODE_E, KeyCode.KEYCODE_F, KeyCode.KEYCODE_G, KeyCode.KEYCODE_H,
  KeyCode.KEYCODE_I, KeyCode.KEYCODE_J, KeyCode.KEYCODE_K, KeyCode.KEYCODE_L,
  KeyCode.KEYCODE_M, KeyCode.KEYCODE_N, KeyCode.KEYCODE_O, KeyCode.KEYCODE_P,
  KeyCode.KEYCODE_Q, KeyCode.KEYCODE_R, KeyCode.KEYCODE_S, KeyCode.KEYCODE_T,
  KeyCode.KEYCODE_U, KeyCode.KEYCODE_V, KeyCode.KEYCODE_W, KeyCode.KEYCODE_X,
  KeyCode.KEYCODE_Y, KeyCode.KEYCODE_Z,
  KeyCode.KEYCODE_0, KeyCode.KEYCODE_1, KeyCode.KEYCODE_2, KeyCode.KEYCODE_3,
  KeyCode.KEYCODE_4, KeyCode.KEYCODE_5, KeyCode.KEYCODE_6, KeyCode.KEYCODE_7,
  KeyCode.KEYCODE_8, KeyCode.KEYCODE_9,
  KeyCode.KEYCODE_F1, KeyCode.KEYCODE_F2, KeyCode.KEYCODE_F3, KeyCode.KEYCODE_F4,
  KeyCode.KEYCODE_F5, KeyCode.KEYCODE_F6, KeyCode.KEYCODE_F7, KeyCode.KEYCODE_F8,
  KeyCode.KEYCODE_F9, KeyCode.KEYCODE_F10, KeyCode.KEYCODE_F11, KeyCode.KEYCODE_F12
];

let subs: inputConsumer.HotkeyOptions[] = [];
let fireCount: number = 0;
// 开机注册时用的回调存在 lastFire：改键时沿用它，触发后的日志和截图流程与开机时一致，不必维护第二套路径。
let lastFire: ((source: string) => void) | null = null;

export function hotkeyActive(): boolean {
  return subs.length > 0;
}

export function modLabel(mod: string): string {
  const i: number = MOD_ORDER.indexOf(mod);
  return i < 0 ? mod : MOD_LABEL[i];
}

// 'ctrl+shift' 加 'A' 得到 'Ctrl + Shift + A'，界面、托盘提示、日志共用这一份说法。
export function hotkeyText(mods: string, key: string): string {
  const parts: string[] = mods.split('+');
  const out: string[] = [];
  for (let i = 0; i < parts.length; i++) {
    out.push(modLabel(parts[i]));
  }
  out.push(key);
  return out.join(' + ');
}

function keyCodeOf(key: string): number {
  const i: number = KEY_LABELS.indexOf(key);
  return i < 0 ? KeyCode.KEYCODE_1 : KEY_CODES[i];
}

function leftRightOf(mod: string): number[] {
  if (mod === 'shift') {
    return [KeyCode.KEYCODE_SHIFT_LEFT, KeyCode.KEYCODE_SHIFT_RIGHT];
  }
  if (mod === 'alt') {
    return [KeyCode.KEYCODE_ALT_LEFT, KeyCode.KEYCODE_ALT_RIGHT];
  }
  return [KeyCode.KEYCODE_CTRL_LEFT, KeyCode.KEYCODE_CTRL_RIGHT];
}

// 左右修饰键的笛卡尔积：一个修饰键 2 组，两个 4 组。
function preKeySets(mods: string): number[][] {
  let out: number[][] = [[]];
  const parts: string[] = mods.split('+');
  for (let i = 0; i < parts.length; i++) {
    const pair: number[] = leftRightOf(parts[i]);
    const next: number[][] = [];
    for (let a = 0; a < out.length; a++) {
      for (let b = 0; b < pair.length; b++) {
        const merged: number[] = out[a].slice();
        merged.push(pair[b]);
        next.push(merged);
      }
    }
    out = next;
  }
  return out;
}

// 返回订上的组数，0 表示这组组合一组都没订上（被占用、被别的应用订阅、设备不支持）。
function subscribe(log: LogFn, onFire: (source: string) => void, mods: string, key: string): number {
  const text: string = hotkeyText(mods, key);
  const finalKey: number = keyCodeOf(key);
  const sets: number[][] = preKeySets(mods);
  let ok: number = 0;
  for (let i = 0; i < sets.length; i++) {
    const opt: inputConsumer.HotkeyOptions = {
      preKeys: sets[i],
      finalKey: finalKey,
      isRepeat: false
    };
    // 每个订阅用各自的回调：多个键共用一个回调会让订阅失效。
    const cb = (opts: inputConsumer.HotkeyOptions): void => {
      fireCount++;
      // 前台标志由 EntryAbility.onForeground/onBackground 维护，这一行就是“真全局”的证明：
      // 前台=否 时还出现在这里，说明别的窗口 focused 也能触发。
      const fg: boolean | undefined = AppStorage.get<boolean>('appForeground');
      log(`快捷键 ${text} 触发 第${fireCount}次 本应用前台=${fg === true ? '是' : '否'}`
        + `（实际匹配 preKeys=${JSON.stringify(opts.preKeys)} finalKey=${opts.finalKey}）`);
      onFire(text);
    };
    try {
      inputConsumer.on('hotkeyChange', opt, cb);
      subs.push(opt);
      ok++;
    } catch (e) {
      const err = e as BusinessError;
      log(`快捷键 ${text} 第${i + 1}/${sets.length} 组订阅失败 code=${err.code} msg=${err.message}`
        + '（4200002=被系统占用，4200003=已被别的应用订阅）');
    }
  }
  return ok;
}

export function registerHotkey(log: LogFn, onFire: (source: string) => void): void {
  if (hotkeyActive()) {
    unregisterHotkey(log);
  }
  lastFire = onFire;
  const mods: string = hotkeyModsNow();
  const key: string = hotkeyKeyNow();
  const n: number = subscribe(log, onFire, mods, key);
  log(n > 0 ? `快捷键 ${hotkeyText(mods, key)} 已生效（左右修饰键共 ${n} 组）`
    : `快捷键 ${hotkeyText(mods, key)} 一组都没订上，截图入口只剩主界面按钮和托盘`);
}

// 改键时调用：先按新组合订，订不上退回旧的，不留“什么都没订上”的状态。
export function applyHotkey(log: LogFn, onFire: (source: string) => void,
  mods: string, key: string): boolean {
  const prevMods: string = hotkeyModsNow();
  const prevKey: string = hotkeyKeyNow();
  const fire: (source: string) => void = lastFire === null ? onFire : lastFire;
  unregisterHotkey(log);
  if (subscribe(log, fire, mods, key) > 0) {
    log(`快捷键已切换为 ${hotkeyText(mods, key)}`);
    return true;
  }
  const back: number = subscribe(log, fire, prevMods, prevKey);
  log(`快捷键没换成，已退回 ${hotkeyText(prevMods, prevKey)}${back > 0 ? '' : '（旧的那组这次也没订上）'}`);
  return false;
}

export function unregisterHotkey(log: LogFn): void {
  if (subs.length === 0) {
    return;
  }
  const n: number = subs.length;
  for (let i = 0; i < subs.length; i++) {
    try {
      inputConsumer.off('hotkeyChange', subs[i]);
    } catch (e) {
      const err = e as BusinessError;
      log(`取消订阅失败 code=${err.code} msg=${err.message}`);
    }
  }
  subs = [];
  log(`快捷键已全部取消订阅（${n} 组，累计触发 ${fireCount} 次）`);
}
