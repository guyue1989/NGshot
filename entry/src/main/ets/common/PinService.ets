// 贴图登记表。屏幕上可以同时有多张贴图，所有 PinAbility 都在同一进程（module.json5 未配 process 字段），
// 裁图字节走本模块的 Map 传递：ArrayBuffer 过一次 AppStorage 就不再是原生 buffer，单个持有变量又会被
// 下一张贴图覆盖。字符串和数字本可以走 AppStorage，但统一一条通道更好排查。
export interface PinStage {
  id: number;
  w: number;
  h: number;
  x: number;
  y: number;
}

let pinSeq: number = 0;
const buffers = new Map<number, ArrayBuffer>();
let pending: PinStage | null = null;
let pagePin: PinStage | null = null;

// 暂存一张待贴的裁图。x/y 是屏幕 px：框选层铺满全屏且起点为 (0,0)，图像 px 与屏幕 px 同一套坐标。
// 返回该贴图终生使用的 id。
export function stagePin(buf: ArrayBuffer, w: number, h: number, x: number, y: number): number {
  pinSeq += 1;
  buffers.set(pinSeq, buf);
  pending = { id: pinSeq, w: w, h: h, x: x, y: y };
  return pinSeq;
}

// PinAbility.onCreate 调用：把暂存的贴图从交接槽取出。
export function consumePendingPin(): PinStage | null {
  const p: PinStage | null = pending;
  pending = null;
  return p;
}

// 能力到页面、窗口的桥：onCreate 存入贴图，页面 aboutToAppear 和 makePinWindow 都只读它。
// 槽位会被下一张贴图的 onCreate 覆盖；UI 线程单线程且贴图逐个启动，消费者总能在下一次
// startAbility 之前读到自己那张。
export function setPagePin(pin: PinStage | null): void {
  pagePin = pin;
}

export function peekPagePin(): PinStage | null {
  return pagePin;
}

export function pinBufferNow(id: number): ArrayBuffer | null {
  const b: ArrayBuffer | undefined = buffers.get(id);
  return b === undefined ? null : b;
}

export function dropPin(id: number): void {
  buffers.delete(id);
}
