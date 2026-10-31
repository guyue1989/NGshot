import { screenshot, window } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { abilityAccessCtrl, bundleManager, common, Permissions, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ShotLog, canonicalPng, setShotBuffer, beginScreenBuffer, endScreenBuffer, dropScreenBuffer,
  setCaptureMap, disposeShot } from './ShotService';
import { startKeepAlive, stopKeepAlive } from './KeepAlive';

export const BUNDLE_NAME: string = 'com.niangao.ngshot';
const RESULT_ABILITY: string = 'ResultAbility';
const SELECT_ABILITY: string = 'SelectAbility';
const CAPTURE_PERM: Permissions = 'ohos.permission.CUSTOM_SCREEN_CAPTURE';

// capture() 之前必须让 hideAbility() 的窗口真正离开屏幕，否则截图里会带上自家主界面。
// CaptureOption.blackWindowIds 只管闪控球窗口，同一时刻直接 capture 照样拍到窗，所以留 400ms 收窗。
const HIDE_SETTLE_MS: number = 400;

let busy: boolean = false;
let busySince: number = 0;
let busyStage: string = '';

// 这一张从“主窗开着”的状态发起：拍完主窗被收掉，框选结束要放回来，否则用户在应用里按的快捷键，
// Esc 之后人却落到桌面。
let restoreAfter: boolean = false;

// 框选层的出口调用：可见状态发起的那一张在结束（取消、复制、保存）后把主窗放回来；
// 从状态栏或热键收起态发起的流程标志为 false，窗口本就该留在状态栏，此时什么也不做。
//
// 返回 Promise 是为了可控顺序：打开结果窗那条出口要先放回主窗再拉结果窗，
// 反了会被随后 showAbility 唤回的主窗盖住。
async function restoreIfStartedVisible(log: ShotLog): Promise<void> {
  if (!restoreAfter) {
    return;
  }
  restoreAfter = false;
  const ctx: common.UIAbilityContext | undefined =
    AppStorage.get<common.UIAbilityContext>('abilityContext');
  if (ctx === undefined) {
    log('没有主能力上下文，主窗没法自动放回来（用状态栏图标的右键菜单打开主界面）');
    return;
  }
  try {
    await ctx.showAbility();
    AppStorage.setOrCreate('abilityHidden', false);
    log('这一张是从可见状态发起的，主窗已放回来');
    void stopKeepAlive(log, ctx);
  } catch (e) {
    const err = e as BusinessError;
    log(`主窗放回来失败 code=${err.code} msg=${err.message}`);
  }
}

// 采集期间 Ctrl+1 从“再来一张”变为“停止采集”：框选层此时缩成角落小面板，按钮不一定点得到，
// 全局热键是始终可用的出口。钩子由 SelectPage 在会话开始注册、结束清空，ShotFlow 不涉及拼接细节。
let scrollStopHook: (() => void) | null = null;

export function setScrollStopHook(hook: (() => void) | null): void {
  scrollStopHook = hook;
}

// 阶段打点：busy 卡在 true 会让本进程内后续的 Ctrl+1 全部失效，而只报“上一次流程还没结束”看不出卡在哪里。
// 每个打点占一行，日志里最后出现的那个就是没能返回的阶段。
function mark(log: ShotLog, stage: string): void {
  busyStage = stage;
  log(`流程打点：${stage}`);
}

function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(resolve, ms);
  });
}

