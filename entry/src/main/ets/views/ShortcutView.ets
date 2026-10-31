import { common } from '@kit.AbilityKit';
import { ProbeLog } from '../probe/ProbeLog';
import { applyHotkey, KEY_LABELS, hotkeyText } from '../probe/Hotkey';
import { asMods, hotkeyKeyNow, hotkeyModsNow, setHotkeySpec } from '../common/ShotSettings';
import { initTray, removeTray, trayAddedNow } from '../common/Tray';
import { captureToOverlay, requestTrayCapture } from '../common/ShotFlow';

const MODS: string[] = ['ctrl', 'shift', 'alt'];
const MOD_SHORT: string[] = ['Ctrl', 'Shift', 'Alt'];
const NUM_KEYS: string[] = ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9'];
const FN_KEYS: string[] = ['F1', 'F2', 'F3', 'F4', 'F5', 'F6', 'F7', 'F8', 'F9', 'F10', 'F11', 'F12'];
const LETTER_KEYS: string[] = KEY_LABELS.slice(0, 26);

// 快捷键由修饰键（1 到 2 个）加主键组成，主键限 A~Z、0~9、F1~F12。
// 生效走 applyHotkey，先订新的，订不上自动退回旧的，失败时只负责把原因说清楚。
@Component
export struct ShortcutView {
  @State mods: string = 'ctrl';
  // 不能叫 key：CustomComponent 自带 key(value) 属性方法，同名 @State 过不了类型检查。
  @State pickedKey: string = '1';
  @State savedMods: string = 'ctrl';
  @State savedKey: string = '1';
  @State msg: string = '';
  @State msgBad: boolean = false;

  aboutToAppear(): void {
    this.savedMods = hotkeyModsNow();
    this.savedKey = hotkeyKeyNow();
    this.mods = this.savedMods;
    this.pickedKey = this.savedKey;
  }

  private ctx(): common.UIAbilityContext | null {
    const stored: common.UIAbilityContext | undefined =
      AppStorage.get<common.UIAbilityContext>('abilityContext');
    return stored === undefined ? null : stored;
  }

  private log(line: string): void {
    ProbeLog.add(line);
  }

  // 兜底回调：applyHotkey 通常沿用启动时注册的回调，只在没有旧回调时接手。
  private fire(source: string): void {
    ProbeLog.add(`${source} 命中（快捷键页重订的订阅），直接进截图流程`);
    const c: common.UIAbilityContext | null = this.ctx();
    if (c !== null) {
      captureToOverlay(this.log, c);
    }
  }

  private say(text: string, bad: boolean): void {
    this.msg = text;
    this.msgBad = bad;
  }

  private modOn(m: string): boolean {
    return this.mods.split('+').indexOf(m) >= 0;
  }

  private modCount(): number {
    return this.mods.split('+').length;
  }

  private toggleMod(m: string): void {
    if (this.modOn(m)) {
      if (this.modCount() === 1) {
        this.say('至少要留一个修饰键，不然就成了单独一个字母键', true);
        return;
      }
      const left: string[] = this.mods.split('+').filter((x: string): boolean => x !== m);
      this.mods = left.join('+');
    } else {
      if (this.modCount() >= 2) {
        this.say('最多两个修饰键，先取消一个再选', true);
        return;
      }
      this.mods = asMods(`${this.mods}+${m}`);
    }
    this.msg = '';
  }

  private dirty(): boolean {
    return this.mods !== this.savedMods || this.pickedKey !== this.savedKey;
  }

  private apply(useMods: string, useKey: string): void {
    const mods: string = asMods(useMods);
    const text: string = hotkeyText(mods, useKey);
    const ok: boolean = applyHotkey(this.log, (source: string): void => {
      this.fire(source);
    }, mods, useKey);
    if (ok) {
      const c: common.UIAbilityContext | null = this.ctx();
      if (c !== null) {
        setHotkeySpec(c, mods, useKey, this.log);
        // 状态栏图标的悬停提示是挂图标那一刻写死的，改了键要重挂一次才不会显示旧键。
        if (trayAddedNow()) {
          removeTray(this.log, c);
          const p: Promise<boolean> = initTray(this.log, c, text, (): void => {
            void requestTrayCapture(this.log, c);
          });
          p.then((again: boolean): void => {
            if (!again) {
              this.log('托盘图标没重挂上，悬停提示还是旧快捷键');
            }
          });
        }
      }
      this.savedMods = mods;
      this.savedKey = useKey;
      this.mods = mods;
      this.pickedKey = useKey;
      this.say(`${text} 已生效，全机都能按`, false);
      return;
    }
    // applyHotkey 已退回旧组合，界面跟着退回去，别让选择框显示一个没生效的键。
    this.mods = this.savedMods;
    this.pickedKey = this.savedKey;
    this.say(`${text} 订不上（多半被系统或别的软件占用了），还是 ${hotkeyText(this.savedMods, this.savedKey)}`,
      true);
  }

