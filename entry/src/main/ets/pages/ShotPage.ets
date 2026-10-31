import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ProbeLog } from '../probe/ProbeLog';
import { saveShot, copyShot, previewShot, disposeShot, shotBufferNow, setShotBuffer } from '../common/ShotService';
import { formatLabel, qualityApplies, saveTargetDir, saveFormatNow, saveQualityNow,
  clipFormatNow, clipQualityNow } from '../common/ShotSettings';

// 结果窗口的全部内容，直接占满 ResultAbility 的整窗，不用主能力的子窗：主能力被 hideAbility()
// 藏起来后再建子窗只有 window id，globalDisplayRect 是 0x0，永远上不了屏。
// PNG 字节放在 ShotService 模块里而不是 AppStorage：ArrayBuffer 过一遍 AppStorage 就不再是原生
// buffer，image.createImageSource() 会静默返回 undefined。两个 ability 同进程，模块里的引用拿得到；
// 状态文字和尺寸走 AppStorage，字符串没问题。预览、保存、复制各自解码一份，因为打包会消耗 PixelMap。
@Entry
@Component
struct ShotPage {
  @StorageProp('shotStatus') status: string = '';
  @StorageProp('shotSize') sizeText: string = '';
  @State preview: image.PixelMap | null = null;

  private ctx(): common.UIAbilityContext | null {
    const stored: common.UIAbilityContext | undefined =
      AppStorage.get<common.UIAbilityContext>('resultAbilityContext');
    if (stored === undefined) {
      ProbeLog.add('截图窗拿不到 resultAbilityContext');
      return null;
    }
    return stored;
  }

  private say(line: string): void {
    ProbeLog.add(`截图窗 ${line}`);
    AppStorage.setOrCreate('shotStatus', line);
  }

  async aboutToAppear(): Promise<void> {
    const buf: ArrayBuffer | null = shotBufferNow();
    if (buf === null) {
      this.say('没有截图字节，结果窗是空的');
      return;
    }
    const pm: image.PixelMap | null = await previewShot(buf, (line: string): void => {
      this.say(line);
    });
    this.preview = pm;
  }

  aboutToDisappear(): void {
    const pm: image.PixelMap | null = this.preview;
    if (pm !== null) {
      disposeShot(pm);
      this.preview = null;
    }
  }

  private saveLine(): string {
    const c: common.UIAbilityContext | null = this.ctx();
    const dir: string = c === null ? '(未知目录)' : saveTargetDir(c);
    const f: string = formatLabel(saveFormatNow());
    const q: string = qualityApplies(saveFormatNow()) ? ` 质量 ${saveQualityNow()}` : '';
    return `保存为 ${f}${q} → ${dir}`;
  }

  private clipLine(): string {
    const f: string = formatLabel(clipFormatNow());
    const q: string = qualityApplies(clipFormatNow()) ? ` 质量 ${clipQualityNow()}` : '';
    return `剪贴板为 ${f}${q}`;
  }

  private close(): void {
    const c: common.UIAbilityContext | null = this.ctx();
    setShotBuffer(null);
    if (c === null) {
      this.say('拿不到 resultAbilityContext，只能等主窗那条路径收拾');
      return;
    }
    // 这一页占满 ResultAbility 的窗口，关闭就是结束该能力，常驻主能力和状态栏图标不受影响。
    try {
      c.terminateSelf();
      this.say('已丢弃，结果能力已关');
    } catch (e) {
      const err = e as BusinessError;
      this.say(`terminateSelf 失败 code=${err.code} msg=${err.message}`);
    }
  }

  build() {
    Column() {
      Row() {
        Text('截图结果').fontSize(15).fontColor($r('app.color.ng_text'))
        Blank()
        Text(this.sizeText).fontSize(11).fontColor($r('app.color.ng_text_faint'))
      }
      .width('100%')
      .margin({ bottom: 6 })

      Scroll() {
        if (this.preview === null) {
          Text('（解码中…）').fontSize(13).fontColor($r('app.color.ng_text_faint'))
        } else {
          Image(this.preview)
            .objectFit(ImageFit.Contain)
            .width('100%')
        }
      }
      .layoutWeight(1)
      .align(Alignment.Top)
      .scrollBar(BarState.Auto)
      .width('100%')
      .backgroundColor($r('app.color.ng_surface_alt'))
      .borderRadius(6)
      .margin({ bottom: 8 })

      Text(this.saveLine()).fontSize(11).fontColor($r('app.color.ng_text_dim'))
      Text(this.clipLine()).fontSize(11).fontColor($r('app.color.ng_text_dim')).margin({ bottom: 6 })
      Text(this.status === '' ? ' ' : this.status)
        .fontSize(11)
        .fontColor($r('app.color.ng_ok'))
        .margin({ bottom: 6 })

      Flex({ wrap: FlexWrap.Wrap }) {
        Button('保存')
          .fontSize(13)
          .height(32)
          .backgroundColor($r('app.color.ng_accent'))
          .fontColor($r('app.color.ng_on_accent'))
          .margin({ right: 8, bottom: 6 })
          .onClick(() => {
            const c = this.ctx();
            const buf: ArrayBuffer | null = shotBufferNow();
            if (c === null || buf === null) {
              this.say('缺 context 或截图字节，存不了');
              return;
            }
            saveShot(buf, c, (line: string): void => {
              this.say(line);
            });
          })
        Button('复制到剪贴板')
          .fontSize(13)
          .height(32)
          .backgroundColor($r('app.color.ng_surface_alt'))
          .fontColor($r('app.color.ng_on_accent'))
          .margin({ right: 8, bottom: 6 })
          .onClick(() => {
            const buf: ArrayBuffer | null = shotBufferNow();
            if (buf === null) {
              this.say('没有截图字节');
              return;
            }
            copyShot(buf, (line: string): void => {
              this.say(line);
            });
          })
        Button('丢弃并关窗')
          .fontSize(13)
          .height(32)
          .backgroundColor($r('app.color.ng_surface_alt'))
          .fontColor($r('app.color.ng_on_accent'))
          .margin({ right: 8, bottom: 6 })
          .onClick(() => {
            this.close();
          })
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding(12)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r('app.color.ng_bg'))
  }
}
