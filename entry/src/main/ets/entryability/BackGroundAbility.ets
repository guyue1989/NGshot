import { UIAbility } from '@kit.AbilityKit';
import { ProbeLog } from '../probe/ProbeLog';

// 只为「把进程钉在状态栏图标上」而存在的能力，没有界面也不进启动列表。
// 为什么不能由主能力自己拉自己绑定：指定 processMode 重复拉起一个正在运行的 singleton
// 会返回 16000068（The ability is already running），所以绑定的目标必须是一个平时不跑的能力。
// 它和主能力同进程，attach 绑定的是进程，所以主能力的窗口收起后快捷键照样在。
export default class BackGroundAbility extends UIAbility {
  onCreate(): void {
    ProbeLog.add('BackGroundAbility onCreate（绑定状态栏图标用，无界面）');
  }

  onWindowStageCreate(): void {
    // 不调 loadContent：没有内容就没有可显示的界面，窗口由 STARTUP_HIDE 挡在屏幕外。
  }

  onDestroy(): void {
    ProbeLog.add('BackGroundAbility onDestroy');
  }
}
