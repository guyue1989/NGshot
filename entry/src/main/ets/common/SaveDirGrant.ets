import { fileShare } from '@kit.CoreFileKit';
import { picker } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

type LogFn = (line: string) => void;

// DocumentViewPicker 返回 file://docs/storage/Users/currentUser/... 形式的 URI。按 URI 解析会在文件名
// 含 # 时丢掉后面全部内容，fileIo 又不接受 URI，所以直接截掉 scheme 与 authority，再 percent-decode。
export function toPlainPath(p: string): string {
  if (!p.startsWith('file://')) {
    return p;
  }
  const rest: string = p.substring(7);
  const slash: number = rest.indexOf('/');
  if (slash < 0) {
    return '/';
  }
  const plain: string = rest.substring(slash);
  try {
    return decodeURIComponent(plain);
  } catch (e) {
    return plain;
  }
}

function policy(uri: string): fileShare.PolicyInfo {
  const p: fileShare.PolicyInfo = {
    uri: uri,
    // WRITE_MODE 不隐含 READ_MODE，只持久化写权限的话重启后目录读不了，用户得重选。
    operationMode: fileShare.OperationMode.READ_MODE | fileShare.OperationMode.WRITE_MODE
  };
  return p;
}

function describe(err: BusinessError<Array<fileShare.PolicyErrorResult>>): string {
  const data = err.data;
  if (data === undefined || data === null || data.length === 0) {
    return err.message;
  }
  let out: string = err.message;
  for (let i = 0; i < data.length; i++) {
    // PolicyErrorCode：1 不可持久化，2 模式非法，3 路径非法，4 未持久化过。
    out = out + ' | ' + data[i].uri + ' code=' + data[i].code + ' ' + data[i].message;
  }
  return out;
}

// 选择器给的授权随会话失效，所以选完目录就立刻持久化。
// 成功返回空串，失败返回原因，供界面就地显示。
export async function persistGrant(uri: string, log: LogFn): Promise<string> {
  try {
    await fileShare.persistPermission([policy(uri)]);
    log(`目录授权已持久化 ${uri}`);
    return '';
  } catch (e) {
    const err = e as BusinessError<Array<fileShare.PolicyErrorResult>>;
    const detail: string = describe(err);
    log(`持久化授权失败 code=${err.code} ${detail}`);
    return detail;
  }
}

// 持久化的授权要等 activatePermission 重新载入内存才能用，每次启动都要调一次。
export async function activateGrant(uri: string, log: LogFn): Promise<boolean> {
  try {
    await fileShare.activatePermission([policy(uri)]);
    log(`目录授权已激活 ${uri}`);
    return true;
  } catch (e) {
    const err = e as BusinessError<Array<fileShare.PolicyErrorResult>>;
    log(`激活授权失败 code=${err.code} ${describe(err)}（保存会退回沙箱目录或失败）`);
    return false;
  }
}

// 目录模式的 DocumentViewPicker 能拿到可写的公共目录，且不需要媒体库权限。
// 系统目录面板是唯一免受限权限就能写到用户可见位置的方式，SaveButton 则每张截图都要点一次。
export function pickSaveDir(ctx: common.UIAbilityContext, log: LogFn,
  onPicked: (uri: string) => void): void {
  try {
    const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
    options.selectMode = picker.DocumentSelectMode.FOLDER;
    const docPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(ctx);
    // AsyncCallback<Array<string>> 的 err 类型是 BusinessError<void>，若在 err 上也声明数据类型
    // 就成了不兼容的覆写，直接编译报错而不只是警告。
    docPicker.select(options, (err: BusinessError<void>, filePaths: Array<string>) => {
      if (err) {
        log(`选择保存目录失败 code=${err.code} msg=${err.message}`);
        return;
      }
      if (filePaths.length > 0) {
        onPicked(filePaths[0]);
      }
    });
  } catch (e) {
    const err = e as BusinessError;
    log(`打开目录选择器失败 code=${err.code} msg=${err.message}`);
  }
}
