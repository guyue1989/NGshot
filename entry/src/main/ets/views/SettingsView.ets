import { common } from '@kit.AbilityKit';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { ProbeLog } from '../probe/ProbeLog';
import {
  ShotFormat,
  formatLabel,
  qualityApplies,
  saveTargetDir,
  setSaveFormat,
  setSaveQuality,
  setClipFormat,
  setClipQuality,
  setSaveDir,
  saveFormatNow,
  saveQualityNow,
  clipFormatNow,
  clipQualityNow,
  setAutoDo,
  autoDoNow,
  autoDoLabel,
  rememberBandNow,
  setRememberBand,
  guidesNow,
  setGuides,
  cornersNow,
  setCorners,
  guideLabel,
  themeNow,
  setTheme
} from '../common/ShotSettings';
import { applyTheme, themeLabel } from '../common/Theme';
import { pickSaveDir, persistGrant, activateGrant, toPlainPath } from '../common/SaveDirGrant';

const FORMATS: ShotFormat[] = [ShotFormat.PNG, ShotFormat.JPEG, ShotFormat.WEBP];
const AUTO_KINDS: string[] = ['none', 'copy', 'save', 'pin'];
const AUTO_SHORT: string[] = ['不做', '复制', '保存', '贴图'];
const GUIDE_KINDS: string[] = ['none', 'thirds', 'golden'];
const THEMES: string[] = ['system', 'light', 'dark'];

// 设置页：外观在最上面，方便第一眼切成深色；然后是截图输出、保存位置和框选行为；
// 最下面是诊断与日志，出问题时往下拉就能把整段日志复制走。
// 不用带值参的 @Builder：本 SDK 上这种 builder 只按第一帧计算，选中的格式和质量会冻住，
// 所以每一行都写在 build 里。
@Component
export struct SettingsView {
  @State theme: string = 'system';
  @State saveFmt: ShotFormat = ShotFormat.PNG;
  @State saveQ: number = 90;
  @State clipFmt: ShotFormat = ShotFormat.PNG;
  @State clipQ: number = 90;
  @State autoDo: string = 'none';
  @State remember: boolean = false;
  @State guides: string = 'none';
  @State corners: boolean = true;
  @State dirLine: string = '';
  @State logTail: string = '';
  @State logNote: string = '';
  private pollTimer: number = -1;

