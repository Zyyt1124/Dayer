import { describe, it, expect } from '@ohos/hypium';
import {
  MIN_REMINDER_MINUTES,
  ReminderSlot,
  ReminderStage,
  reminderSlots
} from '../main/ets/common/ReminderPlan';
// 80% 这个数已经搬到 TaskProgress —— 它才是唯一定义处（ReminderPlan 从那里 import）。
// 从定义处取来断言，顺便证明两个模块用的是同一个值。
import { WARN_RATIO } from '../main/ets/common/TaskProgress';

const MINUTE: number = 60000;
const T0: number = 1700000000000;

/** 把结果压成「阶段:剩余秒」的更易读形式，避免每个用例都去索引数组 */
function shape(slots: ReminderSlot[]): string {
  const parts: string[] = [];
  for (const slot of slots) {
    parts.push(`${slot.stage}:${slot.remainingSeconds}`);
  }
  return parts.join(',');
}

export default function reminderPlanTest() {
  describe('ReminderPlan', () => {

    it('no_slots_before_the_task_is_started', 0, () => {
      // 没点「开始」就没有计时基准，「跑了多久」无从谈起
      expect(shape(reminderSlots(60, 0, T0))).assertEqual('');
    });

    it('no_slots_for_a_short_task', 0, () => {
      // 十几分钟的事被系统弹窗打断一次，代价比它超时本身还大
      expect(MIN_REMINDER_MINUTES).assertEqual(15);
      expect(shape(reminderSlots(10, T0, T0))).assertEqual('');
      expect(shape(reminderSlots(14, T0, T0))).assertEqual('');
    });

    it('a_task_exactly_at_the_threshold_does_get_slots', 0, () => {
      // 边界归上：15 分钟整要登记，否则「至少 15 分钟」这句话就是错的
      expect(shape(reminderSlots(15, T0, T0))).assertEqual('0:720,1:900');
    });

    it('skips_slots_that_are_too_short_but_keeps_the_rest', 0, () => {
      const slots: ReminderSlot[] = reminderSlots(60, T0, T0 + 49 * MINUTE);

      expect(slots.length).assertEqual(1);
      expect(slots[0].stage).assertEqual(ReminderStage.DUE);
      expect(slots[0].remainingSeconds).assertEqual(11 * 60);
    });

    it('a_fresh_start_gets_both_slots', 0, () => {
      // 预估 60 分钟：80% 在 48 分钟处，100% 在 60 分钟处
      const slots: ReminderSlot[] = reminderSlots(60, T0, T0);

      expect(slots.length).assertEqual(2);
      expect(slots[0].stage).assertEqual(ReminderStage.WARN);
      expect(slots[0].remainingSeconds).assertEqual(48 * 60);
      expect(slots[1].stage).assertEqual(ReminderStage.DUE);
      expect(slots[1].remainingSeconds).assertEqual(60 * 60);
      expect(WARN_RATIO).assertEqual(0.8);
    });

    it('drops_the_warn_slot_once_it_has_passed', 0, () => {
      // 应用被重启后对账时会走到这里：80% 已经过去了，只剩到点那一条该登记
      const slots: ReminderSlot[] = reminderSlots(60, T0, T0 + 50 * MINUTE);

      expect(slots.length).assertEqual(1);
      expect(slots[0].stage).assertEqual(ReminderStage.DUE);
      expect(slots[0].remainingSeconds).assertEqual(10 * 60);
    });

    it('returns_nothing_once_the_estimate_is_exceeded', 0, () => {
      // 已经超时了，再登记一条「你超时了」的提醒毫无意义
      expect(shape(reminderSlots(60, T0, T0 + 61 * MINUTE))).assertEqual('');
      expect(shape(reminderSlots(60, T0, T0 + 10 * 60 * MINUTE))).assertEqual('');
    });

    it('drops_a_slot_that_is_only_seconds_away', 0, () => {
      // 打开应用时任务已经跑过头了，此时弹一条几秒后触发的提醒纯属噪音 ——
      // 用户人就在应用里，看得见进度
      const now: number = T0 + 48 * MINUTE - 20 * 1000;
      const slots: ReminderSlot[] = reminderSlots(60, T0, now);

      expect(slots.length).assertEqual(1);
      expect(slots[0].stage).assertEqual(ReminderStage.DUE);
    });

    it('keeps_a_slot_that_is_comfortably_ahead', 0, () => {
      // 只看剩余秒数，不看它是哪个阶段：80% 那条剩得够多就照样登记
      const now: number = T0 + 48 * MINUTE - 5 * MINUTE;
      const slots: ReminderSlot[] = reminderSlots(60, T0, now);

      expect(slots.length).assertEqual(2);
      expect(slots[0].stage).assertEqual(ReminderStage.WARN);
      expect(slots[0].remainingSeconds).assertEqual(5 * 60);
    });

    it('every_returned_slot_is_in_the_future', 0, () => {
      // 倒计时秒数恒为正：登记一条 0 秒或负数秒的提醒要么立刻炸，要么被系统拒绝
      const offsets: number[] = [0, 10 * MINUTE, 47 * MINUTE, 47 * MINUTE + 40 * 1000];
      for (const offset of offsets) {
        const slots: ReminderSlot[] = reminderSlots(60, T0, T0 + offset);
        for (const slot of slots) {
          expect(slot.remainingSeconds > 0).assertTrue();
        }
      }
    });

    it('warn_always_comes_before_due', 0, () => {
      const slots: ReminderSlot[] = reminderSlots(120, T0, T0);
      expect(slots.length).assertEqual(2);
      expect(slots[0].remainingSeconds < slots[1].remainingSeconds).assertTrue();
      expect(slots[0].stage).assertEqual(ReminderStage.WARN);
      expect(slots[1].stage).assertEqual(ReminderStage.DUE);
    });

    it('rounds_partial_seconds_up', 0, () => {
      // 剩 30.5 秒算 31 秒，不能向下取整成 30 —— 半秒的误差会把「刚好够」翻成「不够」。
      // 取 30.5 秒而不是 0.5 秒：0.5 秒那条会先被最小提前量挡掉，验不到取整规则。
      const now: number = T0 + 48 * MINUTE - 30500;
      const slots: ReminderSlot[] = reminderSlots(60, T0, now);

      expect(slots.length).assertEqual(2);
      expect(slots[0].stage).assertEqual(ReminderStage.WARN);
      expect(slots[0].remainingSeconds).assertEqual(31);
    });

    it('drops_a_slot_with_a_sub_second_lead', 0, () => {
      // 剩 0.5 秒：向上取整是 1 秒，但仍然远低于最小提前量，必须丢掉。
      // 这一条同时守住「不能让 0 秒或负数秒流到提醒登记接口」。
      const now: number = T0 + 48 * MINUTE - 500;
      expect(shape(reminderSlots(60, T0, now))).assertEqual('1:721');
    });
  });
}
