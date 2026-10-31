import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'NGshotProbe';

// 日志回调：写文件的地方只需要一个收字符串的函数，调用方各自决定顺手打到哪。
export type LogFn = (line: string) => void;

// 运行日志同时落一份到文件：界面收进状态栏后屏幕上没有输出可看，
// 设置页的「诊断与日志」也直接读这个文件。
export class ProbeLog {
  private static filePath: string = '';

  static init(dir: string): void {
    ProbeLog.filePath = `${dir}/probe.log`;
  }

  static path(): string {
    return ProbeLog.filePath;
  }

  static add(line: string): void {
    hilog.info(DOMAIN, TAG, '%{public}s', line);
    if (ProbeLog.filePath === '') {
      return;
    }
    try {
      const file = fs.openSync(ProbeLog.filePath,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.APPEND);
      fs.writeSync(file.fd, `${ProbeLog.stamp()} ${line}\n`);
      fs.closeSync(file);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'probe log write failed: %{public}s', JSON.stringify(e));
    }
  }

  static read(): string {
    if (ProbeLog.filePath === '') {
      return '';
    }
    try {
      if (!fs.accessSync(ProbeLog.filePath)) {
        return '';
      }
      return fs.readTextSync(ProbeLog.filePath);
    } catch (e) {
      return '';
    }
  }

  static clear(): void {
    if (ProbeLog.filePath === '') {
      return;
    }
    try {
      if (fs.accessSync(ProbeLog.filePath)) {
        fs.unlinkSync(ProbeLog.filePath);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'probe log clear failed: %{public}s', JSON.stringify(e));
    }
  }

  private static stamp(): string {
    const d = new Date();
    const p = (n: number, w: number): string => n.toString().padStart(w, '0');
    return `${p(d.getHours(), 2)}:${p(d.getMinutes(), 2)}:${p(d.getSeconds(), 2)}.${p(d.getMilliseconds(), 3)}`;
  }
}
