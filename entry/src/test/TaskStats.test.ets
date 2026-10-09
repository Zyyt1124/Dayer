import { describe, it, expect } from '@ohos/hypium';
import {
  completedCount,
  computeStats,
  StatsResult,
  statsWindow,
  WINDOW_ALL,
  WINDOW_MONTH,
  WINDOW_TODAY,
  WINDOW_WEEK
} from '../main/ets/common/TaskStats';
import { DayRange } from '../main/ets/common/TimeUtil';
import { Task, TaskStatus } from '../main/ets/model/Task';

const MINUTE: number = 60000;
/** 任取一个固定时刻，不依赖真实当前时间，测试才是可重复的 */
const T0: number = 1700000000000;

const WORK: number = 0;
const STUDY: number = 1;
const LIFE: number = 2;

/** 浮点不能用 assertEqual 直接比，逐位相等在除法里本来就不该强求 */
function near(actual: number, expected: number): boolean {
  return Math.abs(actual - expected) < 1e-9;
}

/** 一条「点过开始、也有结束时间」的任务。actualMinutes 传 0 会落进 TOO_SHORT */
function timedTask(status: number, categoryId: number,
                   estimatedMinutes: number, actualMinutes: number): Task {
  const t: Task = new Task();
  t.status = status;
  t.categoryId = categoryId;
  t.estimatedMinutes = estimatedMinutes;
  t.actualStartTime = T0;
  t.actualEndTime = T0 + actualMinutes * MINUTE;
  return t;
}

/** 从没点过开始的任务：两个时间戳都留 0 */
function untimedTask(status: number, categoryId: number, estimatedMinutes: number): Task {
  const t: Task = new Task();
  t.status = status;
  t.categoryId = categoryId;
  t.estimatedMinutes = estimatedMinutes;
  return t;
}

/** 造 n 条同类、预估 est、实际 actual 的任务 */
function repeat(count: number, status: number, categoryId: number,
                est: number, actual: number): Task[] {
  const list: Task[] = [];
  for (let i = 0; i < count; i++) {
    list.push(timedTask(status, categoryId, est, actual));
  }
  return list;
}

