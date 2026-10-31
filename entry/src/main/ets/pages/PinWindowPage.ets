import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { ProbeLog } from '../probe/ProbeLog';
import { previewShot, disposeShot, copyShot, saveShot } from '../common/ShotService';
import { PinStage, peekPagePin, pinBufferNow, dropPin } from '../common/PinService';
import { ocrFromPng, copyText } from '../common/OcrService';

const KEYCODE_ESCAPE: number = 2070;

// 一个贴图窗的全部内容：图片铺满整窗，窗口的尺寸和位置由 ability 按截图像素设好。
// 左键按下走 startMoving() 把窗口交给系统跟着指针走，右键弹菜单（复制/保存/取词/关闭），
// Esc 在有焦点时关闭。图片必须 .draggable(false) + .copyOption(CopyOptions.None)，
// 否则按下拖动会起 ArkUI 系统拖拽，跟着指针走的是缩略图而不是窗口。
// 置顶由 PinAbility 负责，本页不处理。
@Entry
@Component
struct PinWindowPage {
  @State shot: image.PixelMap | null = null;
  @State status: string = '';
  @State placed: boolean = false;
  @State ocrText: string = '';
  private pin: PinStage | null = null;
  private working: boolean = false;
  private moving: boolean = false;
  private lastMoveStart: number = 0;
  private statusTimer: number = -1;

  private say(line: string): void {
    ProbeLog.add(`贴图 ${line}`);
    this.status = line;
    // 状态只是即时反馈，3 秒后清掉，免得旧提示一直压在图上。
    if (this.statusTimer >= 0) {
      clearTimeout(this.statusTimer);
    }
    this.statusTimer = setTimeout((): void => {
      this.status = '';
      this.statusTimer = -1;
    }, 3000);
  }

  async aboutToAppear(): Promise<void> {
    const p: PinStage | null = peekPagePin();
    if (p === null) {
      this.say('没有贴图数据，这扇窗是空的');
      return;
    }
    this.pin = p;
    const buf: ArrayBuffer | null = pinBufferNow(p.id);
    if (buf === null) {
      this.say('贴图字节已经不在了');
      return;
    }
    this.shot = await previewShot(buf, (line: string): void => {
      this.say(line);
    });
  }

  aboutToDisappear(): void {
    if (this.pin !== null) {
      dropPin(this.pin.id);
      this.pin = null;
    }
    const pm: image.PixelMap | null = this.shot;
    if (pm !== null) {
      disposeShot(pm);
      this.shot = null;
    }
    if (this.statusTimer >= 0) {
      clearTimeout(this.statusTimer);
      this.statusTimer = -1;
    }
  }

  private ctx(): common.UIAbilityContext | null {
    const c = getContext(this) as common.UIAbilityContext;
    return c === undefined || c === null ? null : c;
  }

  private close(): void {
    const c: common.UIAbilityContext | null = this.ctx();
    if (c === null) {
      this.say('拿不到自己的 abilityContext，关不掉');
      return;
    }
    try {
      c.terminateSelf();
    } catch (e) {
      const err = e as BusinessError;
      this.say(`terminateSelf 失败 code=${err.code} msg=${err.message}`);
    }
  }

  private startMove(): void {
    // 按时间窗去重，不看 sourceType：鼠标按下会连着送 onMouse.Press 和合成的 onTouch.Down，
    // 本 SDK 的 TouchEvent 没有 sourceType 可区分。不去重的话第二次调用会撞上系统移动会话的
    // 1300001 Repeat operation。
    const now: number = Date.now();
    if (this.moving || now - this.lastMoveStart < 120) {
      return;
    }
    if (this.ocrText !== '') {
      return;
    }
    this.lastMoveStart = now;
    this.moving = true;
    const c: common.UIAbilityContext | null = this.ctx();
    if (c === null) {
      this.moving = false;
      return;
    }
    window.getLastWindow(c).then((win: window.Window) => {
      return win.startMoving();
    }).then((): void => {
      this.moving = false;
    }).catch((e: BusinessError): void => {
      this.moving = false;
      this.say(`startMoving 失败 code=${e.code} msg=${e.message}`);
    });
  }

  private async act(kind: 'copy' | 'save'): Promise<void> {
    if (this.working || this.pin === null) {
      return;
    }
    const buf: ArrayBuffer | null = pinBufferNow(this.pin.id);
    if (buf === null) {
      this.say('字节不在了，复制/保存都做不了');
      return;
    }
    this.working = true;
    let ok: boolean = false;
    if (kind === 'copy') {
      ok = await copyShot(buf, (line: string): void => {
        this.say(line);
      });
    } else {
      const c: common.UIAbilityContext | null = this.ctx();
      if (c === null) {
        this.working = false;
        return;
      }
      ok = await saveShot(buf, c, (line: string): void => {
        this.say(line);
      });
    }
    this.working = false;
    // 贴图窗不自动关，它是常驻的工作面，不是一次性对话框。
    this.say(ok ? (kind === 'copy' ? '已复制进剪贴板' : '已保存') : '没成功，贴图还在');
  }

