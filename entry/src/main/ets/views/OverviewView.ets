import { common } from '@kit.AbilityKit';
import { ProbeLog } from '../probe/ProbeLog';
import { captureToOverlay } from '../common/ShotFlow';
import { hotkeyText } from '../probe/Hotkey';
import {
  autoDoLabel,
  autoDoNow,
  clipFormatNow,
  clipQualityNow,
  formatLabel,
  hotkeyKeyNow,
  hotkeyModsNow,
  qualityApplies,
  saveFormatNow,
  saveQualityNow,
  saveTargetDir
} from '../common/ShotSettings';

// 概览页：一眼看到按什么键、截完图去哪，外加一个不用记快捷键的截图按钮。
@Component
export struct OverviewView {
  @State hotkey: string = '';
  @State outLine: string = '';
  @State autoLine: string = '';
  @State tail: string = '';
  private pollTimer: number = -1;

  aboutToAppear(): void {
    this.refresh();
    this.pollTimer = setInterval((): void => {
      this.refresh();
    }, 1500);
  }

  aboutToDisappear(): void {
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  private ctx(): common.UIAbilityContext | null {
    const stored: common.UIAbilityContext | undefined =
      AppStorage.get<common.UIAbilityContext>('abilityContext');
    return stored === undefined ? null : stored;
  }

  private refresh(): void {
    this.hotkey = hotkeyText(hotkeyModsNow(), hotkeyKeyNow());
    const c: common.UIAbilityContext | null = this.ctx();
    const dir: string = c === null ? '(未知目录)' : saveTargetDir(c);
    const sq: string = qualityApplies(saveFormatNow()) ? ` · 质量 ${saveQualityNow()}` : '';
    const cq: string = qualityApplies(clipFormatNow()) ? ` · 质量 ${clipQualityNow()}` : '';
    this.outLine = `保存 ${formatLabel(saveFormatNow())}${sq}\n剪贴板 ${formatLabel(clipFormatNow())}${cq}\n位置 ${dir}`;
    const auto: string = autoDoNow();
    this.autoLine = auto === 'none'
      ? '框完停在工具条上，等你选工具或点复制/保存'
      : `框完立刻${autoDoLabel(auto)}，不再停在工具条上`;
    const all: string = ProbeLog.read();
    const tailText: string = all.length > 20000 ? all.slice(-20000) : all;
    const lines: string[] = tailText.split('\n').filter((l: string): boolean => l !== '');
    // 只取四条：一次截图流程就写四行，多了这一块会把整页撑得很长。
    this.tail = lines.slice(-4).join('\n');
  }

  private shoot(): void {
    const c: common.UIAbilityContext | null = this.ctx();
    if (c === null) {
      ProbeLog.add('概览页拿不到 abilityContext，截不了图');
      return;
    }
    captureToOverlay((line: string): void => {
      ProbeLog.add(line);
    }, c);
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        Column({ space: 4 }) {
          Text('年槌糕Shot')
            .fontSize(22)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.ng_text'))
          Text('按快捷键，框住要截的那块屏幕')
            .fontSize(13)
            .fontColor($r('app.color.ng_text_dim'))
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .margin({ bottom: 2 })

        Column({ space: 10 }) {
          Text(this.hotkey)
            .fontSize(34)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.ng_accent_text'))
          Text('按下就定格屏幕，拖出一块区域，松手后下面弹出工具条')
            .fontSize(12)
            .fontColor($r('app.color.ng_text_dim'))
          Row({ space: 8 }) {
            Button('立即截一张')
              .fontSize(13)
              .height(34)
              .backgroundColor($r('app.color.ng_accent'))
              .fontColor($r('app.color.ng_on_accent'))
              .onClick((): void => {
                this.shoot();
              })
            Text('快捷键被别的软件占用时，用这个按钮')
              .fontSize(11)
              .fontColor($r('app.color.ng_text_faint'))
          }
          .width('100%')
        }
        .width('100%')
        .padding(18)
        .alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.ng_surface'))
        .borderRadius(12)
        .border({ width: 1, color: $r('app.color.ng_line') })

        Column({ space: 6 }) {
          Text('怎么用')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.ng_text'))
          Text('选区定住后，工具条里能画框、加箭头、打码、写文字，也能贴到桌面、取词、长截图；画完点「复制」或「保存」')
            .fontSize(12)
            .fontColor($r('app.color.ng_text_dim'))
            .lineHeight(20)
          Text('不想截：还没框时在画面上点一下，已经框好在选区外面点一下，当场取消；键盘上按 Esc 或点右键也一样')
            .fontSize(12)
            .fontColor($r('app.color.ng_text_dim'))
            .lineHeight(20)
          Text('框和改：Ctrl+A 直接框住整屏，方向键微调（按住 Ctrl 一步 5 像素，Shift 一步 10 像素），'
            + '选中某一笔后用方向键只挪它，Delete 删掉它')
            .fontSize(12)
            .fontColor($r('app.color.ng_text_dim'))
            .lineHeight(20)
          Text('画和出图：Ctrl+Z 撤销、Ctrl+Shift+Z 或 Ctrl+Y 重做，Ctrl+C 复制、Ctrl+S 保存，'
            + '打字时回车就是落笔，按住鼠标中键拖框这一次不执行自动动作')
            .fontSize(12)
            .fontColor($r('app.color.ng_text_dim'))
            .lineHeight(20)
          Text('完整的按键清单在左边「快捷键」那一页')
            .fontSize(11)
            .fontColor($r('app.color.ng_text_faint'))
        }
        .width('100%')
        .padding(16)
        .alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.ng_surface'))
        .borderRadius(12)
        .border({ width: 1, color: $r('app.color.ng_line') })

        Column({ space: 6 }) {
          Text('截到的图去哪')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.ng_text'))
          Text(this.outLine)
            .fontSize(12)
            .fontColor($r('app.color.ng_text_dim'))
            .lineHeight(20)
          Text(this.autoLine)
            .fontSize(12)
            .fontColor($r('app.color.ng_text_dim'))
        }
        .width('100%')
        .padding(16)
        .alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.ng_surface'))
        .borderRadius(12)
        .border({ width: 1, color: $r('app.color.ng_line') })

        Column({ space: 6 }) {
          Text('关掉窗口不会退出')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.ng_text'))
          Text(`窗口会收进状态栏，程序还在，${this.hotkey} 继续可用。`
            + '要回来就用状态栏图标的右键菜单点「打开主界面」；左键点图标是直接截图，不会把主界面叫出来。')
            .fontSize(12)
            .fontColor($r('app.color.ng_text_dim'))
            .lineHeight(20)
        }
        .width('100%')
        .padding(16)
        .alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.ng_surface'))
        .borderRadius(12)
        .border({ width: 1, color: $r('app.color.ng_line') })

        Column({ space: 4 }) {
          Text('刚才发生了什么')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.ng_text_dim'))
          Text(this.tail === '' ? '（还没截过图）' : this.tail)
            .fontSize(11)
            .fontColor($r('app.color.ng_text_faint'))
            .fontFamily('monospace')
            .lineHeight(18)
            .width('100%')
            .copyOption(CopyOptions.LocalDevice)
        }
        .width('100%')
        .padding(16)
        .alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.ng_surface'))
        .borderRadius(12)
        .border({ width: 1, color: $r('app.color.ng_line') })
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
