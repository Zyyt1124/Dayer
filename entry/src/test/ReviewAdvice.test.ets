import { describe, it, expect } from '@ohos/hypium';
import {
  Advice,
  AdviceCode,
  buildReview,
  MAX_ADVICE,
  ReviewResult
} from '../main/ets/common/ReviewAdvice';
import { ANY_CATEGORY, MIN_SAMPLES } from '../main/ets/common/EstimateBias';
import { computeStats, StatsResult } from '../main/ets/common/TaskStats';
import { Task, TaskPriority, TaskStatus } from '../main/ets/model/Task';

const MINUTE: number = 60000;
/** 任取一个固定时刻，不依赖真实当前时间，测试才是可重复的 */
const T0: number = 1700000000000;

const WORK: number = 0;
const STUDY: number = 1;
const LIFE: number = 2;

const COMPLETED: number = TaskStatus.COMPLETED;
const UNFINISHED: number = TaskStatus.UNFINISHED;

/**
 * 一条「点过开始、也有结束时间」的任务。
 * deadlineMinutes 传 0 表示不设截止时间（与内存哨兵约定一致，见 Task.ets 头注释）。
 */
function timedTask(status: number, categoryId: number, est: number, actual: number,
                   priority: number, deadlineMinutes: number): Task {
  const t: Task = new Task();
  t.status = status;
  t.categoryId = categoryId;
  t.estimatedMinutes = est;
  t.priority = priority;
  t.actualStartTime = T0;
  t.actualEndTime = T0 + actual * MINUTE;
  if (deadlineMinutes > 0) {
    t.deadline = T0 + deadlineMinutes * MINUTE;
  }
  return t;
}

/** 常用形态：中优先级、不设截止时间 */
function done(categoryId: number, est: number, actual: number): Task {
  return timedTask(COMPLETED, categoryId, est, actual, TaskPriority.MEDIUM, 0);
}

/** 从没点过开始的任务：两个时间戳都留 0，于是既不进计时类分母，也不进 LATE 的分母 */
function idle(status: number, categoryId: number, priority: number): Task {
  const t: Task = new Task();
  t.status = status;
  t.categoryId = categoryId;
  t.priority = priority;
  return t;
}

function repeat(count: number, make: () => Task): Task[] {
  const list: Task[] = [];
  for (let i = 0; i < count; i++) {
    list.push(make());
  }
  return list;
}

/**
 * 找出某类建议。**找不到时返回 numerator = -1 的哨兵**，调用方断言 -1 即「没触发」。
 * 刻意不用 Array.find（返回 T | undefined，本工程实体类一律非可选）。
 */
function adviceOf(result: ReviewResult, code: AdviceCode): Advice {
  let found: Advice = new Advice(code, ANY_CATEGORY, 0, -1, -1);
  for (const item of result.advices) {
    if (item.code === code) {
      found = item;
    }
  }
  return found;
}

/** 结果里有没有这一类建议 */
function hasCode(result: ReviewResult, code: AdviceCode): boolean {
  return adviceOf(result, code).numerator !== -1;
}