// CUSTOM_SCREEN_CAPTURE 自 API 14 起在 PC/2in1 上是 user_grant，未授权时 capture() 抛 201。
async function ensureCapturePerm(log: ShotLog, ctx: common.UIAbilityContext): Promise<boolean> {
  const at = abilityAccessCtrl.createAtManager();
  try {
    const info = bundleManager.getBundleInfoForSelfSync(
      bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
    const status = at.checkAccessTokenSync(info.appInfo.accessTokenId, CAPTURE_PERM);
    if (status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
      return true;
    }
    log('截屏权限还没给，弹系统申请');
    const res = await at.requestPermissionsFromUser(ctx, [CAPTURE_PERM]);
    const ok: boolean = res.authResults.length > 0 && res.authResults[0] === 0;
    log(ok ? '截屏权限已授' : `截屏权限没拿到 authResults=${JSON.stringify(res.authResults)}，不截了`);
    return ok;
  } catch (e) {
    const err = e as BusinessError;
    log(`截屏权限检查失败 code=${err.code} msg=${err.message}`);
    return false;
  }
}

// 截图里不能有本应用。结果窗属于兄弟能力，直接 terminateSelf 即可，它的字节本来也要被丢弃。
async function closeResultWindow(log: ShotLog): Promise<void> {
  const c: common.UIAbilityContext | undefined = AppStorage.get<common.UIAbilityContext>('resultAbilityContext');
  if (c === undefined) {
    return;
  }
  try {
    c.terminateSelf();
    log('结果窗还开着，已先收掉它（别让编辑窗进下一张截图）');
  } catch (e) {
    const err = e as BusinessError;
    log(`收结果窗失败 code=${err.code} msg=${err.message}`);
  }
}

// 返回这次是否真的收了窗：已经收着时调用方不必再等 400ms，屏幕上本来没有东西要消失。
async function hideSelf(log: ShotLog, ctx: common.UIAbilityContext): Promise<boolean> {
  if (AppStorage.get<boolean>('abilityHidden') === true) {
    return false;
  }
  try {
    await ctx.hideAbility();
    AppStorage.setOrCreate('abilityHidden', true);
    log('主窗已 hideAbility 收起');
    // 收起后进程要在后台等下一次热键或托盘点击，没有长时任务会被系统挂起，热键随之失效。
    void startKeepAlive(log, ctx);
    return true;
  } catch (e) {
    const err = e as BusinessError;
    log(`hideAbility 失败 code=${err.code} msg=${err.message}，退 minimize`);
    const win: window.Window | undefined = AppStorage.get<window.Window>('mainWindow');
    if (win === undefined) {
      log('也没有主窗口句柄，这一张可能把自己拍进去');
      return false;
    }
    try {
      await win.minimize();
    } catch (e2) {
      const err2 = e2 as BusinessError;
      log(`minimize 也失败 code=${err2.code} msg=${err2.message}`);
    }
    return false;
  }
}

async function startSibling(log: ShotLog, ctx: common.UIAbilityContext, name: string): Promise<boolean> {
  const target: Want = {
    bundleName: BUNDLE_NAME,
    abilityName: name
  };
  try {
    await ctx.startAbility(target);
    log(`startAbility(${name}) 成功返回（隐藏态可拉起兄弟能力）`);
    return true;
  } catch (e) {
    const err = e as BusinessError;
    log(`拉起 ${name} 失败 code=${err.code} msg=${err.message}`
      + '（10xxx 里若有「后台拉起被拒」就说明隐藏态能力不能起别的窗，得改成先 showAbility）');
    return false;
  }
}

// 主流程：快捷键、收窗、capture() 全屏、全屏层自绘框选、裁选区、结果窗。
// 主干不用 pick()：本机上它可能不再返回，并在系统截图服务里留下只有重启才清掉的会话，
// 多调一次还会污染后续每次调用。capture() 更快且不弹系统界面。
//
// selfInShot 表示这张是否要把本应用拍进去。主界面开着时按快捷键或点“立即截一张”，用户往往就是要
// 截自己的界面，于是先拍再收窗；窗口已经收在状态栏时先收窗再拍，画面里不留自家窗。
// 不传则按 AppStorage 里的收起标志判断。
export async function captureToOverlay(log: ShotLog, ctx: common.UIAbilityContext,
  selfInShot?: boolean): Promise<void> {
  if (busy) {
    if (scrollStopHook !== null) {
      const hook: () => void = scrollStopHook;
      scrollStopHook = null;
      log('长截图正在采集，这次 Ctrl+1 当作「停止采集」');
      hook();
      return;
    }
    log(`上一次截图流程还没结束，忽略本次触发（停在「${busyStage}」已 ${Date.now() - busySince}ms）`);
    return;
  }
  const hidden: boolean = AppStorage.get<boolean>('abilityHidden') === true;
  const wantSelf: boolean = selfInShot === undefined ? !hidden : selfInShot;
  restoreAfter = wantSelf;
  busy = true;
  busySince = Date.now();
  const t0: number = Date.now();
  let handedOver: boolean = false;
  try {
    mark(log, '检查截屏权限');
    if (!await ensureCapturePerm(log, ctx)) {
      return;
    }
    mark(log, '收起自家窗口');
    await closeResultWindow(log);
    if (wantSelf) {
      // 要拍自己：此刻先不收窗，拍完再收。收窗只须赶在框选层上屏之前完成，那 400ms 等待是给
      // “收完再拍”用的，这条路不必等。
      log('主窗还在屏上，先拍再收：这一张会包含本应用界面');
    } else {
      const hid: boolean = await hideSelf(log, ctx);
      if (hid) {
        await delay(HIDE_SETTLE_MS);
      } else {
        log('主窗本来就收着，不用等上屏');
      }
    }
    mark(log, 'capture() 已发起');
    const pm = await screenshot.capture();
    const meta = pm.getImageInfoSync();
    log(`capture 完成 ${meta.size.width}x${meta.size.height} 耗时 ${Date.now() - t0}ms`
      + `（含本应用=${wantSelf ? '是' : '否'}）`);
    if (wantSelf) {
      // 拍完再收窗：框选层是全屏的，主窗在它下面停留一瞬也看不见，此处也不必再等 400ms。
      await hideSelf(log, ctx);
    }
    const gen: number = beginScreenBuffer();
    // 上屏不等 PNG：capture 的 PixelMap 直接交给框选层（同进程模块持有）当底图，PNG 在后台编，
    // 用户拖框的时间足够编完。整屏固化需 537~770ms，真正占时的因此只剩 capture 本身和拉窗。
    setCaptureMap(pm);
    AppStorage.setOrCreate('screenWidth', meta.size.width);
    AppStorage.setOrCreate('screenHeight', meta.size.height);
    AppStorage.setOrCreate('selectStatus', '');
    mark(log, `startAbility(${SELECT_ABILITY}) 已发起`);
    const started: boolean = await startSibling(log, ctx, SELECT_ABILITY);
    if (!started) {
      setCaptureMap(null);
      disposeShot(pm);
      return;
    }
    void encodeScreenPng(pm, gen, log);
    // 从这里起锁交给框选层，由 dropSelectLock 或 cancelSelect 释放。
    handedOver = true;
    mark(log, '等用户在全屏层里框选');
    log(`热键到框选层上屏 ${Date.now() - t0}ms`);
  } catch (e) {
    const err = e as BusinessError;
    log(`流程在「${busyStage}」抛异常 code=${err.code} msg=${err.message}`
      + '（capture 阶段：201=没截屏权限，801=设备不支持）');
  } finally {
    if (!handedOver) {
      busy = false;
      log(`流程结束，总耗时 ${Date.now() - t0}ms`);
      // 没交出去就没有框选层接管这个标志，主窗要自己放回来，否则一次 Ctrl+1 失败应用就从屏幕上消失。
      void restoreIfStartedVisible(log);
    }
  }
}

// 状态栏图标左键：只负责把框选层叫起来，拍屏由 captureForTrayOverlay 在那边做。
// 主窗还开着就先收掉：这一张不该把本应用拍进去，框选层也不该压着主窗出现。
export async function requestTrayCapture(log: ShotLog, ctx: common.UIAbilityContext): Promise<void> {
  if (busy) {
    log(`上一次截图流程还没结束，托盘这一下忽略（停在「${busyStage}」已 ${Date.now() - busySince}ms）`);
    return;
  }
  if (AppStorage.get<boolean>('abilityHidden') !== true) {
    try {
      await ctx.hideAbility();
      AppStorage.setOrCreate('abilityHidden', true);
      log('主窗还在屏上，先 hideAbility 收起，这一张不拍本应用');
      void startKeepAlive(log, ctx);
    } catch (e) {
      const err = e as BusinessError;
      log(`hideAbility 失败 code=${err.code} msg=${err.message}，这一张会带上本应用界面`);
    }
    await delay(HIDE_SETTLE_MS);
  }
  const params: Record<string, Object> = { 'ngCapture': '1' };
  const target: Want = {
    bundleName: BUNDLE_NAME,
    abilityName: SELECT_ABILITY,
    parameters: params
  };
  try {
    await ctx.startAbility(target);
    log('托盘左键：框选层已拉起（由它自己拍屏）');
  } catch (e) {
    const err = e as BusinessError;
    log(`托盘左键拉起框选层失败 code=${err.code} msg=${err.message}`);
  }
}

// 状态栏图标左键的第二段：框选层自己拍，拍完再上屏，屏幕上全程不出现主界面。
// 调用它之前主窗要先 hideAbility，否则这一张会把本应用界面拍进去。
// 返回 false 时调用方要把框选层收掉，别留一张空的全屏窗。
export async function captureForTrayOverlay(log: ShotLog, ctx: common.UIAbilityContext): Promise<boolean> {
  if (busy) {
    log(`上一次截图流程还没结束，托盘这一张不拍了（停在「${busyStage}」已 ${Date.now() - busySince}ms）`);
    return false;
  }
  busy = true;
  busySince = Date.now();
  busyStage = '';
  restoreAfter = false;
  const t0: number = Date.now();
  let handedOver: boolean = false;
  try {
    mark(log, '检查截屏权限');
    if (!await ensureCapturePerm(log, ctx)) {
      return false;
    }
    mark(log, '收起自家窗口');
    await closeResultWindow(log);
    if (AppStorage.get<boolean>('abilityHidden') === true) {
      log('主窗本来就收着，直接拍');
    } else {
      // 主界面还开着时点托盘图标：这一张也不该把自家窗口拍进去，收掉后不再放回来。
      const main: common.UIAbilityContext | undefined =
        AppStorage.get<common.UIAbilityContext>('abilityContext');
      if (main === undefined) {
        log('没有主能力上下文，这一张可能带上本应用界面');
      } else {
        try {
          await main.hideAbility();
          AppStorage.setOrCreate('abilityHidden', true);
          log('主窗还在屏上，先 hideAbility 收起，这一张不拍本应用');
          void startKeepAlive(log, main);
        } catch (e) {
          const err = e as BusinessError;
          log(`hideAbility 失败 code=${err.code} msg=${err.message}，这一张会带上本应用界面`);
        }
        await delay(HIDE_SETTLE_MS);
      }
    }
    mark(log, 'capture() 已发起');
    const pm = await screenshot.capture();
    const meta = pm.getImageInfoSync();
    log(`capture 完成 ${meta.size.width}x${meta.size.height} 耗时 ${Date.now() - t0}ms（含本应用=否）`);
    const gen: number = beginScreenBuffer();
    setCaptureMap(pm);
    AppStorage.setOrCreate('screenWidth', meta.size.width);
    AppStorage.setOrCreate('screenHeight', meta.size.height);
    AppStorage.setOrCreate('selectStatus', '');
    void encodeScreenPng(pm, gen, log);
    busyStage = '等用户在全屏层里框选';
    handedOver = true;
    log(`托盘到框选层就绪 ${Date.now() - t0}ms`);
    return true;
  } catch (e) {
    const err = e as BusinessError;
    log(`托盘截图在「${busyStage}」抛异常 code=${err.code} msg=${err.message}`
      + '（201=没截屏权限，801=设备不支持）');
    return false;
  } finally {
    if (!handedOver) {
      busy = false;
      busyStage = '';
      dropScreenBuffer();
    }
  }
}

// 提速的后台一半：框选层绘制实时 PixelMap，裁选区从 PNG 解码。
// 先 clone()，因为 packToData 会消耗传入的 map，而框选层那份要活过编码。
async function encodeScreenPng(pm: image.PixelMap, gen: number, log: ShotLog): Promise<void> {
  const t0: number = Date.now();
  try {
    const copy: image.PixelMap = await pm.clone();
    const bytes: ArrayBuffer | null = await canonicalPng(copy, log);
    endScreenBuffer(bytes, gen, log);
    log(`全屏 PNG 后台编完 ${Date.now() - t0}ms${bytes === null ? '（失败，裁不了选区）' : ''}`);
  } catch (e) {
    const err = e as BusinessError;
    log(`全屏 PNG 后台编失败 code=${err.code} msg=${err.message}，裁不了选区`);
  }
}

// 框选层出口之一：交回选区和尺寸，拉起结果窗。两条出口都要放锁，下一次 Ctrl+1 才能生效。
export async function finishSelect(log: ShotLog, ctx: common.UIAbilityContext, bytes: ArrayBuffer,
  w: number, h: number): Promise<void> {
  busy = false;
  busyStage = '';
  dropScreenBuffer();
  setShotBuffer(bytes);
  // 必须在拉起窗口前写入：结果页在自己的 aboutToAppear 里读取这些值，两个能力同进程
  // （声明里没有 process 字段），可通过 AppStorage 直传。
  AppStorage.setOrCreate('shotStatus', '');
  AppStorage.setOrCreate('shotSize', `${w}x${h}`);
  AppStorage.setOrCreate('shotWidth', w);
  AppStorage.setOrCreate('shotHeight', h);
  log(`选区已就绪 ${w}x${h}，打开结果窗`);
  // 先放回主窗再拉结果窗：结果窗是后起的新窗，天然压在主窗上面。
  await restoreIfStartedVisible(log);
  if (!await startSibling(log, ctx, RESULT_ABILITY)) {
    log('结果窗没起来，选区字节还留着，可以再按一次 Ctrl+1');
  }
}

// 框选层工具栏的直接出口（复制、保存，不起结果窗）。两个出口都放锁，下一次 Ctrl+1 才能生效。
export function dropSelectLock(log: ShotLog): void {
  busy = false;
  busyStage = '';
  dropScreenBuffer();
  log('选区已处理完，锁已放');
  void restoreIfStartedVisible(log);
}

// 框选层还攥着锁吗：SelectAbility 用它判断「窗口都失焦了流程还挂着」要不要按取消收场。
export function isSelectFlowBusy(): boolean {
  return busy;
}

export function cancelSelect(log: ShotLog, restore: boolean = true): void {
  busy = false;
  busyStage = '';
  dropScreenBuffer();
  log('已取消框选，锁已放');
  if (restore) {
    void restoreIfStartedVisible(log);
    return;
  }
  // 用户是自己点去别的窗口的，别把主窗塞回前台；标志也要清掉，否则下一次热键会按旧起点判断。
  restoreAfter = false;
}
