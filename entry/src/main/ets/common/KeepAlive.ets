import backgroundTaskManager from '@ohos.backgroundTaskManager';
import wantAgent from '@ohos.app.ability.wantAgent';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

export type KeepAliveLog = (line: string) => void;

const BUNDLE_NAME: string = 'com.niangao.ngshot';
const MAIN_ABILITY: string = 'EntryAbility';
// 应用已持有长时任务时 startBackgroundRunning 返回这个码，它不是拒绝；当成拒绝会让下一种模式
// 再叠一个任务上去。
const ALREADY_APPLIED: number = 9800005;
// taskKeeping 是 PC/2in1 的后台计算类型（API 20 起对三方开放），不要求持有者上报进度。
// dataTransfer 是兜底模式，但约十分钟没有可见窗口的进度更新系统就会取消，只能算备选。
const MODES: backgroundTaskManager.BackgroundMode[] = [
  backgroundTaskManager.BackgroundMode.TASK_KEEPING,
  backgroundTaskManager.BackgroundMode.DATA_TRANSFER
];
// 枚举数值未承诺稳定，日志里按名字记录。
const MODE_NAMES: string[] = ['taskKeeping', 'dataTransfer'];

let held: boolean = false;

async function agent(ctx: common.UIAbilityContext): Promise<object> {
  const info: wantAgent.WantAgentInfo = {
    wants: [{ bundleName: BUNDLE_NAME, abilityName: MAIN_ABILITY }],
    operationType: wantAgent.OperationType.START_ABILITY,
    requestCode: 0,
    wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
  };
  return await wantAgent.getWantAgent(info);
}

// 不持有长时任务时，窗口一收进状态栏系统就挂起进程，而挂起的进程无法响应全局快捷键，
// 那是窗口收起后本应用唯一的入口。
// 每次启动都重新申请而不是记住状态：本 SDK 没有长时任务的取消回调，被系统收回的任务
// 会永远留在“已持有”的记录里。
export async function startKeepAlive(log: KeepAliveLog, ctx: common.UIAbilityContext): Promise<boolean> {
  try {
    const agentObj: object = await agent(ctx);
    for (let i = 0; i < MODES.length; i++) {
      const mode: backgroundTaskManager.BackgroundMode = MODES[i];
      const label: string = MODE_NAMES[i];
      try {
        await backgroundTaskManager.startBackgroundRunning(ctx, mode, agentObj);
        held = true;
        log(`长时任务已持有 mode=${label}`);
        return true;
      } catch (e) {
        const err = e as BusinessError;
        if (err.code === ALREADY_APPLIED) {
          held = true;
          log(`长时任务本来就在持有（9800005）mode=${label}`);
          return true;
        }
        log(`startBackgroundRunning mode=${label} 被拒 code=${err.code} msg=${err.message}`
          + '（201=没拿到 KEEP_BACKGROUND_RUNNING）');
      }
    }
    return false;
  } catch (e) {
    const err = e as BusinessError;
    log(`长时任务入口异常 code=${err.code} msg=${err.message}`);
    return false;
  }
}

export async function stopKeepAlive(log: KeepAliveLog, ctx: common.UIAbilityContext): Promise<void> {
  if (!held) {
    return;
  }
  held = false;
  try {
    await backgroundTaskManager.stopBackgroundRunning(ctx);
    log('长时任务已释放');
  } catch (e) {
    const err = e as BusinessError;
    log(`stopBackgroundRunning 失败 code=${err.code} msg=${err.message}`);
  }
}
