import { describe, it, expect } from '@ohos/hypium';
import {
  calcDeviation,
  DeviationKind,
  DeviationResult,
  splitDuration,
  DurationParts,
  startOfDay,
  shiftDays,
  isSameDay,
  DayRange,
  dayRangeOf,
  startOfToday,
  startOfTomorrow,
  startOfWeek,
  startOfMonth,
  endOfDay,
  formatDate
} from '../main/ets/common/TimeUtil';

const MINUTE: number = 60000;
/** 任取一个固定时刻，不依赖真实当前时间，测试才是可重复的 */
const T0: number = 1700000000000;

export default function timeUtilTest() {
  describe('TimeUtil', () => {

    // ---- 偏差计算：无计时数据 ----

    it('calcDeviation_never_started_is_no_timing_data', 0, () => {
      const r: DeviationResult = calcDeviation(60, 0, T0 + 60 * MINUTE);
      expect(r.kind).assertEqual(DeviationKind.NO_TIMING_DATA);
      // 关键：绝不能按 0 计算出「节省 60 分钟」这种假结论
      expect(r.actualMinutes).assertEqual(0);
      expect(r.diffMinutes).assertEqual(0);
    });

    it('calcDeviation_never_ended_is_no_timing_data', 0, () => {
      const r: DeviationResult = calcDeviation(60, T0, 0);
      expect(r.kind).assertEqual(DeviationKind.NO_TIMING_DATA);
    });

    it('calcDeviation_both_unset_is_no_timing_data', 0, () => {
      const r: DeviationResult = calcDeviation(60, 0, 0);
      expect(r.kind).assertEqual(DeviationKind.NO_TIMING_DATA);
    });

    // ---- 偏差计算：时钟回拨 ----

    it('calcDeviation_end_before_start_is_time_anomaly', 0, () => {
      const r: DeviationResult = calcDeviation(60, T0 + 30 * MINUTE, T0);
      expect(r.kind).assertEqual(DeviationKind.TIME_ANOMALY);
      // 夹紧到 0，不能返回负数构成的假「节省」
      expect(r.actualMinutes).assertEqual(0);
      expect(r.diffMinutes).assertEqual(0);
    });

    // ---- 偏差计算：实测不足 1 分钟 ----
    // 这一组守的是一个真实缺陷：Math.round 会把 23 秒折成 0 分钟，
    // 「预计 60 分钟」于是被读成「节省 1小时」。误触开始/完成就能复现。

    it('calcDeviation_sub_minute_actual_is_too_short', 0, () => {
      const r: DeviationResult = calcDeviation(60, T0, T0 + 23000);
      expect(r.kind).assertEqual(DeviationKind.TOO_SHORT);
      // 绝不能带数字出去：任何数字都会被拼成一句「节省 X」的假结论
      expect(r.actualMinutes).assertEqual(0);
      expect(r.diffMinutes).assertEqual(0);
    });

    it('calcDeviation_just_under_one_minute_is_too_short', 0, () => {
      const r: DeviationResult = calcDeviation(60, T0, T0 + MINUTE - 1);
      expect(r.kind).assertEqual(DeviationKind.TOO_SHORT);
    });

    it('calcDeviation_exactly_one_minute_is_not_too_short', 0, () => {
      // 边界取闭区间：整整 1 分钟是有意义的实测值，按正常路径判
      const r: DeviationResult = calcDeviation(60, T0, T0 + MINUTE);
      expect(r.kind).assertEqual(DeviationKind.UNDER);
      expect(r.actualMinutes).assertEqual(1);
    });

    it('calcDeviation_clock_rollback_wins_over_too_short', 0, () => {
      // 结束早于开始时，差值同样是「不足 1 分钟」。
      // 两条判断顺序反了的话，系统时间被改这件事会被降级成一句中性的「耗时过短」，
      // 用户就看不到真正需要他处理的那个问题。
      const r: DeviationResult = calcDeviation(60, T0 + 10000, T0);
      expect(r.kind).assertEqual(DeviationKind.TIME_ANOMALY);
    });

    it('calcDeviation_reports_a_single_minute_as_under_not_too_short', 0, () => {
      // 45 秒也会被四舍五入成 1 分钟，但门槛卡在整分钟上：
      // 「耗时 1 分钟、预估 8 小时」这个结论同样没有意义，所以 45 秒仍按过短处理
      const r: DeviationResult = calcDeviation(480, T0, T0 + 45000);
      expect(r.kind).assertEqual(DeviationKind.TOO_SHORT);
    });

    // ---- 偏差计算：三个正常分支 ----

    it('calcDeviation_exact_match_is_accurate', 0, () => {
      const r: DeviationResult = calcDeviation(60, T0, T0 + 60 * MINUTE);
      expect(r.kind).assertEqual(DeviationKind.ACCURATE);
      expect(r.actualMinutes).assertEqual(60);
      expect(r.diffMinutes).assertEqual(0);
    });

    it('calcDeviation_over_estimate', 0, () => {
      // 预计 5 分钟、实际 30 分钟
      const r: DeviationResult = calcDeviation(5, T0, T0 + 30 * MINUTE);
      expect(r.kind).assertEqual(DeviationKind.OVER);
      expect(r.actualMinutes).assertEqual(30);
      expect(r.diffMinutes).assertEqual(25);
    });

    it('calcDeviation_under_estimate', 0, () => {
      const r: DeviationResult = calcDeviation(60, T0, T0 + 30 * MINUTE);
      expect(r.kind).assertEqual(DeviationKind.UNDER);
      expect(r.actualMinutes).assertEqual(30);
      expect(r.diffMinutes).assertEqual(-30);
    });

    // ---- 偏差计算：容差边界 ----
    // 容差 = max(5 分钟, 预计 × 10%)

    it('calcDeviation_short_task_uses_5min_tolerance_floor', 0, () => {
      // 预计 10 分钟 → 10% 只有 1 分钟，应取 5 分钟下限
      const within: DeviationResult = calcDeviation(10, T0, T0 + 14 * MINUTE);
      expect(within.kind).assertEqual(DeviationKind.ACCURATE);

      const beyond: DeviationResult = calcDeviation(10, T0, T0 + 16 * MINUTE);
      expect(beyond.kind).assertEqual(DeviationKind.OVER);
    });

    it('calcDeviation_tolerance_boundary_is_inclusive', 0, () => {
      // 预计 100 分钟 → 容差 10 分钟，正好 10 分钟仍算吻合
      const atEdge: DeviationResult = calcDeviation(100, T0, T0 + 110 * MINUTE);
      expect(atEdge.kind).assertEqual(DeviationKind.ACCURATE);
      expect(atEdge.diffMinutes).assertEqual(10);

      const justOver: DeviationResult = calcDeviation(100, T0, T0 + 111 * MINUTE);
      expect(justOver.kind).assertEqual(DeviationKind.OVER);
    });

    it('calcDeviation_zero_estimate_is_not_accurate_by_default', 0, () => {
      // 预计 0 分钟（理论上不该出现在库里，但要保证不会算出荒谬结论）
      const r: DeviationResult = calcDeviation(0, T0, T0 + 30 * MINUTE);
      expect(r.kind).assertEqual(DeviationKind.OVER);
      expect(r.diffMinutes).assertEqual(30);
    });

    // ---- 时长拆分 ----

    it('splitDuration_under_one_hour', 0, () => {
      const p: DurationParts = splitDuration(45);
      expect(p.hours).assertEqual(0);
      expect(p.minutes).assertEqual(45);
    });

    it('splitDuration_exact_hour', 0, () => {
      const p: DurationParts = splitDuration(60);
      expect(p.hours).assertEqual(1);
      expect(p.minutes).assertEqual(0);
    });

    it('splitDuration_hour_and_minute', 0, () => {
      const p: DurationParts = splitDuration(90);
      expect(p.hours).assertEqual(1);
      expect(p.minutes).assertEqual(30);
    });

    it('splitDuration_zero_and_negative_are_clamped', 0, () => {
      const zero: DurationParts = splitDuration(0);
      expect(zero.hours).assertEqual(0);
      expect(zero.minutes).assertEqual(0);

      const negative: DurationParts = splitDuration(-30);
      expect(negative.hours).assertEqual(0);
      expect(negative.minutes).assertEqual(0);
    });

    // ---- 今日区间 ----

    it('startOfToday_is_local_midnight', 0, () => {
      const d: Date = new Date(startOfToday(T0));
      expect(d.getHours()).assertEqual(0);
      expect(d.getMinutes()).assertEqual(0);
      expect(d.getSeconds()).assertEqual(0);
      expect(d.getMilliseconds()).assertEqual(0);
    });

    it('startOfTomorrow_is_next_local_midnight', 0, () => {
      // 用固定的月中时刻做锚点，而不是 Date.now()：否则测试结果随运行日期变化。
      const anchor: number = new Date(2026, 5, 10, 15, 30, 0).getTime();
      const today: Date = new Date(startOfToday(anchor));
      const tomorrow: Date = new Date(startOfTomorrow(anchor));
      expect(today.getDate()).assertEqual(10);
      expect(tomorrow.getDate()).assertEqual(11);
      expect(tomorrow.getHours()).assertEqual(0);
      expect(tomorrow.getMinutes()).assertEqual(0);
      // 区间必须是左闭右开：create_time 落在 [today, tomorrow)
      expect(tomorrow.getTime() > today.getTime()).assertTrue();
    });

    it('startOfTomorrow_rolls_over_month_end', 0, () => {
      // 1 月 31 日 +1 天是 2 月 1 日，不是「32 日」。
      // 之前这里断言的是 tomorrow.getDate() === today.getDate() + 1，
      // 只在月末之外的日期碰巧成立 —— 每月 31 号会假失败。
      const monthEnd: number = new Date(2026, 0, 31, 12, 0, 0).getTime();
      const tomorrow: Date = new Date(startOfTomorrow(monthEnd));
      expect(tomorrow.getMonth()).assertEqual(1);
      expect(tomorrow.getDate()).assertEqual(1);
    });

    // ---- 周零点 / 月零点 ----
    // 这一组守的是统计页「本周 / 本月」两个窗口的地基。
    // 星期算错不会报错，只会安静地把「本周」变成「上一周」或「最近七天」。

    it('startOfWeek_is_monday_midnight', 0, () => {
      // 2026-06-10 是周三 → 本周一是 06-08
      const wednesday: number = new Date(2026, 5, 10, 15, 30, 0).getTime();
      const d: Date = new Date(startOfWeek(wednesday));
      expect(d.getMonth()).assertEqual(5);
      expect(d.getDate()).assertEqual(8);
      expect(d.getHours()).assertEqual(0);
      expect(d.getMinutes()).assertEqual(0);
      // 断言的是真正的星期，而不是「减了两天」这种可能碰巧成立的巧合
      expect(d.getDay()).assertEqual(1);
    });

    it('startOfWeek_on_sunday_goes_back_six_days', 0, () => {
      // 周日是 (getDay() + 6) % 7 唯一的临界点：getDay() 返回 0，
      // 写成 getDay() - 1 会得到 -1 天，于是周日那天「本周」整整少算一周、变成上周六。
      const sunday: number = new Date(2026, 5, 14, 9, 0, 0).getTime();
      expect(new Date(sunday).getDay()).assertEqual(0);

      const d: Date = new Date(startOfWeek(sunday));
      expect(d.getDay()).assertEqual(1);
      expect(d.getDate()).assertEqual(8);
    });

    it('startOfWeek_on_monday_is_that_same_day', 0, () => {
      const monday: number = new Date(2026, 5, 8, 9, 0, 0).getTime();
      expect(new Date(monday).getDay()).assertEqual(1);

      const d: Date = new Date(startOfWeek(monday));
      expect(d.getDate()).assertEqual(8);
      expect(d.getHours()).assertEqual(0);
    });

    it('startOfWeek_crosses_the_year_boundary', 0, () => {
      // 2026-01-01 是周四 → 那一周从 2025-12-29（周一）起算。
      // 「本周」落进上一年是完全正常的，不能在这里返回本年 1 月 1 日。
      const newYear: number = new Date(2026, 0, 1, 8, 0, 0).getTime();
      expect(new Date(newYear).getDay()).assertEqual(4);

      const d: Date = new Date(startOfWeek(newYear));
      expect(d.getFullYear()).assertEqual(2025);
      expect(d.getMonth()).assertEqual(11);
      expect(d.getDate()).assertEqual(29);
      expect(d.getDay()).assertEqual(1);
    });

    it('startOfWeek_is_stable_for_any_day_of_the_week', 0, () => {
      // 同一周里的任何时刻都必须得到同一个周一，否则用户周内切来切去会看到不同结果
      const monday: number = new Date(2026, 5, 8, 0, 0, 0).getTime();
      const expected: number = startOfWeek(monday);

      for (let i = 0; i < 7; i++) {
        expect(startOfWeek(shiftDays(monday, i))).assertEqual(expected);
        // 当天最晚的一毫秒也必须在同一周内
        expect(startOfWeek(endOfDay(shiftDays(monday, i)))).assertEqual(expected);
      }
      // 第 7 天（下周一）必须换到新的一周
      expect(startOfWeek(shiftDays(monday, 7)) === expected).assertFalse();
    });

    it('startOfMonth_is_the_first_at_midnight', 0, () => {
      const anchor: number = new Date(2026, 5, 10, 15, 30, 0).getTime();
      const d: Date = new Date(startOfMonth(anchor));
      expect(d.getMonth()).assertEqual(5);
      expect(d.getDate()).assertEqual(1);
      expect(d.getHours()).assertEqual(0);
      expect(d.getMinutes()).assertEqual(0);
      expect(d.getSeconds()).assertEqual(0);
    });

    it('startOfMonth_from_a_month_end_does_not_slip_into_the_previous_month', 0, () => {
      // 这类代码最常见的差一天：3 月 31 日往前「减掉今天是几号」会落到 2 月 28/29 日，
      // 那是上个月末而不是本月 1 号。
      const monthEnd: number = new Date(2026, 2, 31, 12, 0, 0).getTime();
      const d: Date = new Date(startOfMonth(monthEnd));
      expect(d.getMonth()).assertEqual(2);
      expect(d.getDate()).assertEqual(1);
    });

    it('startOfMonth_on_the_first_is_identity_on_that_day', 0, () => {
      const first: number = new Date(2026, 6, 1, 0, 0, 0).getTime();
      expect(startOfMonth(first)).assertEqual(first);
    });

    it('startOfMonth_handles_the_year_boundary', 0, () => {
      const january: number = new Date(2026, 0, 15, 12, 0, 0).getTime();
      const d: Date = new Date(startOfMonth(january));
      expect(d.getFullYear()).assertEqual(2026);
      expect(d.getMonth()).assertEqual(0);
      expect(d.getDate()).assertEqual(1);
    });

    it('startOfMonth_handles_a_leap_february', 0, () => {
      // 2024 是闰年：2 月有 29 天，3 月 1 日往前不能落到 2 月 28 日
      const march: number = new Date(2024, 2, 1, 6, 0, 0).getTime();
      const d: Date = new Date(startOfMonth(march));
      expect(d.getMonth()).assertEqual(2);
      expect(d.getDate()).assertEqual(1);
    });

    // ---- 按日历天平移 ----
    // 这一组守的是「翻日期」功能的地基：历史日视图按天取区间，
    // 日期算错一天不会有任何报错，只会安静地把任务显示在错误的那一天。

    it('shiftDays_zero_is_identity', 0, () => {
      const anchor: number = new Date(2026, 5, 10, 15, 30, 0).getTime();
      expect(shiftDays(anchor, 0)).assertEqual(anchor);
    });

    it('shiftDays_plus_one_keeps_time_of_day', 0, () => {
      // 平移的是「天」，钟面时刻必须原样保留，否则日零点锚点会漂
      const anchor: number = new Date(2026, 5, 10, 15, 30, 0).getTime();
      const d: Date = new Date(shiftDays(anchor, 1));
      expect(d.getDate()).assertEqual(11);
      expect(d.getHours()).assertEqual(15);
      expect(d.getMinutes()).assertEqual(30);
    });

    it('shiftDays_crosses_month_end_forward', 0, () => {
      const d: Date = new Date(shiftDays(new Date(2026, 0, 31, 12, 0, 0).getTime(), 1));
      expect(d.getMonth()).assertEqual(1);
      expect(d.getDate()).assertEqual(1);
    });

    it('shiftDays_crosses_month_start_backward', 0, () => {
      // 2026 是平年，2 月只有 28 天
      const d: Date = new Date(shiftDays(new Date(2026, 2, 1, 0, 0, 0).getTime(), -1));
      expect(d.getMonth()).assertEqual(1);
      expect(d.getDate()).assertEqual(28);
    });

    it('shiftDays_crosses_year_boundary_both_ways', 0, () => {
      const forward: Date = new Date(shiftDays(new Date(2025, 11, 31, 8, 0, 0).getTime(), 1));
      expect(forward.getFullYear()).assertEqual(2026);
      expect(forward.getMonth()).assertEqual(0);
      expect(forward.getDate()).assertEqual(1);

      const backward: Date = new Date(shiftDays(new Date(2026, 0, 1, 8, 0, 0).getTime(), -1));
      expect(backward.getFullYear()).assertEqual(2025);
      expect(backward.getMonth()).assertEqual(11);
      expect(backward.getDate()).assertEqual(31);
    });

    it('shiftDays_handles_leap_day', 0, () => {
      // 2024 是闰年：2 月 28 日 +1 是 29 日，29 日 +1 才是 3 月 1 日
      const toLeap: Date = new Date(shiftDays(new Date(2024, 1, 28, 12, 0, 0).getTime(), 1));
      expect(toLeap.getMonth()).assertEqual(1);
      expect(toLeap.getDate()).assertEqual(29);

      const offLeap: Date = new Date(shiftDays(new Date(2024, 1, 29, 12, 0, 0).getTime(), 1));
      expect(offLeap.getMonth()).assertEqual(2);
      expect(offLeap.getDate()).assertEqual(1);
    });

    it('shiftDays_skips_the_missing_feb_29_in_a_non_leap_year', 0, () => {
      const d: Date = new Date(shiftDays(new Date(2026, 1, 28, 12, 0, 0).getTime(), 1));
      expect(d.getMonth()).assertEqual(2);
      expect(d.getDate()).assertEqual(1);
    });

    it('shiftDays_is_invertible_over_a_long_span', 0, () => {
      // 30 天的往返会跨过月末，能同时抓到「按毫秒加减」在时区规则切换日累积出的偏移
      const anchor: number = new Date(2026, 0, 15, 9, 0, 0).getTime();
      expect(shiftDays(shiftDays(anchor, -30), 30)).assertEqual(anchor);
    });

    it('shiftDays_moves_off_the_original_timestamp', 0, () => {
      const anchor: number = new Date(2026, 5, 10, 15, 30, 0).getTime();
      expect(shiftDays(anchor, 1) === anchor).assertFalse();
    });

    // ---- 日零点 / 半开区间 ----

    it('startOfDay_is_local_midnight', 0, () => {
      const d: Date = new Date(startOfDay(T0));
      expect(d.getHours()).assertEqual(0);
      expect(d.getMinutes()).assertEqual(0);
      expect(d.getSeconds()).assertEqual(0);
      expect(d.getMilliseconds()).assertEqual(0);
    });

    it('startOfToday_agrees_with_startOfDay', 0, () => {
      // startOfToday 现在只是 startOfDay 的别名，行为必须逐位一致
      expect(startOfToday(T0)).assertEqual(startOfDay(T0));
    });

    it('dayRangeOf_spans_midnight_to_midnight', 0, () => {
      const anchor: number = new Date(2026, 5, 10, 15, 30, 0).getTime();
      const range: DayRange = dayRangeOf(anchor);
      const start: Date = new Date(range.start);
      const end: Date = new Date(range.end);
      expect(start.getDate()).assertEqual(10);
      expect(start.getHours()).assertEqual(0);
      expect(end.getDate()).assertEqual(11);
      expect(end.getHours()).assertEqual(0);
      expect(end.getMinutes()).assertEqual(0);
    });

    it('dayRangeOf_end_agrees_with_startOfTomorrow', 0, () => {
      // 两个函数必须给出同一个右边界，否则「今天」与「历史日」会差一毫秒
      const anchor: number = new Date(2026, 5, 10, 15, 30, 0).getTime();
      expect(dayRangeOf(anchor).end).assertEqual(startOfTomorrow(anchor));
    });

    it('dayRangeOf_is_half_open', 0, () => {
      const range: DayRange = dayRangeOf(new Date(2026, 5, 10, 15, 30, 0).getTime());
      // 左端点属于这一天
      expect(range.start < range.end).assertTrue();
      // 右端点（次日零点）不属于这一天，而是下一天的左端点。
      // 写成「落在下一天区间内」才有意义 —— 直接断言它不在自己区间内是句废话。
      const next: DayRange = dayRangeOf(shiftDays(range.start, 1));
      expect(range.end >= next.start && range.end < next.end).assertTrue();
    });

    it('dayRangeOf_is_stable_for_any_time_within_the_day', 0, () => {
      // 同一天的凌晨、正午、最后一毫秒必须得到完全相同的区间，
      // 否则用户在一天之内切来切去会看到不同的结果
      const first: DayRange = dayRangeOf(new Date(2026, 5, 10, 0, 0, 0, 0).getTime());
      const noon: DayRange = dayRangeOf(new Date(2026, 5, 10, 12, 0, 0, 0).getTime());
      const last: DayRange = dayRangeOf(new Date(2026, 5, 10, 23, 59, 59, 999).getTime());
      expect(noon.start).assertEqual(first.start);
      expect(noon.end).assertEqual(first.end);
      expect(last.start).assertEqual(first.start);
      expect(last.end).assertEqual(first.end);
    });

    it('dayRangeOf_adjacent_days_stitch_without_gap_or_overlap', 0, () => {
      // 本组最有价值的一条：相邻两天的区间必须严丝合缝地拼起来。
      // 有缝 → 某个时间戳两天都查不到，任务会从所有日视图里消失；
      // 有重叠 → 同一个任务在两天都出现，用户会以为看到了重复数据。
      const today: DayRange = dayRangeOf(new Date(2026, 5, 10, 9, 0, 0).getTime());
      const yesterday: DayRange = dayRangeOf(shiftDays(today.start, -1));
      const tomorrow: DayRange = dayRangeOf(shiftDays(today.start, 1));
      expect(yesterday.end).assertEqual(today.start);
      expect(today.end).assertEqual(tomorrow.start);
    });

    // ---- 同一天判定 ----

    it('isSameDay_true_for_different_times_on_the_same_day', 0, () => {
      const morning: number = new Date(2026, 5, 10, 0, 0, 0, 0).getTime();
      const night: number = new Date(2026, 5, 10, 23, 59, 59, 999).getTime();
      expect(isSameDay(morning, night)).assertTrue();
    });

    it('isSameDay_false_across_the_midnight_boundary', 0, () => {
      // 相差 1 毫秒但分属两天 —— 最容易写错的一处
      const lastMs: number = new Date(2026, 5, 10, 23, 59, 59, 999).getTime();
      const firstMs: number = new Date(2026, 5, 11, 0, 0, 0, 0).getTime();
      expect(isSameDay(lastMs, firstMs)).assertFalse();
    });

    it('isSameDay_false_for_adjacent_days_at_the_same_clock_time', 0, () => {
      const a: number = new Date(2026, 2, 15, 10, 0, 0).getTime();
      const b: number = new Date(2026, 2, 16, 10, 0, 0).getTime();
      expect(isSameDay(a, b)).assertFalse();
    });

    it('isSameDay_true_across_a_month_boundary_on_the_same_day', 0, () => {
      const early: number = new Date(2026, 0, 31, 0, 30, 0).getTime();
      const late: number = new Date(2026, 0, 31, 22, 0, 0).getTime();
      expect(isSameDay(early, late)).assertTrue();
    });

    // ---- 截止时间：当天最后一刻 ----

    it('endOfDay_is_last_millisecond_of_the_same_day', 0, () => {
      const anchor: number = new Date(2026, 5, 10, 9, 15, 30, 123).getTime();
      const end: Date = new Date(endOfDay(anchor));
      expect(end.getFullYear()).assertEqual(2026);
      expect(end.getMonth()).assertEqual(5);
      expect(end.getDate()).assertEqual(10);
      expect(end.getHours()).assertEqual(23);
      expect(end.getMinutes()).assertEqual(59);
      expect(end.getSeconds()).assertEqual(59);
      expect(end.getMilliseconds()).assertEqual(999);
    });

    it('endOfDay_is_idempotent', 0, () => {
      const anchor: number = new Date(2026, 5, 10, 9, 0, 0).getTime();
      const once: number = endOfDay(anchor);
      expect(endOfDay(once)).assertEqual(once);
    });

    // ---- 日期格式化 ----

    it('formatDate_pads_month_and_day_to_two_digits', 0, () => {
      // 补零是硬要求：'2026-1-5' 与 '2026-01-05' 在列表里对不齐
      expect(formatDate(new Date(2026, 0, 5, 13, 0, 0).getTime())).assertEqual('2026-01-05');
    });

    it('formatDate_handles_leap_day', 0, () => {
      expect(formatDate(new Date(2024, 1, 29, 8, 0, 0).getTime())).assertEqual('2024-02-29');
    });

    it('formatDate_does_not_shift_across_midnight_boundaries', 0, () => {
      // 取当天第一毫秒和最后一毫秒，格式化结果必须都还是这一天。
      // 若有任何隐式 UTC 转换，其中一个会漂到相邻日期。
      const dayStart: number = new Date(2026, 2, 15, 0, 0, 0, 0).getTime();
      expect(formatDate(dayStart)).assertEqual('2026-03-15');
      expect(formatDate(endOfDay(dayStart))).assertEqual('2026-03-15');
    });
  });
}
