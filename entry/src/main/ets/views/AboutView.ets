import { bundleManager } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

// 版本号从应用清单里读，不在代码里另写一份，免得 app.json5 改过之后对不上。
const APP_NAME: string = '年槌糕Shot';
const TAGLINE: string = '截图 · 标注 · 贴图';
// “基于……构建”写实际技术栈：ArkTS 写逻辑，ArkUI 画界面，跑在本工程的 API 23 基线上。
const FOOTER: string = '© 2026 年槌糕Shot · 基于 HarmonyOS ArkTS · ArkUI（API 23）构建';
const FEATURES: string[] = [
  '全局快捷键框选截图，任何窗口前面都能按',
  '标注：矩形、线、箭头、画笔、马赛克、遮罩、文字、序号、取色',
  '长截图：滚动拼接成一整张',
  '文字识别：端侧 OCR，识别结果直接进剪贴板',
  '贴图：把截图开成一扇小窗摆着对照看，可以压在其他应用上面',
  '保存 PNG / JPEG / WebP，或复制到剪贴板'
];

@Component
export struct AboutView {
  @State version: string = '';

  aboutToAppear(): void {
    try {
      const info: bundleManager.BundleInfo = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      this.version = info.versionName;
    } catch (e) {
      const err = e as BusinessError;
      this.version = `读取失败 code=${err.code}`;
    }
  }

  build() {
    Column() {
      Scroll() {
        Column({ space: 12 }) {
          // 头图按常见“关于”页的排法：左边图标，右边名称、一句话和版本号胶囊。
          // 图标是分层图标（app_layered_image.json：background + foreground），单独取一层只会得到
          // 一块底色，所以两层按同一画布叠起来，再按 App 图标那种圆角裁一下。
          Row({ space: 16 }) {
            Stack() {
              Image($r('app.media.background'))
                .width('100%')
                .height('100%')
                .objectFit(ImageFit.Cover)
              Image($r('app.media.foreground'))
                .width('100%')
                .height('100%')
                .objectFit(ImageFit.Cover)
            }
            .width(72)
            .height(72)
            .borderRadius(18)
            .clip(true)
            Column({ space: 6 }) {
              Text(APP_NAME)
                .fontSize(24)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.ng_text'))
              Text(TAGLINE)
                .fontSize(13)
                .fontColor($r('app.color.ng_text_dim'))
              Text(`版本 ${this.version}`)
                .fontSize(11)
                .fontColor($r('app.color.ng_text_dim'))
                .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                .backgroundColor($r('app.color.ng_surface_alt'))
                .borderRadius(6)
                .margin({ top: 2 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
          }
          .width('100%')
          .padding(18)
          .alignItems(VerticalAlign.Center)
          .backgroundColor($r('app.color.ng_surface'))
          .borderRadius(14)
          .border({ width: 1, color: $r('app.color.ng_line') })

          Column({ space: 6 }) {
            Text('能做什么')
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.ng_text'))
              .margin({ bottom: 2 })
            ForEach(FEATURES, (f: string) => {
              Row() {
                Text('·')
                  .fontSize(13)
                  .fontColor($r('app.color.ng_accent_text'))
                  .width(12)
                Text(f)
                  .fontSize(12)
                  .fontColor($r('app.color.ng_text_dim'))
                  .layoutWeight(1)
                  .lineHeight(19)
              }
              .width('100%')
              .alignItems(VerticalAlign.Top)
            }, (f: string) => f)
          }
          .width('100%')
          .padding(16)
          .alignItems(HorizontalAlign.Start)
          .backgroundColor($r('app.color.ng_surface'))
          .borderRadius(12)
          .border({ width: 1, color: $r('app.color.ng_line') })

          Column({ space: 6 }) {
            Text('你的截图放在哪')
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.ng_text'))
              .margin({ bottom: 2 })
            Text('截图只会写进你在「设置 → 保存位置」里挑的文件夹，没挑过就放在应用自己的空间里。'
              + '日志也只是本机的一个文本文件，随时可以在「设置 → 诊断与日志」里清空。')
              .fontSize(12)
              .fontColor($r('app.color.ng_text_dim'))
              .lineHeight(19)
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
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Auto)

      // 版权行固定在底部，不随内容滚动，内容再短也贴着窗口下沿。
      Text(FOOTER)
        .fontSize(11)
        .fontColor($r('app.color.ng_text_faint'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ left: 20, right: 20, top: 6, bottom: 14 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.ng_bg'))
    .alignItems(HorizontalAlign.Start)
  }
}