export default function taskStatsTest() {
  describe('TaskStats', () => {

    // ---- 时间窗口 ----

    it('statsWindow_today_is_one_calendar_day', 0, () => {
      const now: number = new Date(2026, 5, 10, 15, 30, 0).getTime();
      const range: DayRange = statsWindow(now, WINDOW_TODAY);
      const start: Date = new Date(range.start);
      const end: Date = new Date(range.end);

      expect(start.getDate()).assertEqual(10);
      expect(start.getHours()).assertEqual(0);
      expect(end.getDate()).assertEqual(11);
      expect(end.getHours()).assertEqual(0);
      expect(end.getMinutes()).assertEqual(0);
    });

    it('statsWindow_week_starts_on_monday', 0, () => {
      // 2026-06-10 是周三 → 本周应从周一 6-08 起算
      const wednesday: number = new Date(2026, 5, 10, 15, 30, 0).getTime();
      const start: Date = new Date(statsWindow(wednesday, WINDOW_WEEK).start);
      expect(start.getMonth()).assertEqual(5);
      expect(start.getDate()).assertEqual(8);
      expect(start.getHours()).assertEqual(0);
      // getDay() 里 1 是周一；这里断言的是真正的星期，而不是「减了两天」
      expect(start.getDay()).assertEqual(1);
    });

    it('statsWindow_week_on_a_sunday_goes_back_six_days_not_minus_one', 0, () => {
      // 周日是 (getDay() + 6) % 7 唯一的临界点：直接写 getDay() - 1 会算出 -1 天，
      // 于是「本周」在周日那天整整少算一周、变成上一周的周六
      const sunday: number = new Date(2026, 5, 14, 9, 0, 0).getTime();
      const start: Date = new Date(statsWindow(sunday, WINDOW_WEEK).start);
      expect(start.getDay()).assertEqual(1);
      expect(start.getDate()).assertEqual(8);
    });

    it('statsWindow_week_on_a_monday_is_that_same_day', 0, () => {
      const monday: number = new Date(2026, 5, 8, 9, 0, 0).getTime();
      const start: Date = new Date(statsWindow(monday, WINDOW_WEEK).start);
      expect(start.getDate()).assertEqual(8);
      expect(start.getDay()).assertEqual(1);
    });

    it('statsWindow_month_starts_on_the_first', 0, () => {
      const now: number = new Date(2026, 5, 10, 15, 30, 0).getTime();
      const start: Date = new Date(statsWindow(now, WINDOW_MONTH).start);
      expect(start.getMonth()).assertEqual(5);
      expect(start.getDate()).assertEqual(1);
      expect(start.getHours()).assertEqual(0);
    });

    it('statsWindow_month_from_a_month_end_does_not_slip_into_the_previous_month', 0, () => {
      // 3 月 31 日往前「减 30 天」会落到 3 月 1 日、减 31 天会落到 2 月 ——
      // setDate(1) 直接改日历字段才不会有这类差一天
      const monthEnd: number = new Date(2026, 2, 31, 12, 0, 0).getTime();
      const start: Date = new Date(statsWindow(monthEnd, WINDOW_MONTH).start);
      expect(start.getMonth()).assertEqual(2);
      expect(start.getDate()).assertEqual(1);

      const firstDay: number = new Date(2026, 6, 1, 0, 30, 0).getTime();
      const startOfJuly: Date = new Date(statsWindow(firstDay, WINDOW_MONTH).start);
      expect(startOfJuly.getMonth()).assertEqual(6);
      expect(startOfJuly.getDate()).assertEqual(1);
    });

    it('statsWindow_all_has_no_lower_bound', 0, () => {
      const now: number = new Date(2026, 5, 10, 15, 30, 0).getTime();
      const range: DayRange = statsWindow(now, WINDOW_ALL);
      expect(range.start).assertEqual(0);
      // 右边界仍必须是明天零点：它由「今天」决定，与左边界无关
      expect(range.end).assertEqual(statsWindow(now, WINDOW_TODAY).end);
    });

    it('statsWindow_unknown_value_falls_back_to_today', 0, () => {
      // 防御性：传了没定义的窗口号时不能算出 [0, 0) 这种空区间
      const now: number = new Date(2026, 5, 10, 15, 30, 0).getTime();
      expect(statsWindow(now, 99).start).assertEqual(statsWindow(now, WINDOW_TODAY).start);
    });

    // ---- 完成情况：三桶 ----

    it('computeStats_empty_input_is_all_zero', 0, () => {
      const s: StatsResult = computeStats([]);
      expect(s.settledCount).assertEqual(0);
      expect(s.doneOnTimeCount).assertEqual(0);
      expect(s.doneLateCount).assertEqual(0);
      expect(s.unfinishedCount).assertEqual(0);
      expect(s.timedCount).assertEqual(0);
      expect(s.totalActualMinutes).assertEqual(0);
      expect(s.categories.length).assertEqual(0);
      // 没有样本时倍率不可解读，但绝不能是 NaN
      expect(s.overallBias.ready).assertFalse();
      expect(s.overallBias.medianRatio).assertEqual(1);
      expect(completedCount(s)).assertEqual(0);
    });

    it('computeStats_counts_the_three_buckets', 0, () => {
      const onTime: Task = timedTask(TaskStatus.COMPLETED, WORK, 60, 60);
      const late: Task = timedTask(TaskStatus.COMPLETED, WORK, 60, 60);
      // 截止时间设在实际结束之前 —— 逾期与否由 isCompletedLate() 推导，不是一种状态
      late.deadline = T0 + 10 * MINUTE;
      const unfinished: Task = untimedTask(TaskStatus.UNFINISHED, STUDY, 60);

      const s: StatsResult = computeStats([onTime, late, unfinished]);

      expect(s.doneOnTimeCount).assertEqual(1);
      expect(s.doneLateCount).assertEqual(1);
      expect(s.unfinishedCount).assertEqual(1);
      expect(s.settledCount).assertEqual(3);
      // 延期也算做完 —— 它只是晚了，不是没做完
      expect(completedCount(s)).assertEqual(2);
    });

    it('computeStats_completed_without_a_deadline_is_never_late', 0, () => {
      // 没设截止时间的任务无从谈逾期，不该被算成延期
      const t: Task = timedTask(TaskStatus.COMPLETED, WORK, 60, 600);
      expect(t.deadline).assertEqual(0);

      const s: StatsResult = computeStats([t]);
      expect(s.doneOnTimeCount).assertEqual(1);
      expect(s.doneLateCount).assertEqual(0);
    });

    it('computeStats_makes_no_claim_about_unsettled_tasks', 0, () => {
      // 待开始 / 进行中的任务既不算完成也不算失败 —— 一个今天刚建、还没轮到做的任务
      // 被计成失败，会让【今日】的完成率永远接近 0
      const notStarted: Task = timedTask(TaskStatus.NOT_STARTED, WORK, 60, 60);
      const inProgress: Task = timedTask(TaskStatus.IN_PROGRESS, WORK, 60, 30);

      const s: StatsResult = computeStats([notStarted, inProgress]);
      expect(s.settledCount).assertEqual(0);
      expect(s.doneOnTimeCount).assertEqual(0);
      expect(s.unfinishedCount).assertEqual(0);
      // 但它们照样可能记了实际耗时，估时表现要把它们算进来
      expect(s.timedCount).assertEqual(2);
    });

    it('computeStats_never_started_unfinished_carries_no_timing', 0, () => {
      // ⚠️ 这一条钉的是本模块头注释里写明的**已知缺口**，不是理想行为：
      // 从没点过开始就被标为未完成的任务，actualEndTime 是 0，带不出任何计时数据。
      // 它在「创建于窗口 ∪ 结束于窗口」两条分支里都落不进去，会被漏掉，使完成率偏高。
      // 日后若有人「顺手修好」它（比如改用状态本身去圈任务），这条断言会红 —— 那是提醒他
      // 这会引入与首页不同的第二套取数口径，得先想清楚再动。
      const t: Task = untimedTask(TaskStatus.UNFINISHED, WORK, 60);
      const s: StatsResult = computeStats([t]);

      expect(s.unfinishedCount).assertEqual(1);
      expect(s.settledCount).assertEqual(1);
      expect(s.timedCount).assertEqual(0);
      expect(s.totalActualMinutes).assertEqual(0);
      expect(s.categories.length).assertEqual(0);
    });

    // ---- 估时表现：分母只收有结论的 ----

    it('computeStats_excludes_every_kind_without_a_conclusion', 0, () => {
      const comparable: Task = timedTask(TaskStatus.COMPLETED, WORK, 60, 60);
      const tooShort: Task = timedTask(TaskStatus.COMPLETED, WORK, 60, 0);
      const neverStarted: Task = untimedTask(TaskStatus.COMPLETED, WORK, 60);
      const anomaly: Task = timedTask(TaskStatus.COMPLETED, WORK, 60, 10);
      // 结束早于开始：通常是用户改了系统时间，那个差值不是耗时
      anomaly.actualEndTime = anomaly.actualStartTime - MINUTE;

      const s: StatsResult = computeStats([comparable, tooShort, neverStarted, anomaly]);

      // 四条任务里只有一条有可比的实测值
      expect(s.timedCount).assertEqual(1);
      expect(s.accurateCount).assertEqual(1);
      expect(s.totalActualMinutes).assertEqual(60);
      // 完成情况那一侧不受影响，四条都算已结算
      expect(s.settledCount).assertEqual(4);
    });

    it('computeStats_just_under_one_minute_is_too_short', 0, () => {
      // 45 秒会被四舍五入成 1 分钟，但门槛卡在整分钟上（与 calcDeviation 同一口径）。
      // 放它进来会造出「预估 8 小时、实际 1 分钟」这种把统计污染成「我一直在高估」的结论。
      const t: Task = timedTask(TaskStatus.COMPLETED, WORK, 480, 0);
      t.actualEndTime = t.actualStartTime + 45 * 1000;

      const s: StatsResult = computeStats([t]);
      expect(s.timedCount).assertEqual(0);
    });

    it('computeStats_splits_accurate_over_and_under', 0, () => {
      // 容差 = max(5 分钟, 预估 × 10%)，这里预估 100 → 容差 10 分钟
      const accurate: Task = timedTask(TaskStatus.COMPLETED, WORK, 100, 110);
      const over: Task = timedTask(TaskStatus.COMPLETED, WORK, 100, 150);
      const under: Task = timedTask(TaskStatus.COMPLETED, WORK, 100, 60);

      const s: StatsResult = computeStats([accurate, over, under]);
      expect(s.timedCount).assertEqual(3);
      expect(s.accurateCount).assertEqual(1);
      expect(s.overCount).assertEqual(1);
      expect(s.underCount).assertEqual(1);
      expect(s.totalActualMinutes).assertEqual(110 + 150 + 60);
    });

    it('computeStats_counts_a_task_without_a_finish_claim', 0, () => {
      // 未完成的任务同样可能记了实际耗时，估时照样能判断准不准 ——
      // 分母用的是「可比条数」而不是「已结算条数」，就是为这种情况
      const t: Task = timedTask(TaskStatus.UNFINISHED, WORK, 60, 60);
      const s: StatsResult = computeStats([t]);

      expect(s.timedCount).assertEqual(1);
      expect(s.unfinishedCount).assertEqual(1);
    });

    // ---- 分类耗时占比 ----

    it('computeStats_category_shares_sum_to_one', 0, () => {
      const tasks: Task[] = [];
      for (const t of repeat(2, TaskStatus.COMPLETED, WORK, 30, 30)) {
        tasks.push(t);
      }
      tasks.push(timedTask(TaskStatus.COMPLETED, STUDY, 20, 20));

      const s: StatsResult = computeStats(tasks);
      expect(s.categories.length).assertEqual(2);
      expect(s.totalActualMinutes).assertEqual(80);

      let sum: number = 0;
      for (const item of s.categories) {
        sum += item.share;
      }
      expect(near(sum, 1)).assertTrue();
    });

    it('computeStats_single_category_takes_the_whole_share', 0, () => {
      const s: StatsResult = computeStats(repeat(3, TaskStatus.COMPLETED, LIFE, 40, 40));
      expect(s.categories.length).assertEqual(1);
      expect(s.categories[0].categoryId).assertEqual(LIFE);
      expect(near(s.categories[0].share, 1)).assertTrue();
      expect(s.categories[0].actualMinutes).assertEqual(120);
    });

    it('computeStats_orders_categories_by_actual_minutes_descending', 0, () => {
      const tasks: Task[] = [
        timedTask(TaskStatus.COMPLETED, STUDY, 10, 10),
        timedTask(TaskStatus.COMPLETED, WORK, 90, 90),
        timedTask(TaskStatus.COMPLETED, LIFE, 50, 50)
      ];

      const s: StatsResult = computeStats(tasks);
      expect(s.categories.length).assertEqual(3);
      expect(s.categories[0].categoryId).assertEqual(WORK);
      expect(s.categories[1].categoryId).assertEqual(LIFE);
      expect(s.categories[2].categoryId).assertEqual(STUDY);
    });

    it('computeStats_leaves_categories_without_timing_out', 0, () => {
      // 只做过「工作」，就不该铺出学习/生活/娱乐/健身四条 0 耗时的空条
      const s: StatsResult = computeStats([timedTask(TaskStatus.COMPLETED, WORK, 30, 30)]);
      expect(s.categories.length).assertEqual(1);
      expect(s.categories[0].categoryId).assertEqual(WORK);
    });

    it('computeStats_category_bias_needs_min_samples', 0, () => {
      // 学习类只有 2 条 —— 少于 EstimateBias.MIN_SAMPLES(3)，必须直说「样本还不够」，
      // 而不是拿这两条编一个倍率出来
      const tasks: Task[] = [
        timedTask(TaskStatus.COMPLETED, STUDY, 60, 120),
        timedTask(TaskStatus.COMPLETED, STUDY, 60, 120),
        timedTask(TaskStatus.COMPLETED, WORK, 100, 100)
      ];

      const s: StatsResult = computeStats(tasks);
      // 按耗时降序：学习 120 分钟在前，工作 100 分钟在后
      expect(s.categories.length).assertEqual(2);
      expect(s.categories[0].categoryId).assertEqual(STUDY);
      expect(s.categories[0].biasReady).assertFalse();
      // 未就绪时倍率给 1.0（「就按你估的来」），调用方只能靠 biasReady 判断
      expect(s.categories[0].medianRatio).assertEqual(1);
      // 工作类只有 1 条，同样不够
      expect(s.categories[1].categoryId).assertEqual(WORK);
      expect(s.categories[1].biasReady).assertFalse();
    });

    it('computeStats_category_bias_ready_at_min_samples', 0, () => {
      const s: StatsResult = computeStats(repeat(3, TaskStatus.COMPLETED, LIFE, 60, 120));

      expect(s.categories[0].biasReady).assertTrue();
      expect(near(s.categories[0].medianRatio, 2)).assertTrue();
      // 整体倍率与单分类倍率取自同一批样本，单分类时两者必须一致
      expect(s.overallBias.ready).assertTrue();
      expect(near(s.overallBias.medianRatio, 2)).assertTrue();
    });

    it('computeStats_overall_bias_pools_every_category', 0, () => {
      // 每个分类各自只有 1 条（都不够 3 条），但合起来是 3 条 —— 整体倍率应当就绪
      const tasks: Task[] = [
        timedTask(TaskStatus.COMPLETED, WORK, 60, 90),
        timedTask(TaskStatus.COMPLETED, STUDY, 60, 90),
        timedTask(TaskStatus.COMPLETED, LIFE, 60, 90)
      ];

      const s: StatsResult = computeStats(tasks);
      expect(s.overallBias.ready).assertTrue();
      expect(s.overallBias.sampleCount).assertEqual(3);
      expect(near(s.overallBias.medianRatio, 1.5)).assertTrue();
      // 三个分类各自都不到 MIN_SAMPLES
      for (const item of s.categories) {
        expect(item.biasReady).assertFalse();
      }
    });

    it('computeStats_skips_bias_samples_with_a_zero_estimate', 0, () => {
      // 预估 0 分钟算不出比值。它仍是一次有结论的实测（calcDeviation 判 OVER），
      // 所以进得了计数，但绝不能进倍率样本 —— 当成 1.0 混进去会稀释掉真实偏差
      const s: StatsResult = computeStats(repeat(3, TaskStatus.COMPLETED, WORK, 0, 60));

      expect(s.timedCount).assertEqual(3);
      expect(s.overCount).assertEqual(3);
      expect(s.overallBias.ready).assertFalse();
      expect(s.overallBias.sampleCount).assertEqual(0);
    });

    it('computeStats_is_deterministic_regardless_of_input_order', 0, () => {
      const a: Task = timedTask(TaskStatus.COMPLETED, WORK, 100, 100);
      const b: Task = timedTask(TaskStatus.COMPLETED, STUDY, 50, 50);
      const c: Task = timedTask(TaskStatus.COMPLETED, LIFE, 50, 50);

      const forward: StatsResult = computeStats([a, b, c]);
      const backward: StatsResult = computeStats([c, b, a]);

      expect(forward.categories.length).assertEqual(backward.categories.length);
      for (let i = 0; i < forward.categories.length; i++) {
        expect(forward.categories[i].categoryId).assertEqual(backward.categories[i].categoryId);
        expect(forward.categories[i].actualMinutes).assertEqual(backward.categories[i].actualMinutes);
      }
    });

    it('computeStats_ranks_ties_by_category_id', 0, () => {
      // 两个分类耗时完全一样时，顺序不能随任务在数组里的先后漂 ——
      // 同一份数据两次打开长得不一样，用户会以为数字变了
      const study: Task = timedTask(TaskStatus.COMPLETED, STUDY, 50, 50);
      const work: Task = timedTask(TaskStatus.COMPLETED, WORK, 50, 50);

      const s: StatsResult = computeStats([study, work]);
      expect(s.categories[0].categoryId).assertEqual(WORK);
      expect(s.categories[1].categoryId).assertEqual(STUDY);
    });
  });
}