export default function reviewAdviceTest() {
  describe('ReviewAdvice', () => {

    // ---- 空与门槛 ----

    it('buildReview_empty_tasks_gives_nothing_and_does_not_throw', 0, () => {
      const result: ReviewResult = buildReview([]);

      expect(result.advices.length).assertEqual(0);
      expect(result.hasEnoughData).assertFalse();
      expect(result.basisCount).assertEqual(0);
      expect(result.timedCount).assertEqual(0);
    });

    it('buildReview_enough_data_but_no_rule_fires', 0, () => {
      // 3 条都估得准（100/100）→ 没有偏差可报；但计时样本够了 → hasEnoughData 为真。
      // 页面据此显示「没发现明显的规律」，而不是「记录还太少」——这是两句话，不能混。
      const result: ReviewResult = buildReview(repeat(3, () => done(WORK, 100, 100)));

      expect(result.advices.length).assertEqual(0);
      expect(result.hasEnoughData).assertTrue();
      expect(result.basisCount).assertEqual(3);
      expect(result.timedCount).assertEqual(3);
    });

    it('buildReview_first_day_user_gets_no_advice', 0, () => {
      // 装好第一天：1 条记录。既不该说「这类只记了 1 条」，也不该说任何别的
      const result: ReviewResult = buildReview(repeat(1, () => done(STUDY, 100, 120)));

      expect(result.advices.length).assertEqual(0);
      expect(result.hasEnoughData).assertFalse();
    });

    // ---- 分类偏差：超时 ----

    it('category_over_fires_at_exactly_1_2', 0, () => {
      const result: ReviewResult = buildReview(repeat(3, () => done(STUDY, 100, 120)));
      const advice: Advice = adviceOf(result, AdviceCode.CATEGORY_OVER);

      expect(advice.categoryId).assertEqual(STUDY);
      expect(advice.tenths).assertEqual(12);
      expect(advice.numerator).assertEqual(3);
    });

    it('category_over_does_not_fire_while_display_stays_below_1_2', 0, () => {
      // 1.14 落在「估得准」带之外，但卡上会显示成「1.1 倍」—— 那个数没碰到线，不该报
      const result: ReviewResult = buildReview(repeat(3, () => done(STUDY, 100, 114)));

      expect(hasCode(result, AdviceCode.CATEGORY_OVER)).assertFalse();
      expect(result.advices.length).assertEqual(0);
    });

    it('category_over_fires_once_rounding_reaches_the_line', 0, () => {
      // 1.15 本身没到 1.2，但卡上显示的是「1.2 倍」。
      // 判断与显示必须判同一个量：用户盯着屏上的 1.2 倍却等不到建议，是说不通的。
      const result: ReviewResult = buildReview(repeat(3, () => done(STUDY, 100, 115)));
      const advice: Advice = adviceOf(result, AdviceCode.CATEGORY_OVER);

      expect(advice.categoryId).assertEqual(STUDY);
      expect(advice.tenths).assertEqual(12);
    });

    it('category_over_does_not_fire_when_not_ready', 0, () => {
      // 2 条 1.5 倍：倍率本身很好，但样本不到 MIN_SAMPLES，不能拿它下结论
      const result: ReviewResult = buildReview(repeat(2, () => done(STUDY, 100, 150)));

      expect(hasCode(result, AdviceCode.CATEGORY_OVER)).assertFalse();
      expect(result.advices.length).assertEqual(0);
    });

    // ---- 分类偏差：提前 ----

    it('category_under_fires_at_exactly_0_8', 0, () => {
      const result: ReviewResult = buildReview(repeat(3, () => done(STUDY, 100, 80)));
      const advice: Advice = adviceOf(result, AdviceCode.CATEGORY_UNDER);

      expect(advice.categoryId).assertEqual(STUDY);
      expect(advice.tenths).assertEqual(8);
    });

    it('category_under_fires_once_rounding_reaches_the_line', 0, () => {
      // 设备上的真实数据：工作类中位倍率 0.8333，卡上显示「0.8 倍」。
      // 改口径前它不发建议，改完必须发 —— 否则就是「屏上写着 0.8 倍、规则却不认 0.8」
      const result: ReviewResult = buildReview(repeat(3, () => done(WORK, 60, 50)));
      const advice: Advice = adviceOf(result, AdviceCode.CATEGORY_UNDER);

      expect(advice.categoryId).assertEqual(WORK);
      expect(advice.tenths).assertEqual(8);
    });

    it('category_under_does_not_fire_while_display_stays_above_0_8', 0, () => {
      // 0.86 显示成「0.9 倍」，没碰到线
      const result: ReviewResult = buildReview(repeat(3, () => done(WORK, 100, 86)));

      expect(hasCode(result, AdviceCode.CATEGORY_UNDER)).assertFalse();
      expect(result.advices.length).assertEqual(0);
    });

    it('category_drift_takes_at_most_two_worst_first', 0, () => {
      // 三个分类都超时，只报最严重的两条 —— 否则同一维度吃满整张卡，
      // 完成度那边的问题一条都露不出来
      const tasks: Task[] = [];
      for (const t of repeat(3, () => done(WORK, 100, 150))) {
        tasks.push(t);
      }
      for (const t of repeat(3, () => done(STUDY, 100, 140))) {
        tasks.push(t);
      }
      for (const t of repeat(3, () => done(LIFE, 100, 130))) {
        tasks.push(t);
      }

      const result: ReviewResult = buildReview(tasks);

      expect(result.advices.length).assertEqual(2);
      expect(result.advices[0].categoryId).assertEqual(WORK);
      expect(result.advices[1].categoryId).assertEqual(STUDY);
      expect(hasCode(result, AdviceCode.CATEGORY_OVER)).assertTrue();
    });

    it('category_drift_ties_break_by_category_id', 0, () => {
      // 两个分类的偏差幅度一样、只能报两条时，顺序不能随任务顺序漂
      const tasks: Task[] = [];
      for (const t of repeat(3, () => done(LIFE, 100, 150))) {
        tasks.push(t);
      }
      for (const t of repeat(3, () => done(WORK, 100, 150))) {
        tasks.push(t);
      }

      const result: ReviewResult = buildReview(tasks);

      expect(result.advices[0].categoryId).assertEqual(WORK);
      expect(result.advices[1].categoryId).assertEqual(LIFE);
    });

    // ---- 「还差几条」 ----

    it('category_near_reports_gap_to_min_samples', 0, () => {
      // 学习类 2 条计时 + 1 条从没开始的 → 结算量够开这个口，但学习类还差 1 条
      const tasks: Task[] = [];
      for (const t of repeat(2, () => done(STUDY, 100, 120))) {
        tasks.push(t);
      }
      tasks.push(idle(UNFINISHED, WORK, TaskPriority.MEDIUM));

      const result: ReviewResult = buildReview(tasks);
      const advice: Advice = adviceOf(result, AdviceCode.CATEGORY_NEAR);

      // ⚠️ categoryId 必须是真分类，不能是 ANY_CATEGORY —— 页面的 chip 用
      // categoryText(advice.categoryId)，而它的兜底分支返回「工作」，
      // 会把这句「学习类还差 1 条」挂到一个「工作」标签上
      expect(advice.categoryId).assertEqual(STUDY);
      expect(advice.numerator).assertEqual(2);
      expect(advice.denominator).assertEqual(MIN_SAMPLES);
      // 页面用 分母 - 分子 得「还差 1 条」
      expect(advice.denominator - advice.numerator).assertEqual(1);
    });

    it('category_near_ignores_category_with_zero_valid_samples', 0, () => {
      // ⚠️ 这条是「预估填 0」那个边界：computeStats 按「有可比时长」建分类桶，
      // 所以这两条任务在分类卡上有一条实实在在的耗时条；但 estimateBias 会剔掉
      // estimatedMinutes ≤ 0 的样本，于是它的 sampleCount 是 0。
      // 不排掉它就会显示「这一类只记了 0 / 3 条」——用户明明看得到那条耗时。
      const tasks: Task[] = [];
      for (const t of repeat(2, () => done(STUDY, 0, 60))) {
        tasks.push(t);
      }
      tasks.push(idle(UNFINISHED, WORK, TaskPriority.MEDIUM));

      const result: ReviewResult = buildReview(tasks);

      // 先确认前提成立：桶在、耗时在，但有效样本是 0
      const stats: StatsResult = computeStats(tasks);
      expect(stats.categories.length).assertEqual(1);
      expect(stats.categories[0].actualMinutes).assertEqual(120);
      expect(stats.categories[0].sampleCount).assertEqual(0);

      expect(hasCode(result, AdviceCode.CATEGORY_NEAR)).assertFalse();
      expect(result.advices.length).assertEqual(0);
    });

    it('category_near_needs_some_settled_tasks_globally', 0, () => {
      // 全局只有 2 条已结算（不到 MIN_SAMPLES）→ 连「还差几条」都不该说，
      // 那只是在陈述「你刚装了这个 App」
      const result: ReviewResult = buildReview(repeat(2, () => done(STUDY, 100, 120)));

      expect(hasCode(result, AdviceCode.CATEGORY_NEAR)).assertFalse();
      expect(result.advices.length).assertEqual(0);
    });

    it('category_near_picks_most_samples_then_lowest_category_id', 0, () => {
      // collectNear 内部有两个分支，样本数 1 / 2 / 2 一次全覆盖：
      // 样本多的赢（2 压过 1），样本并列时按分类 id 升序（学习 1 压过 生活 2）。
      // 设备上那份真实数据就是靠第二次并列选出「学习类还差 1 条」的。
      const tasks: Task[] = [];
      tasks.push(done(WORK, 100, 120));
      for (const t of repeat(2, () => done(LIFE, 100, 120))) {
        tasks.push(t);
      }
      for (const t of repeat(2, () => done(STUDY, 100, 120))) {
        tasks.push(t);
      }
      // 再补一条没记时的未完成：把全局已结算抬过 NEAR 的门槛，
      // 且 idle 既不进计时分母、也不凭空造出一个分类桶
      tasks.push(idle(UNFINISHED, WORK, TaskPriority.MEDIUM));

      const result: ReviewResult = buildReview(tasks);
      const advice: Advice = adviceOf(result, AdviceCode.CATEGORY_NEAR);

      // 这一份数据只该出这一条：完成 4/5 没跌破七成、计时 4/5 没过半、全中优先级
      expect(result.advices.length).assertEqual(1);
      expect(hasCode(result, AdviceCode.CATEGORY_NEAR)).assertTrue();
      expect(advice.categoryId).assertEqual(STUDY);
      expect(advice.numerator).assertEqual(2);
      expect(advice.denominator).assertEqual(MIN_SAMPLES);
    });

    it('category_near_tie_break_does_not_follow_input_order', 0, () => {
      // 并列若按「先遇到的赢」，同一份数据换个查询顺序就会改口 ——
      // 工作 与 生活 的样本数一样时，屏幕上那句话不能今天说学习明天说生活
      const forward: Task[] = [];
      const backward: Task[] = [];
      for (const t of repeat(2, () => done(STUDY, 100, 120))) {
        forward.push(t);
        backward.unshift(t);
      }
      for (const t of repeat(2, () => done(LIFE, 100, 120))) {
        forward.push(t);
        backward.unshift(t);
      }
      // unshift 之后 生活 排在 学习 前面：这正是能把「先遇到的赢」照出来的顺序
      forward.push(idle(UNFINISHED, WORK, TaskPriority.MEDIUM));
      backward.push(idle(UNFINISHED, WORK, TaskPriority.MEDIUM));

      const a: ReviewResult = buildReview(forward);
      const b: ReviewResult = buildReview(backward);

      expect(adviceOf(a, AdviceCode.CATEGORY_NEAR).categoryId).assertEqual(STUDY);
      expect(adviceOf(b, AdviceCode.CATEGORY_NEAR).categoryId).assertEqual(STUDY);
    });

    // ---- 计时覆盖率 ----

    it('timing_coverage_fires_below_half', 0, () => {
      // 5 条已结算、只有 2 条记了计时 → 复盘只能覆盖那 2 条
      const tasks: Task[] = [];
      for (const t of repeat(2, () => done(WORK, 100, 100))) {
        tasks.push(t);
      }
      for (const t of repeat(3, () => idle(UNFINISHED, WORK, TaskPriority.MEDIUM))) {
        tasks.push(t);
      }

      const result: ReviewResult = buildReview(tasks);
      const advice: Advice = adviceOf(result, AdviceCode.TIMING_COVERAGE);

      expect(advice.numerator).assertEqual(2);
      expect(advice.denominator).assertEqual(5);
    });

    it('timing_coverage_does_not_fire_at_half', 0, () => {
      // 恰好一半（3/5）不算「太低」，线画在严格小于一半
      const tasks: Task[] = [];
      for (const t of repeat(3, () => done(WORK, 100, 100))) {
        tasks.push(t);
      }
      for (const t of repeat(2, () => done(WORK, 100, 0))) {
        // 计时过短（0 分钟）会落进 TOO_SHORT，同样不进计时类 —— 但它是已完成
        tasks.push(t);
      }

      const result: ReviewResult = buildReview(tasks);

      expect(result.timedCount).assertEqual(3);
      expect(hasCode(result, AdviceCode.TIMING_COVERAGE)).assertFalse();
    });

    it('timing_coverage_needs_min_settled', 0, () => {
      // 4 条已结算、1 条计时：比例很低，但分母不到 5，不下结论
      const tasks: Task[] = [];
      for (const t of repeat(1, () => done(WORK, 100, 100))) {
        tasks.push(t);
      }
      for (const t of repeat(3, () => idle(UNFINISHED, WORK, TaskPriority.MEDIUM))) {
        tasks.push(t);
      }

      const result: ReviewResult = buildReview(tasks);

      expect(hasCode(result, AdviceCode.TIMING_COVERAGE)).assertFalse();
    });

    // ---- 完成率 ----

    it('completion_low_fires_below_seven_tenths', 0, () => {
      // 10 条结算、6 条完成 → 6/10 < 7/10
      const tasks: Task[] = [];
      for (const t of repeat(6, () => done(WORK, 100, 100))) {
        tasks.push(t);
      }
      for (const t of repeat(4, () => idle(UNFINISHED, WORK, TaskPriority.MEDIUM))) {
        tasks.push(t);
      }

      const result: ReviewResult = buildReview(tasks);
      const advice: Advice = adviceOf(result, AdviceCode.COMPLETION_LOW);

      expect(advice.numerator).assertEqual(4);
      expect(advice.denominator).assertEqual(10);
    });

    it('completion_low_does_not_fire_at_exactly_seven_tenths', 0, () => {
      // 7/10 正好在线上 —— 线上不报，报的是「低于」
      const tasks: Task[] = [];
      for (const t of repeat(7, () => done(WORK, 100, 100))) {
        tasks.push(t);
      }
      for (const t of repeat(3, () => idle(UNFINISHED, WORK, TaskPriority.MEDIUM))) {
        tasks.push(t);
      }

      const result: ReviewResult = buildReview(tasks);

      expect(hasCode(result, AdviceCode.COMPLETION_LOW)).assertFalse();
      expect(result.advices.length).assertEqual(0);
    });

    // ---- 延期完成 ----

    it('late_fires_when_third_of_deadlined_work_is_late', 0, () => {
      // 3 条设了截止时间的已完成任务，1 条超时 → 1/3 达到线
      const tasks: Task[] = [];
      tasks.push(timedTask(COMPLETED, STUDY, 100, 100, TaskPriority.MEDIUM, 50));
      tasks.push(timedTask(COMPLETED, STUDY, 100, 100, TaskPriority.MEDIUM, 200));
      tasks.push(timedTask(COMPLETED, STUDY, 100, 100, TaskPriority.MEDIUM, 200));

      const result: ReviewResult = buildReview(tasks);
      const advice: Advice = adviceOf(result, AdviceCode.LATE);

      expect(advice.numerator).assertEqual(1);
      expect(advice.denominator).assertEqual(3);
    });

    it('late_ignores_tasks_without_deadline', 0, () => {
      // ⚠️ 这条钉住 LATE 的分母定义：必须是「已完成**且有截止时间**」的条数。
      // 3 条已完成里只有 1 条设了截止时间 —— 若拿 completedCount(3) 当分母，
      // 1 条超时就会被报成 1/3「踩线」。Task.isCompletedLate() 要求 deadline > 0，
      // 从不设截止时间的人本该什么都看不到，而不是看到一句假的「你总在踩线」。
      const tasks: Task[] = [];
      tasks.push(timedTask(COMPLETED, STUDY, 100, 100, TaskPriority.MEDIUM, 50));
      tasks.push(done(STUDY, 100, 100));
      tasks.push(done(STUDY, 100, 100));

      const stats: StatsResult = computeStats(tasks);
      expect(stats.settledCount).assertEqual(3);

      const result: ReviewResult = buildReview(tasks);

      expect(hasCode(result, AdviceCode.LATE)).assertFalse();
      expect(result.advices.length).assertEqual(0);
    });

    it('late_needs_at_least_three_deadlined', 0, () => {
      // 2 条设了截止时间、1 条超时 → 比例 1/2 远超线，但基数太小（碰巧而已）
      const tasks: Task[] = [];
      tasks.push(timedTask(COMPLETED, STUDY, 100, 100, TaskPriority.MEDIUM, 50));
      tasks.push(timedTask(COMPLETED, STUDY, 100, 100, TaskPriority.MEDIUM, 200));

      const result: ReviewResult = buildReview(tasks);

      expect(hasCode(result, AdviceCode.LATE)).assertFalse();
    });

    // ---- 优先级 ----

    it('priority_low_fires_when_high_priority_lags_behind', 0, () => {
      // 高优先级 5 条结算只完成 2 条（2/5），其他 5 条全完成（5/5）
      const tasks: Task[] = [];
      for (const t of repeat(2, () => timedTask(
        COMPLETED, WORK, 100, 100, TaskPriority.HIGH, 0))) {
        tasks.push(t);
      }
      for (const t of repeat(3, () => idle(UNFINISHED, WORK, TaskPriority.HIGH))) {
        tasks.push(t);
      }
      for (const t of repeat(5, () => timedTask(
        COMPLETED, WORK, 100, 100, TaskPriority.MEDIUM, 0))) {
        tasks.push(t);
      }

      const result: ReviewResult = buildReview(tasks);
      const advice: Advice = adviceOf(result, AdviceCode.PRIORITY_LOW);

      expect(advice.numerator).assertEqual(2);
      expect(advice.denominator).assertEqual(5);
    });

    it('priority_low_does_not_fire_at_seven_tenths', 0, () => {
      // 高优先级 7/10 = 0.7，比其他的 10/10 低得多 —— 但 0.7 本身不算低。
      // 没有绝对水位这条判据的话，这里会报出一句「高优先级完成率偏低」的假话。
      const tasks: Task[] = [];
      for (const t of repeat(7, () => timedTask(
        COMPLETED, WORK, 100, 100, TaskPriority.HIGH, 0))) {
        tasks.push(t);
      }
      for (const t of repeat(3, () => idle(UNFINISHED, WORK, TaskPriority.HIGH))) {
        tasks.push(t);
      }
      for (const t of repeat(10, () => timedTask(
        COMPLETED, WORK, 100, 100, TaskPriority.MEDIUM, 0))) {
        tasks.push(t);
      }

      const result: ReviewResult = buildReview(tasks);

      expect(hasCode(result, AdviceCode.PRIORITY_LOW)).assertFalse();
    });

    it('priority_low_needs_both_sides_at_least_four', 0, () => {
      // 高优先级只有 3 条结算（0/3），其他 10 条全完成 —— 3 条时完成率只能取
      // 0/0.33/0.67/1，一格之差就翻面，判据太脆，所以两侧都要够条数
      const tasks: Task[] = [];
      for (const t of repeat(3, () => idle(UNFINISHED, WORK, TaskPriority.HIGH))) {
        tasks.push(t);
      }
      for (const t of repeat(10, () => timedTask(
        COMPLETED, WORK, 100, 100, TaskPriority.MEDIUM, 0))) {
        tasks.push(t);
      }

      const result: ReviewResult = buildReview(tasks);

      expect(hasCode(result, AdviceCode.PRIORITY_LOW)).assertFalse();
    });

    it('priority_low_compares_against_non_high_priority_not_overall', 0, () => {
      // 这条钉住「与谁比」。整体**包含高优先级自身**，子集和含自身的超集比，
      // 差异会被自己稀释掉 —— 高优先级越是不行，它对自己所在那个整体的拖累越大。
      //
      // 构造：高优先级 3/5 = 0.6，其他 17/20 = 0.85，整体 20/25 = 0.8。
      //   · 与「非高优先级」比：0.6 < 0.85 - 0.2 = 0.65  → 触发 ✓
      //   · 与「整体」比：      0.6 < 0.8  - 0.2 = 0.60  → 不触发 ✗（正好卡在线上）
      // 所以这条用例过了，就说明用的是补集而不是整体。
      const tasks: Task[] = [];
      for (const t of repeat(3, () => timedTask(
        COMPLETED, WORK, 100, 100, TaskPriority.HIGH, 0))) {
        tasks.push(t);
      }
      for (const t of repeat(2, () => idle(UNFINISHED, WORK, TaskPriority.HIGH))) {
        tasks.push(t);
      }
      for (const t of repeat(17, () => timedTask(
        COMPLETED, WORK, 100, 100, TaskPriority.MEDIUM, 0))) {
        tasks.push(t);
      }
      for (const t of repeat(3, () => idle(UNFINISHED, WORK, TaskPriority.MEDIUM))) {
        tasks.push(t);
      }

      const result: ReviewResult = buildReview(tasks);
      const advice: Advice = adviceOf(result, AdviceCode.PRIORITY_LOW);

      expect(advice.numerator).assertEqual(3);
      expect(advice.denominator).assertEqual(5);
    });

    // ---- 排序与截断 ----

    it('buildReview_orders_completion_before_good_news_and_truncates', 0, () => {
      // 四个维度同时触发，但要按严重度排、并截断到 MAX_ADVICE：
      //   COMPLETION_LOW(0) → CATEGORY_OVER(1) → LATE(2) → CATEGORY_UNDER(6)
      // CATEGORY_UNDER 被挤掉是**故意的**：它是好消息（可以少留点余量），
      // 不该挤掉任何一条警告。
      const tasks: Task[] = [];
      // 工作类普遍超时（3 条 1.5 倍）
      for (const t of repeat(3, () => done(WORK, 100, 150))) {
        tasks.push(t);
      }
      // 学习类普遍提前（3 条 0.8 倍），且有 1 条超时完成
      tasks.push(timedTask(COMPLETED, STUDY, 100, 80, TaskPriority.MEDIUM, 50));
      tasks.push(timedTask(COMPLETED, STUDY, 100, 80, TaskPriority.MEDIUM, 200));
      tasks.push(timedTask(COMPLETED, STUDY, 100, 80, TaskPriority.MEDIUM, 200));
      // 4 条没做完 → 完成率 6/10
      for (const t of repeat(4, () => idle(UNFINISHED, LIFE, TaskPriority.MEDIUM))) {
        tasks.push(t);
      }

      const result: ReviewResult = buildReview(tasks);

      expect(result.advices.length).assertEqual(MAX_ADVICE);
      expect(result.advices[0].code).assertEqual(AdviceCode.COMPLETION_LOW);
      expect(result.advices[1].code).assertEqual(AdviceCode.CATEGORY_OVER);
      expect(result.advices[2].code).assertEqual(AdviceCode.LATE);
      expect(hasCode(result, AdviceCode.CATEGORY_UNDER)).assertFalse();
    });

    it('buildReview_reports_category_under_when_it_is_all_there_is', 0, () => {
      // 只有好消息时也要说 —— 「你这类总是提前」配「预估可以再紧一点」是有用的
      const result: ReviewResult = buildReview(repeat(3, () => done(STUDY, 100, 80)));
      const advice: Advice = adviceOf(result, AdviceCode.CATEGORY_UNDER);

      expect(advice.categoryId).assertEqual(STUDY);
      expect(result.advices.length).assertEqual(1);
    });

    it('buildReview_is_independent_of_task_input_order', 0, () => {
      // 分类偏差并列时顺序不能随任务顺序漂 —— 同一份数据两次打开必须长得一样
      const forward: Task[] = [];
      const backward: Task[] = [];
      for (const t of repeat(3, () => done(LIFE, 100, 150))) {
        forward.push(t);
        backward.unshift(t);
      }
      for (const t of repeat(3, () => done(WORK, 100, 150))) {
        forward.push(t);
        backward.unshift(t);
      }

      const a: ReviewResult = buildReview(forward);
      const b: ReviewResult = buildReview(backward);

      expect(b.advices.length).assertEqual(a.advices.length);
      for (let i = 0; i < a.advices.length; i++) {
        expect(b.advices[i].code).assertEqual(a.advices[i].code);
        expect(b.advices[i].categoryId).assertEqual(a.advices[i].categoryId);
      }
      expect(a.advices[0].categoryId).assertEqual(WORK);
    });

    it('buildReview_does_not_mutate_input_tasks', 0, () => {
      // buildReview 只收 tasks、内部自己 computeStats，所以它**够不着**调用方的
      // stats 对象（这正是单参数签名的价值）。这里只需确认它没改那批任务本身。
      const tasks: Task[] = [];
      for (const t of repeat(3, () => done(STUDY, 100, 120))) {
        tasks.push(t);
      }
      tasks.push(idle(UNFINISHED, WORK, TaskPriority.MEDIUM));

      const statusBefore: number = tasks[0].status;
      const estBefore: number = tasks[0].estimatedMinutes;
      const endBefore: number = tasks[0].actualEndTime;

      buildReview(tasks);

      expect(tasks.length).assertEqual(4);
      expect(tasks[0].status).assertEqual(statusBefore);
      expect(tasks[0].estimatedMinutes).assertEqual(estBefore);
      expect(tasks[0].actualEndTime).assertEqual(endBefore);
    });
  });
}