  private async ocr(): Promise<void> {
    if (this.working || this.pin === null) {
      return;
    }
    const buf: ArrayBuffer | null = pinBufferNow(this.pin.id);
    if (buf === null) {
      this.say('字节不在了，取不了词');
      return;
    }
    this.working = true;
    const text: string | null = await ocrFromPng(buf, (line: string): void => {
      this.say(line);
    });
    this.working = false;
    if (text !== null) {
      this.ocrText = text;
    }
  }

  private async copyOcr(): Promise<void> {
    const ok: boolean = await copyText(this.ocrText, (line: string): void => {
      this.say(line);
    });
    if (ok) {
      this.say('取词结果已复制');
    }
  }

  @Builder
  pinMenu() {
    Column() {
      Button('复制到剪贴板')
        .fontSize(12)
        .height(30)
        .width('100%')
        .backgroundColor('#FF2F6C49')
        .fontColor('#FFE9EDF2')
        .onClick(() => {
          this.act('copy');
        })
      Button('保存')
        .fontSize(12)
        .height(30)
        .width('100%')
        .margin({ top: 6 })
        .backgroundColor('#FF2A313A')
        .fontColor('#FFE9EDF2')
        .onClick(() => {
          this.act('save');
        })
      Button('取词')
        .fontSize(12)
        .height(30)
        .width('100%')
        .margin({ top: 6 })
        .backgroundColor('#FF2F6C49')
        .fontColor('#FFE9EDF2')
        .onClick(() => {
          this.ocr();
        })
      Button('关闭贴图')
        .fontSize(12)
        .height(30)
        .width('100%')
        .margin({ top: 6 })
        .backgroundColor('#FF2A313A')
        .fontColor('#FFE9EDF2')
        .onClick(() => {
          this.close();
        })
    }
    .width(160)
    .padding(8)
    .backgroundColor('#F0101418')
    .borderRadius(8)
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.shot === null) {
        Text('贴图解码中…').fontSize(13).fontColor('#FF9AA4AF')
      } else {
        Image(this.shot)
          .width('100%')
          .height('100%')
          // 用 Contain 不用 Fill：系统最小窗宽 320vp（608px）会让窗口比窄截图更宽，
          // Fill 会把图横向拉伸。
          .objectFit(ImageFit.Contain)
          .draggable(false)
          .copyOption(CopyOptions.None)
      }

      if (this.status !== '') {
        Text(this.status)
          .fontSize(10)
          .fontColor('#FFE9EDF2')
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .backgroundColor('#B3000000')
          .borderRadius(4)
          .margin(4)
      }

      if (this.ocrText !== '') {
        Column() {
          Text('取词结果')
            .fontSize(12)
            .fontColor('#FFE9EDF2')
            .margin({ bottom: 6 })
          Scroll() {
            Text(this.ocrText)
              .fontSize(13)
              .fontColor('#FFE9EDF2')
              .width('100%')
          }
          .align(Alignment.Top)
          .layoutWeight(1)
          .width('100%')
          Row() {
            Button('复制全部')
              .fontSize(12)
              .height(30)
              .layoutWeight(1)
              .backgroundColor('#FF2F6C49')
              .fontColor('#FFE9EDF2')
              .onClick(() => {
                this.copyOcr();
              })
            Button('收起')
              .fontSize(12)
              .height(30)
              .layoutWeight(1)
              .margin({ left: 6 })
              .backgroundColor('#FF2A313A')
              .fontColor('#FFE9EDF2')
              .onClick(() => {
                this.ocrText = '';
              })
          }
          .margin({ top: 8 })
        }
        .width('100%')
        .height('100%')
        .padding(10)
        .backgroundColor('#E6101418')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FF101418')
    .border({ width: 1, color: '#802F6F4F' })
    .bindContextMenu(this.pinMenu(), ResponseType.RightClick)
    .onKeyEvent((ev: KeyEvent): boolean => {
      if (ev.type === KeyType.Down && ev.keyCode === KEYCODE_ESCAPE) {
        if (this.ocrText !== '') {
          this.ocrText = '';
        } else {
          this.close();
        }
        return true;
      }
      return false;
    })
    .onMouse((ev: MouseEvent): void => {
      // 鼠标拖拽走 onMouse。按下时会另送一个 onTouch.Down，startMove() 的 120ms 时间窗把重复的那次
      // 合并掉，否则第二次 startMoving 会被系统移动会话拒绝。
      if (ev.action === MouseAction.Press && ev.button === MouseButton.Left) {
        this.startMove();
      }
    })
    .onTouch((ev: TouchEvent): void => {
      // 手指和鼠标合成的 Down 都会进来，重复由 startMove() 的时间窗合并。
      if (ev.type === TouchType.Down) {
        this.startMove();
      }
    })
  }
}
