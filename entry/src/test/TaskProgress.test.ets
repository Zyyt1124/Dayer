import { describe, it, expect } from '@ohos/hypium';
import {
  calcProgress,
  mostUrgentRunning,
  ProgressResult,
  ProgressStage
} from '../main/ets/common/TaskProgress';
import { Task, TaskStatus } from '../main/ets/model/Task';

const MINUTE: number = 60000;
/** 任取一个固定时刻，不依赖真实当前时间，测试才是可重复的 */
const T0: number = 1700000000000;

function running(id: number, estimatedMinutes: number, startedAt: number): Task {
  const task: Task = new Task();
  task.id = id;
  task.estimatedMinutes = estimatedMinutes;
  task.actualStartTime = startedAt;
  task.status = TaskStatus.IN_PROGRESS;
  return task;
}

/**
 * 只回 id，不回 Task。
 * 直接断言 mostUrgentRunning 的返回值会让每个用例都要处理 null 收窄，
 * 而「选中了谁」本来就是这一组断言真正关心的东西。
 */
function pickedId(tasks: Task[], now: number): number {
  const task: Task | null = mostUrgentRunning(tasks, now);
  return task === null ? -1 : task.id;
}

export default function taskProgressTest() {
  describe('TaskProgress', () => {

    // ---- 算不出进度的两种输入 ----

    it('calcProgress_not_started_is_no_baseline', 0, () => {
      const r: ProgressResult = calcProgress(60, 0, T0);
      expect(r.stage).assertEqual(ProgressStage.NO_BASELINE);
      expect(r.elapsedMinutes).assertEqual(0);
      expect(r.remainingMinutes).assertEqual(0);
      expect(r.percent).assertEqual(0);
    });

    it('calcProgress_zero_estimate_is_no_baseline', 0, () => {
      // 这条守的是一个会永久卡住的假提示：不拦掉的话 elapsedMs / plannedMs 得到 Infinity，
      // stage 恒为 OVER，用户会收到一个怎么点「知道了」都消不掉的「已超时」。
      const r: ProgressResult = calcProgress(0, T0, T0 + 30 * MINUTE);
      expect(r.stage).assertEqual(ProgressStage.NO_BASELINE);
      expect(r.percent).assertEqual(0);
    });

    it('calcProgress_negative_estimate_is_no_baseline', 0, () => {
      const r: ProgressResult = calcProgress(-30, T0, T0 + 30 * MINUTE);
      expect(r.stage).assertEqual(ProgressStage.NO_BASELINE);
    });

    // ---- 三个正常阶段 ----

    it('calcProgress_at_zero_elapsed_shows_full_remaining', 0, () => {
      const r: ProgressResult = calcProgress(15, T0, T0);
      expect(r.stage).assertEqual(ProgressStage.RUNNING);
      expect(r.elapsedMinutes).assertEqual(0);
      expect(r.remainingMinutes).assertEqual(15);
      expect(r.percent).assertEqual(0);
    });

    it('calcProgress_just_below_warn_ratio_is_running', 0, () => {
      // 预计 100 分钟，跑到 79 分钟 —— 还差一点到 80%，不该出声
      const r: ProgressResult = calcProgress(100, T0, T0 + 79 * MINUTE);
      expect(r.stage).assertEqual(ProgressStage.RUNNING);
      expect(r.percent).assertEqual(79);
    });

    it('calcProgress_exactly_at_warn_ratio_is_near_limit', 0, () => {
      // 边界含等号：正好 80% 就算进入预警
      const r: ProgressResult = calcProgress(100, T0, T0 + 80 * MINUTE);
      expect(r.stage).assertEqual(ProgressStage.NEAR_LIMIT);
      expect(r.remainingMinutes).assertEqual(20);
    });

    it('calcProgress_just_below_estimate_is_near_limit', 0, () => {
      const r: ProgressResult = calcProgress(100, T0, T0 + 99 * MINUTE);
      expect(r.stage).assertEqual(ProgressStage.NEAR_LIMIT);
      expect(r.percent).assertEqual(99);
    });

    it('calcProgress_exactly_at_estimate_is_over', 0, () => {
      const r: ProgressResult = calcProgress(10, T0, T0 + 10 * MINUTE);
      expect(r.stage).assertEqual(ProgressStage.OVER);
      expect(r.percent).assertEqual(100);
      // 恰好到点的那一瞬是 0，下一跳（30 秒后）才会变成 -1。
      // 用 === 而不是 assertEqual：-0 与 0 在 assertEqual 里是否相等取决于实现，
      // 而这里要断言的恰恰是「它等于 0」这件事本身。
      expect(r.remainingMinutes === 0).assertTrue();
    });

    it('calcProgress_past_estimate_reports_over_minutes', 0, () => {
      // 预计 10 分钟、已跑 25 分钟 → 超出 15 分钟
      const r: ProgressResult = calcProgress(10, T0, T0 + 25 * MINUTE);
      expect(r.stage).assertEqual(ProgressStage.OVER);
      expect(r.elapsedMinutes).assertEqual(25);
      expect(r.remainingMinutes).assertEqual(-15);
      // 超时了也不显示「130%」：条画满就够，具体超多少由数字说
      expect(r.percent).assertEqual(100);
    });

    // ---- 取整与夹紧 ----

    it('calcProgress_elapsed_rounds_down', 0, () => {
      // 12 分 59 秒仍是「已用 12 分钟」，不能跳成 13
      const r: ProgressResult = calcProgress(100, T0, T0 + 12 * MINUTE + 59000);
      expect(r.elapsedMinutes).assertEqual(12);
      expect(r.percent).assertEqual(12);
    });

    it('calcProgress_remaining_rounds_up_so_it_never_says_zero', 0, () => {
      // 预计 100 分钟、已跑 60 分 30 秒 → 还剩 39 分 30 秒，显示「还剩 40 分钟」。
      // 向下取整会得到 39，向上才是对人更有用的方向：
      // 还剩 30 秒时说「还剩 1 分钟」，比说「还剩 0 分钟」诚实 ——
      // 后者会让一个还在计时的任务看起来已经到点了。
      const r: ProgressResult = calcProgress(100, T0, T0 + 60 * MINUTE + 30000);
      expect(r.stage).assertEqual(ProgressStage.RUNNING);
      expect(r.elapsedMinutes).assertEqual(60);
      expect(r.remainingMinutes).assertEqual(40);
    });

    it('calcProgress_clock_rollback_clamps_to_zero', 0, () => {
      // 用户把系统时间往回拨：now 早于开始时间。夹紧到 0，
      // 不能让「已用」变成负数、也不能让 percent 变成负数
      const r: ProgressResult = calcProgress(60, T0, T0 - 5 * MINUTE);
      expect(r.stage).assertEqual(ProgressStage.RUNNING);
      expect(r.elapsedMinutes).assertEqual(0);
      expect(r.remainingMinutes).assertEqual(60);
      expect(r.percent).assertEqual(0);
    });

    // ---- 挑出该被展示的那一个 ----

    it('most_urgent_returns_nothing_when_no_task_runs', 0, () => {
      const done: Task = running(1, 60, T0 - 30 * MINUTE);
      done.status = TaskStatus.COMPLETED;
      const fresh: Task = running(2, 60, 0);
      fresh.status = TaskStatus.NOT_STARTED;
      fresh.actualStartTime = 0;

      expect(pickedId([done, fresh], T0)).assertEqual(-1);
      expect(pickedId([], T0)).assertEqual(-1);
    });

    it('most_urgent_picks_the_highest_ratio', 0, () => {
      // 第一次开的新任务不该比一个已经跑了 50% 的任务更值得注意，
      // 哪怕它的优先级更高、创建得更晚
      const slow: Task = running(1, 100, T0 - 10 * MINUTE);
      const urgent: Task = running(2, 10, T0 - 5 * MINUTE);
      expect(pickedId([slow, urgent], T0)).assertEqual(2);
    });

    it('most_urgent_picks_an_overdue_task_over_a_merely_started_one', 0, () => {
      const overdue: Task = running(1, 10, T0 - 40 * MINUTE);
      const justStarted: Task = running(2, 600, T0 - 1 * MINUTE);
      expect(pickedId([justStarted, overdue], T0)).assertEqual(1);
    });

    it('most_urgent_tie_break_prefers_the_earlier_start', 0, () => {
      // 同一比例（都是 20%）时必须给出确定的结果，否则同一屏两次渲染可能换卡片，
      // 单测也没法断言。先开始先操心。
      const earlier: Task = running(1, 100, T0 - 20 * MINUTE);
      const later: Task = running(2, 50, T0 - 10 * MINUTE);
      expect(pickedId([later, earlier], T0)).assertEqual(1);
    });

    it('most_urgent_ranks_a_task_without_baseline_last', 0, () => {
      // 预计为 0 的任务算不出比例，只能排在最后 —— 它不该抢走卡片的展示位
      const noBaseline: Task = running(1, 0, T0);
      const measurable: Task = running(2, 100, T0);
      expect(pickedId([noBaseline, measurable], T0)).assertEqual(2);
    });

    it('most_urgent_still_returns_the_baseline_less_task_when_it_is_the_only_one', 0, () => {
      // 只有它一个在跑时还是要给出来，否则用户在这个列表页上完全看不到它正在计时
      const noBaseline: Task = running(1, 0, T0);
      expect(pickedId([noBaseline], T0)).assertEqual(1);
    });
  });
}
