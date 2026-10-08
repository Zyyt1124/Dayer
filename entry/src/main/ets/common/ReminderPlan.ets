import { MS_PER_MINUTE } from './TimeUtil';
import { WARN_RATIO } from './TaskProgress';

/**
 * 「任务跑到预估时长的哪个位置该提醒」的时点计算。
 *
 * 抽成纯函数的原因和 TimeUtil 一样：时间边界（刚好越过 80%、刚好超过 100%、
 * 剩余只剩几秒）是最容易算错又最难在真机上复现的地方，必须能逐条断言。
 *
 * ⚠️ 本文件禁止 import 任何 @kit 模块，也禁止使用 $r() 资源引用。
 *
 * ⚠️⚠️ **当前没有任何生产代码引用本文件**，不要以为它接上了。「谁在什么时点该被打断」
 * 这部分逻辑已经改由 `TaskProgress.ets` 承担（应用内卡片 + 进度提示，随时可单测、
 * 不依赖任何系统能力）。留在这里的是「假如将来走系统通知」需要的时间点算术：
 * 那条路已实测不可用 —— 代理提醒在未签名构建下配额恒为 0（`1700002`），
 * 需要在 AGC 申请「代理提醒」开放能力并重新签发 Profile 才有配额；
 * 而普通通知在 API 15 拿不到「有图标、无提示音无横幅」那一档（`LEVEL_LOW` 不可达）。
 *
 * 为什么停在 80% 而不是等到超时：等到 100% 才说话，用户能做的只剩「事后记账」；
 * 80% 时还剩两成时间，足够决定「收尾」还是「改预估」，这才叫纠偏而不是通报。
 */

/**
 * 短于这个时长的任务不登记提醒。
 * 十几分钟的事被系统弹窗打断一次，代价比它超时本身还大。
 */
export const MIN_REMINDER_MINUTES: number = 15;

/**
 * 剩余不足这个秒数就不登记了。
 * 打开应用时任务已经跑到 11 分 58 秒，此时登记一条 2 秒后触发的提醒纯属噪音 ——
 * 用户人就在应用里，看得见进度。
 */
const MIN_LEAD_SECONDS: number = 30;

const MS_PER_SECOND: number = 1000;

/** 提醒阶段。数值会落进通知文案的资源 key，不要随手调整顺序 */
export enum ReminderStage {
  /** 预估时长的 80%：还剩两成，来得及调整 */
  WARN = 0,
  /** 预估时长的 100%：到点了 */
  DUE = 1
}

/** 一个待登记的提醒时点 */
export class ReminderSlot {
  stage: ReminderStage;
  /** 距离该时点还有多少秒，恒 > 0 */
  remainingSeconds: number;

  constructor(stage: ReminderStage, remainingSeconds: number) {
    this.stage = stage;
    this.remainingSeconds = remainingSeconds;
  }
}

function pushIfStillAhead(slots: ReminderSlot[], stage: ReminderStage,
                          at: number, now: number): void {
  const remainingSeconds: number = Math.ceil((at - now) / MS_PER_SECOND);
  if (remainingSeconds < MIN_LEAD_SECONDS) {
    return;
  }
  slots.push(new ReminderSlot(stage, remainingSeconds));
}

/**
 * 算出当前还该登记哪几条提醒。
 *
 * 返回的是「尚未越过的时点」，所以：
 * - 刚点开始 → 返回 80% 和 100% 两条；
 * - 已经过了 80% 但没到 100%（例如应用被重启后对账）→ 只返回 100% 那一条；
 * - 都过了，或任务太短，或压根没点开始 → 空数组。
 *
 * ⚠️ 返回两条时必须**分别登记两条独立的倒计时提醒**，不能指望一条提醒重复触发：
 * ReminderRequestTimer 的 repeatInterval / repeatCount 是 @since 26.0.0，本工程（API 15）用不了。
 *
 * @param estimatedMinutes 预估耗时（分钟）
 * @param actualStartTime  实际开始时间戳，0 表示没点过开始
 * @param now              当前时间戳，由调用方传入以保证可测
 */
export function reminderSlots(estimatedMinutes: number,
                              actualStartTime: number,
                              now: number): ReminderSlot[] {
  const slots: ReminderSlot[] = [];
  // 没点开始就没有计时基准，也就无从说起「跑了多久」
  if (actualStartTime <= 0) {
    return slots;
  }
  if (estimatedMinutes < MIN_REMINDER_MINUTES) {
    return slots;
  }

  const warnAt: number = actualStartTime + estimatedMinutes * WARN_RATIO * MS_PER_MINUTE;
  const dueAt: number = actualStartTime + estimatedMinutes * MS_PER_MINUTE;

  pushIfStillAhead(slots, ReminderStage.WARN, warnAt, now);
  pushIfStillAhead(slots, ReminderStage.DUE, dueAt, now);
  return slots;
}
