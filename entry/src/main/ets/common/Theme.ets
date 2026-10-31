import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { themeNow } from './ShotSettings';

// 界面深浅色用资源分流加应用级颜色模式：颜色都在 resources/base/element/color.json（浅色）与
// resources/dark/element/color.json（深色）的同名 ng_* 令牌上，页面只写 $r('app.color.ng_xxx')，
// 切换模式时不需要通知页面重绘。setColorMode 要求 API 11+（PC/2in1 为 13+）、只能主线程调用，
// 且必须在窗口创建和页面加载完成之后调，所以调用点都在 loadContent 回调之后；COLOR_MODE_NOT_SET 即跟随系统。

export function themeLabel(mode: string): string {
  if (mode === 'dark') {
    return '深色';
  }
  if (mode === 'light') {
    return '浅色';
  }
  return '跟随系统';
}

function toColorMode(mode: string): ConfigurationConstant.ColorMode {
  if (mode === 'dark') {
    return ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  }
  if (mode === 'light') {
    return ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
  }
  return ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
}

export function applyTheme(ctx: common.Context, mode: string, log: (line: string) => void): void {
  try {
    ctx.getApplicationContext().setColorMode(toColorMode(mode));
    log(`界面主题已切到「${themeLabel(mode)}」`);
  } catch (e) {
    const err = e as BusinessError;
    log(`切换界面主题失败 code=${err.code} msg=${err.message}`);
  }
}

// 启动时读一次存下来的偏好直接套用。
export function applySavedTheme(ctx: common.Context, log: (line: string) => void): void {
  applyTheme(ctx, themeNow(), log);
}
