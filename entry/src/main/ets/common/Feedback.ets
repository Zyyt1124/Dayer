import { promptAction, UIContext } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from './Logger';

const TAG: string = 'Feedback';

/**
 * 全局的 promptAction 静态方法（promptAction.showToast / showDialog）在 API 18 起已废弃，
 * 官方要求改用 UIContext 上的实例方法。这里统一封装，页面只传 UIContext。
 *
 * 两者的 .d.ts 都声明了 @throws，ArkTSCheck 要求显式处理，否则每个调用点都会报
 * "Function may throw exceptions" —— 所以 try/catch 是必需的，不是防御性冗余。
 */

/** 轻提示 */
export function showToast(ui: UIContext, message: Resource): void {
  try {
    ui.getPromptAction().showToast({ message: message });
  } catch (err) {
    const e: BusinessError = err as BusinessError;
    Logger.error(TAG, `showToast failed: ${e.code} ${e.message}`);
  }
}

/**
 * 二次确认框。确认动作固定放在下标 1（右侧按钮）。
 *
 * 不返回 Promise：调用方只关心「用户确认了没有」，用 onConfirm 回调承接即可，
 * 也免得每个调用点都要写一遍 then/catch。
 */
export function confirmDialog(ui: UIContext,
                              title: Resource,
                              message: Resource,
                              confirmText: Resource,
                              cancelText: Resource,
                              onConfirm: () => void): void {
  const buttons: promptAction.Button[] = [
    { text: cancelText, color: $r('app.color.text_secondary') },
    { text: confirmText, color: $r('app.color.deviation_over') }
  ];
  try {
    ui.getPromptAction()
      .showDialog({ title: title, message: message, buttons: buttons })
      .then((response: promptAction.ShowDialogSuccessResponse) => {
        if (response.index === 1) {
          onConfirm();
        }
      })
      .catch((err: BusinessError) => {
        Logger.error(TAG, `showDialog failed: ${err.code} ${err.message}`);
      });
  } catch (err) {
    const e: BusinessError = err as BusinessError;
    Logger.error(TAG, `showDialog threw: ${e.code} ${e.message}`);
  }
}