  aboutToAppear(): void {
    this.theme = themeNow();
    this.saveFmt = saveFormatNow();
    this.saveQ = saveQualityNow();
    this.clipFmt = clipFormatNow();
    this.clipQ = clipQualityNow();
    this.autoDo = autoDoNow();
    this.remember = rememberBandNow();
    this.guides = guidesNow();
    this.corners = cornersNow();
    this.refreshDir();
    this.refreshLog();
    this.pollTimer = setInterval((): void => {
      this.refreshLog();
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
    if (stored === undefined) {
      ProbeLog.add('设置页拿不到 abilityContext');
      return null;
    }
    return stored;
  }

  private log(line: string): void {
    ProbeLog.add(line);
  }

  private refreshDir(): void {
    const c: common.UIAbilityContext | null = this.ctx();
    this.dirLine = c === null ? '保存目录：(未知)' : `保存目录：${saveTargetDir(c)}`;
  }

  // 日志一直增长，每次重新截尾：三十行足够看清最近一次截图走到哪一步。
  private refreshLog(): void {
    const all: string = ProbeLog.read();
    const tailText: string = all.length > 40000 ? all.slice(-40000) : all;
    const lines: string[] = tailText.split('\n').filter((l: string): boolean => l !== '');
    this.logTail = lines.slice(-30).join('\n');
  }

  private chooseDir(): void {
    const c: common.UIAbilityContext | null = this.ctx();
    if (c === null) {
      return;
    }
    pickSaveDir(c, this.log, (uri: string): void => {
      this.applyDir(c, uri);
    });
  }

  // 选择器给的授权只在本次会话有效，所以选完立刻写盘并在本次运行里激活；
  // 下次启动由 EntryAbility 再 activatePermission 一次。
  private async applyDir(c: common.UIAbilityContext, uri: string): Promise<void> {
    const fail: string = await persistGrant(uri, this.log);
    if (fail !== '') {
      this.dirLine = `目录授权失败：${fail}`;
      return;
    }
    await activateGrant(uri, this.log);
    setSaveDir(c, toPlainPath(uri), uri, this.log);
    this.refreshDir();
  }

  private resetDir(): void {
    const c: common.UIAbilityContext | null = this.ctx();
    if (c === null) {
      return;
    }
    setSaveDir(c, '', '', this.log);
    this.refreshDir();
  }

  private pickTheme(v: string): void {
    this.theme = v;
    const c: common.UIAbilityContext | null = this.ctx();
    if (c !== null) {
      setTheme(c, v, this.log);
      applyTheme(c, v, this.log);
    }
  }

  private pickSave(f: ShotFormat): void {
    this.saveFmt = f;
    const c: common.UIAbilityContext | null = this.ctx();
    if (c !== null) {
      setSaveFormat(c, f, this.log);
    }
  }

  private pickClip(f: ShotFormat): void {
    this.clipFmt = f;
    const c: common.UIAbilityContext | null = this.ctx();
    if (c !== null) {
      setClipFormat(c, f, this.log);
    }
  }

  private pickAuto(v: string): void {
    this.autoDo = v;
    const c: common.UIAbilityContext | null = this.ctx();
    if (c !== null) {
      setAutoDo(c, v, this.log);
    }
  }

  private pickRemember(v: boolean): void {
    this.remember = v;
    const c: common.UIAbilityContext | null = this.ctx();
    if (c !== null) {
      setRememberBand(c, v, this.log);
    }
  }

  private pickGuides(v: string): void {
    this.guides = v;
    const c: common.UIAbilityContext | null = this.ctx();
    if (c !== null) {
      setGuides(c, v, this.log);
    }
  }

  private pickCorners(v: boolean): void {
    this.corners = v;
    const c: common.UIAbilityContext | null = this.ctx();
    if (c !== null) {
      setCorners(c, v, this.log);
    }
  }

  private copyLog(): void {
    const text: string = ProbeLog.read();
    if (text === '') {
      this.logNote = '日志是空的，还没截过图';
      return;
    }
    const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    pasteboard.getSystemPasteboard().setData(data).then((): void => {
      this.logNote = `已复制 ${text.length} 个字符，可以粘到反馈里`;
    }).catch((e: BusinessError): void => {
      this.logNote = `复制失败 code=${e.code} msg=${e.message}`;
    });
  }

  private clearLog(): void {
    ProbeLog.clear();
    this.refreshLog();
    this.logNote = '日志已清空';
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        Column({ space: 4 }) {
          Text('设置')
            .fontSize(22)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.ng_text'))
          Text('改完立刻生效，不用重启')
            .fontSize(13)
            .fontColor($r('app.color.ng_text_dim'))
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .margin({ bottom: 2 })

        Column({ space: 8 }) {
          Text('外观')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.ng_text'))
          Text('默认跟随系统：电脑切到深色，这里也跟着变。')
            .fontSize(11)
            .fontColor($r('app.color.ng_text_faint'))
          Row() {
            ForEach(THEMES, (t: string) => {
              Button(themeLabel(t))
                .fontSize(13)
                .height(32)
                .backgroundColor(this.theme === t ? $r('app.color.ng_accent') : $r('app.color.ng_surface_alt'))
                .fontColor(this.theme === t ? $r('app.color.ng_on_accent') : $r('app.color.ng_text'))
                .margin({ right: 6, bottom: 6 })
                .onClick((): void => {
                  this.pickTheme(t);
                })
            }, (t: string) => `theme-${t}`)
          }
          .width('100%')
        }
        .width('100%')
        .padding(16)
        .alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.ng_surface'))
        .borderRadius(12)
        .border({ width: 1, color: $r('app.color.ng_line') })

        Column({ space: 8 }) {
          Text('保存成文件')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.ng_text'))
          Text('工具栏上点「保存」时写下的文件格式')
            .fontSize(11)
            .fontColor($r('app.color.ng_text_faint'))
          Row() {
            Text('格式')
              .fontSize(13)
              .fontColor($r('app.color.ng_text_dim'))
              .width(64)
            ForEach(FORMATS, (f: ShotFormat) => {
              Button(formatLabel(f))
                .fontSize(12)
                .height(30)
                .backgroundColor(this.saveFmt === f ? $r('app.color.ng_accent') : $r('app.color.ng_surface_alt'))
                .fontColor(this.saveFmt === f ? $r('app.color.ng_on_accent') : $r('app.color.ng_text'))
                .margin({ right: 6 })
                .onClick((): void => {
                  this.pickSave(f);
                })
            }, (f: ShotFormat) => `save-${f}`)
          }
          .width('100%')
          Row() {
            Text('质量')
              .fontSize(13)
              .fontColor($r('app.color.ng_text_dim'))
              .width(64)
            Slider({ value: this.saveQ, min: 10, max: 100, step: 5, style: SliderStyle.OutSet })
              .enabled(qualityApplies(this.saveFmt))
              .layoutWeight(1)
              .onChange((v: number, mode: SliderChangeMode) => {
                this.saveQ = Math.round(v);
                // 拖动过程中每格都写盘没有意义，松手时再存。
                if (mode === SliderChangeMode.End) {
                  const c: common.UIAbilityContext | null = this.ctx();
                  if (c !== null) {
                    setSaveQuality(c, this.saveQ, this.log);
                  }
                }
              })
            Text(qualityApplies(this.saveFmt) ? `${this.saveQ}` : '仅 JPEG 有效')
              .fontSize(12)
              .fontColor(qualityApplies(this.saveFmt) ? $r('app.color.ng_text') : $r('app.color.ng_text_faint'))
              .width(84)
              .textAlign(TextAlign.End)
          }
          .width('100%')
        }
        .width('100%')
        .padding(16)
        .alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.ng_surface'))
        .borderRadius(12)
        .border({ width: 1, color: $r('app.color.ng_line') })

        Column({ space: 8 }) {
          Text('复制到剪贴板')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.ng_text'))
          Text('这里只定压缩方式，粘出来存成 PNG 还是 JPEG 由对方应用决定')
            .fontSize(11)
            .fontColor($r('app.color.ng_text_faint'))
          Row() {
            Text('格式')
              .fontSize(13)
              .fontColor($r('app.color.ng_text_dim'))
              .width(64)
            ForEach(FORMATS, (f: ShotFormat) => {
              Button(formatLabel(f))
                .fontSize(12)
                .height(30)
                .backgroundColor(this.clipFmt === f ? $r('app.color.ng_accent') : $r('app.color.ng_surface_alt'))
                .fontColor(this.clipFmt === f ? $r('app.color.ng_on_accent') : $r('app.color.ng_text'))
                .margin({ right: 6 })
                .onClick((): void => {
                  this.pickClip(f);
                })
            }, (f: ShotFormat) => `clip-${f}`)
          }
          .width('100%')
          Row() {
            Text('质量')
              .fontSize(13)
              .fontColor($r('app.color.ng_text_dim'))
              .width(64)
            Slider({ value: this.clipQ, min: 10, max: 100, step: 5, style: SliderStyle.OutSet })
              .enabled(qualityApplies(this.clipFmt))
              .layoutWeight(1)
              .onChange((v: number, mode: SliderChangeMode) => {
                this.clipQ = Math.round(v);
                if (mode === SliderChangeMode.End) {
                  const c: common.UIAbilityContext | null = this.ctx();
                  if (c !== null) {
                    setClipQuality(c, this.clipQ, this.log);
                  }
                }
              })
            Text(qualityApplies(this.clipFmt) ? `${this.clipQ}` : '仅 JPEG 有效')
              .fontSize(12)
              .fontColor(qualityApplies(this.clipFmt) ? $r('app.color.ng_text') : $r('app.color.ng_text_faint'))
              .width(84)
              .textAlign(TextAlign.End)
          }
          .width('100%')
        }
        .width('100%')
        .padding(16)
        .alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.ng_surface'))
        .borderRadius(12)
        .border({ width: 1, color: $r('app.color.ng_line') })

        Column({ space: 8 }) {
          Text('保存位置')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.ng_text'))
          Text(this.dirLine)
            .fontSize(12)
            .fontColor($r('app.color.ng_text_dim'))
          Text('默认存在应用自己的空间里；换成公共文件夹要靠系统目录选择器授权，选一次长期有效。')
            .fontSize(11)
            .fontColor($r('app.color.ng_text_faint'))
            .lineHeight(17)
          Flex({ wrap: FlexWrap.Wrap }) {
            Button('选择文件夹')
              .fontSize(12)
              .height(30)
              .backgroundColor($r('app.color.ng_accent'))
              .fontColor($r('app.color.ng_on_accent'))
              .margin({ right: 8, top: 4 })
              .onClick((): void => {
                this.chooseDir();
              })
            Button('恢复默认位置')
              .fontSize(12)
              .height(30)
              .backgroundColor($r('app.color.ng_surface_alt'))
              .fontColor($r('app.color.ng_text'))
              .margin({ right: 8, top: 4 })
              .onClick((): void => {
                this.resetDir();
              })
          }
          .width('100%')
        }
        .width('100%')
        .padding(16)
        .alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.ng_surface'))
        .borderRadius(12)
        .border({ width: 1, color: $r('app.color.ng_line') })

        Column({ space: 10 }) {
          Text('框选')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.ng_text'))

          Text('框完松手直接做什么')
            .fontSize(12)
            .fontColor($r('app.color.ng_text_dim'))
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(AUTO_KINDS, (k: string, i: number) => {
              Button(AUTO_SHORT[i])
                .fontSize(12)
                .height(30)
                .backgroundColor(this.autoDo === k ? $r('app.color.ng_accent') : $r('app.color.ng_surface_alt'))
                .fontColor(this.autoDo === k ? $r('app.color.ng_on_accent') : $r('app.color.ng_text'))
                .margin({ right: 6, top: 4 })
                .onClick((): void => {
                  this.pickAuto(k);
                })
            }, (k: string) => k)
          }
          .width('100%')
          Text(this.autoDo === 'none'
            ? '现在：框完停在工具条上，等你选工具或点复制/保存'
            : `现在：框完立刻${autoDoLabel(this.autoDo)}，不再停在工具条上`)
            .fontSize(11)
            .fontColor($r('app.color.ng_text_faint'))

          Divider().color($r('app.color.ng_line')).margin({ top: 2, bottom: 2 })

          Text(this.remember ? '记忆框选：下次先摆出上一次的框' : '记忆框选：每次都重新拖')
            .fontSize(12)
            .fontColor($r('app.color.ng_text_dim'))
          Flex({ wrap: FlexWrap.Wrap }) {
            Button('记住上次的框')
              .fontSize(12)
              .height(30)
              .backgroundColor(this.remember ? $r('app.color.ng_accent') : $r('app.color.ng_surface_alt'))
              .fontColor(this.remember ? $r('app.color.ng_on_accent') : $r('app.color.ng_text'))
              .margin({ right: 6, top: 4 })
              .onClick((): void => {
                this.pickRemember(true);
              })
            Button('每次都重新拖')
              .fontSize(12)
              .height(30)
              .backgroundColor(!this.remember ? $r('app.color.ng_accent') : $r('app.color.ng_surface_alt'))
              .fontColor(!this.remember ? $r('app.color.ng_on_accent') : $r('app.color.ng_text'))
              .margin({ right: 6, top: 4 })
              .onClick((): void => {
                this.pickRemember(false);
              })
          }
          .width('100%')

          Text(`参考线：${guideLabel(this.guides)}（只画在屏幕上，不会出现在截图里）`)
            .fontSize(12)
            .fontColor($r('app.color.ng_text_dim'))
            .margin({ top: 4 })
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(GUIDE_KINDS, (k: string) => {
              Button(guideLabel(k))
                .fontSize(12)
                .height(30)
                .backgroundColor(this.guides === k ? $r('app.color.ng_accent') : $r('app.color.ng_surface_alt'))
                .fontColor(this.guides === k ? $r('app.color.ng_on_accent') : $r('app.color.ng_text'))
                .margin({ right: 6, top: 4 })
                .onClick((): void => {
                  this.pickGuides(k);
                })
            }, (k: string) => `guide-${k}`)
          }
          .width('100%')

          Text(this.corners ? '四角坐标：拖框和定稿时都标出左上 / 右下' : '四角坐标：只标尺寸')
            .fontSize(12)
            .fontColor($r('app.color.ng_text_dim'))
            .margin({ top: 4 })
          Flex({ wrap: FlexWrap.Wrap }) {
            Button('显示')
              .fontSize(12)
              .height(30)
              .backgroundColor(this.corners ? $r('app.color.ng_accent') : $r('app.color.ng_surface_alt'))
              .fontColor(this.corners ? $r('app.color.ng_on_accent') : $r('app.color.ng_text'))
              .margin({ right: 6, top: 4 })
              .onClick((): void => {
                this.pickCorners(true);
              })
            Button('不显示')
              .fontSize(12)
              .height(30)
              .backgroundColor(!this.corners ? $r('app.color.ng_accent') : $r('app.color.ng_surface_alt'))
              .fontColor(!this.corners ? $r('app.color.ng_on_accent') : $r('app.color.ng_text'))
              .margin({ right: 6, top: 4 })
              .onClick((): void => {
                this.pickCorners(false);
              })
          }
          .width('100%')
        }
        .width('100%')
        .padding(16)
        .alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.ng_surface'))
        .borderRadius(12)
        .border({ width: 1, color: $r('app.color.ng_line') })

        Column({ space: 8 }) {
          Text('诊断与日志')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.ng_text'))
          Text('截图出问题时，把这里的最后几十行复制下来一起发过来，就能看出卡在哪一步。')
            .fontSize(11)
            .fontColor($r('app.color.ng_text_faint'))
            .lineHeight(17)
          Flex({ wrap: FlexWrap.Wrap }) {
            Button('复制日志')
              .fontSize(12)
              .height(30)
              .backgroundColor($r('app.color.ng_accent'))
              .fontColor($r('app.color.ng_on_accent'))
              .margin({ right: 8, top: 4 })
              .onClick((): void => {
                this.copyLog();
              })
            Button('清空日志')
              .fontSize(12)
              .height(30)
              .backgroundColor($r('app.color.ng_surface_alt'))
              .fontColor($r('app.color.ng_text'))
              .margin({ right: 8, top: 4 })
              .onClick((): void => {
                this.clearLog();
              })
          }
          .width('100%')
          if (this.logNote !== '') {
            Text(this.logNote)
              .fontSize(11)
              .fontColor($r('app.color.ng_text_dim'))
          }
          Scroll() {
            Text(this.logTail === '' ? '（还没有日志）' : this.logTail)
              .fontSize(11)
              .fontColor($r('app.color.ng_text_dim'))
              .fontFamily('monospace')
              .lineHeight(17)
              .textAlign(TextAlign.Start)
              .width('100%')
              .copyOption(CopyOptions.LocalDevice)
          }
          .width('100%')
          .height(200)
          .align(Alignment.Top)
          .scrollBar(BarState.Auto)
          .padding(10)
          .backgroundColor($r('app.color.ng_surface_alt'))
          .borderRadius(8)
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
