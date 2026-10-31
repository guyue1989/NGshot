import { OverviewView } from '../views/OverviewView';
import { ShortcutView } from '../views/ShortcutView';
import { SettingsView } from '../views/SettingsView';
import { AboutView } from '../views/AboutView';

const TABS: string[] = ['overview', 'shortcut', 'settings', 'about'];
const TAB_LABELS: string[] = ['概览', '快捷键', '设置', '关于'];

// 主界面：固定左侧栏加右侧内容区。侧栏只切内容不跳页，换栏时右区整块重挂，
// 各视图在 aboutToAppear 里自己读设置，所以当前栏位放在 AppStorage，改栏不重建状态。
// 截图时会隐藏主窗，这是截图流程本身的要求，与侧栏无关。
@Entry
@Component
struct MainPage {
  @StorageLink('mainTab') tab: string = 'overview';

  build() {
    Row() {
      Column() {
        Column({ space: 2 }) {
          Text('年槌糕Shot')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.ng_text'))
          Text('截图 · 标注 · 贴图')
            .fontSize(11)
            .fontColor($r('app.color.ng_text_faint'))
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 12, top: 4, bottom: 16 })

        ForEach(TABS, (t: string, i: number) => {
          Row() {
            Text(TAB_LABELS[i])
              .fontSize(14)
              .fontColor(this.tab === t ? $r('app.color.ng_accent_text') : $r('app.color.ng_text_dim'))
              .fontWeight(this.tab === t ? FontWeight.Medium : FontWeight.Normal)
          }
          .width('100%')
          .height(38)
          .padding({ left: 12 })
          .borderRadius(8)
          .backgroundColor(this.tab === t ? $r('app.color.ng_accent_soft') : Color.Transparent)
          .margin({ bottom: 2 })
          .onClick((): void => {
            this.tab = t;
          })
        }, (t: string) => `tab-${t}`)

        Blank()

        Text('关掉窗口不会退出，程序留在状态栏')
          .fontSize(10)
          .fontColor($r('app.color.ng_text_faint'))
          .lineHeight(15)
          .padding({ left: 12, right: 4 })
      }
      .width(176)
      .height('100%')
      .padding({ left: 10, right: 10, top: 14, bottom: 12 })
      .alignItems(HorizontalAlign.Start)
      .backgroundColor($r('app.color.ng_surface_alt'))
      .border({ width: { right: 1 }, color: $r('app.color.ng_line') })

      Column() {
        if (this.tab === 'shortcut') {
          ShortcutView()
        } else if (this.tab === 'settings') {
          SettingsView()
        } else if (this.tab === 'about') {
          AboutView()
        } else {
          OverviewView()
        }
      }
      .layoutWeight(1)
      .height('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .alignItems(VerticalAlign.Top)
    .backgroundColor($r('app.color.ng_bg'))
  }
}