  // 不用带值参的 @Builder：本 SDK 上这种 builder 只按第一帧计算，选中态会冻住，
  // 所以这些按钮全部写在 build 里。
  build() {
    Scroll() {
      Column({ space: 12 }) {
        Column({ space: 4 }) {
          Text('全局快捷键')
            .fontSize(22)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.ng_text'))
          Text('在任何窗口里按下都能开始截图，包括 NGshot 自己缩在状态栏的时候')
            .fontSize(13)
            .fontColor($r('app.color.ng_text_dim'))
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .margin({ bottom: 2 })

        Column({ space: 10 }) {
          Text(hotkeyText(this.mods, this.pickedKey))
            .fontSize(30)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.ng_accent_text'))
          Text(this.dirty() ? '改好了，点下面的按钮让它生效'
            : `正在使用：${hotkeyText(this.savedMods, this.savedKey)}`)
            .fontSize(12)
            .fontColor($r('app.color.ng_text_dim'))
          Row({ space: 8 }) {
            Button(this.dirty() ? '应用并生效' : '重新应用一次')
              .fontSize(13)
              .height(34)
              .backgroundColor($r('app.color.ng_accent'))
              .fontColor($r('app.color.ng_on_accent'))
              .onClick((): void => {
                this.apply(this.mods, this.pickedKey);
              })
            Button('恢复 Ctrl + 1')
              .fontSize(13)
              .height(34)
              .backgroundColor($r('app.color.ng_surface_alt'))
              .fontColor($r('app.color.ng_text'))
              .onClick((): void => {
                this.apply('ctrl', '1');
              })
          }
          .width('100%')
          if (this.msg !== '') {
            Text(this.msg)
              .fontSize(12)
              .fontColor(this.msgBad ? $r('app.color.ng_danger') : $r('app.color.ng_ok'))
              .width('100%')
          }
        }
        .width('100%')
        .padding(18)
        .alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.ng_surface'))
        .borderRadius(12)
        .border({ width: 1, color: $r('app.color.ng_line') })

        Column({ space: 8 }) {
          Text('修饰键（最多两个）')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.ng_text'))
          Row() {
            ForEach(MODS, (m: string, i: number) => {
              Button(MOD_SHORT[i])
                .fontSize(13)
                .height(32)
                .backgroundColor(this.modOn(m) ? $r('app.color.ng_accent') : $r('app.color.ng_surface_alt'))
                .fontColor(this.modOn(m) ? $r('app.color.ng_on_accent') : $r('app.color.ng_text'))
                .margin({ right: 6, bottom: 6 })
                .onClick((): void => {
                  this.toggleMod(m);
                })
            }, (m: string) => `mod-${m}`)
          }
          .width('100%')
          Text('左边的和右边的 Ctrl / Shift / Alt 都算，随手按哪边都行')
            .fontSize(11)
            .fontColor($r('app.color.ng_text_faint'))
        }
        .width('100%')
        .padding(16)
        .alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.ng_surface'))
        .borderRadius(12)
        .border({ width: 1, color: $r('app.color.ng_line') })

        Column({ space: 8 }) {
          Text('字母和数字')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.ng_text'))
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(LETTER_KEYS, (k: string) => {
              Button(k)
                .fontSize(12)
                .height(30)
                .width(46)
                // Button 自带左右内边距，46 宽扣完只够一个字符，“F10”这类键会被缩成“…”。
                .padding({ left: 0, right: 0 })
                .backgroundColor(this.pickedKey === k ? $r('app.color.ng_accent') : $r('app.color.ng_surface_alt'))
                .fontColor(this.pickedKey === k ? $r('app.color.ng_on_accent') : $r('app.color.ng_text'))
                .margin({ right: 5, bottom: 5 })
                .onClick((): void => {
                  this.pickedKey = k;
                  this.msg = '';
                })
            }, (k: string) => `k-${k}`)
          }
          .width('100%')
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(NUM_KEYS, (k: string) => {
              Button(k)
                .fontSize(12)
                .height(30)
                .width(46)
                // Button 自带左右内边距，46 宽扣完只够一个字符，“F10”这类键会被缩成“…”。
                .padding({ left: 0, right: 0 })
                .backgroundColor(this.pickedKey === k ? $r('app.color.ng_accent') : $r('app.color.ng_surface_alt'))
                .fontColor(this.pickedKey === k ? $r('app.color.ng_on_accent') : $r('app.color.ng_text'))
                .margin({ right: 5, bottom: 5 })
                .onClick((): void => {
                  this.pickedKey = k;
                  this.msg = '';
                })
            }, (k: string) => `n-${k}`)
          }
          .width('100%')
          Text('功能键')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.ng_text'))
            .margin({ top: 4 })
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(FN_KEYS, (k: string) => {
              Button(k)
                .fontSize(12)
                .height(30)
                .width(46)
                // Button 自带左右内边距，46 宽扣完只够一个字符，“F10”这类键会被缩成“…”。
                .padding({ left: 0, right: 0 })
                .backgroundColor(this.pickedKey === k ? $r('app.color.ng_accent') : $r('app.color.ng_surface_alt'))
                .fontColor(this.pickedKey === k ? $r('app.color.ng_on_accent') : $r('app.color.ng_text'))
                .margin({ right: 5, bottom: 5 })
                .onClick((): void => {
                  this.pickedKey = k;
                  this.msg = '';
                })
            }, (k: string) => `f-${k}`)
          }
          .width('100%')
        }
        .width('100%')
        .padding(16)
        .alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.ng_surface'))
        .borderRadius(12)
        .border({ width: 1, color: $r('app.color.ng_line') })

        Text('某个组合要是被系统或别的软件先占了，应用会保留原来的快捷键并在这里说明原因，'
          + '不会出现按了没反应的情况。快捷键失效时，也可以用「概览」里的按钮截图。')
          .fontSize(11)
          .fontColor($r('app.color.ng_text_faint'))
          .lineHeight(18)
          .width('100%')
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 18, bottom: 20 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Auto)
    .backgroundColor($r('app.color.ng_bg'))
  }
}
