import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * hilog 统一封装。
 * domain 必须是 0x0 - 0xFFFF 之间的数字，超出会导致日志不打印；tag 上限 31 字节。
 */
const DOMAIN: number = 0x0000;

export class Logger {
  static info(tag: string, message: string): void {
    hilog.info(DOMAIN, tag, '%{public}s', message);
  }

  static warn(tag: string, message: string): void {
    hilog.warn(DOMAIN, tag, '%{public}s', message);
  }

  static error(tag: string, message: string): void {
    hilog.error(DOMAIN, tag, '%{public}s', message);
  }
}
