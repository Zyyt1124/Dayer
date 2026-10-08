import { describe, it, expect } from '@ohos/hypium';
import { Task, TaskStatus } from '../main/ets/model/Task';
import {
  applyStart,
  applyComplete,
  applyUndoComplete,
  applyMarkUnfinished,
  applySetActualDuration,
  isSettled,
  MAX_ACTUAL_MINUTES
} from '../main/ets/common/TaskFlow';
import { calcDeviation, DeviationKind, DeviationResult, endOfDay } from '../main/ets/common/TimeUtil';

const MINUTE: number = 60000;
const T0: number = 1700000000000;

export default function taskFlowTest() {
  describe('TaskFlow', () => {

    it('applyStart_sets_status_and_timestamp', 0, () => {
      const task: Task = new Task();
      const changed: boolean = applyStart(task, T0);
      expect(changed).assertTrue();
      expect(task.status).assertEqual(TaskStatus.IN_PROGRESS);
      expect(task.actualStartTime).assertEqual(T0);
    });

    it('applyStart_is_idempotent_and_keeps_first_timestamp', 0, () => {
      const task: Task = new Task();
      applyStart(task, T0);

      // 再点一次「开始」：不覆盖起点，否则实际耗时会被悄悄缩短
      const changed: boolean = applyStart(task, T0 + 30 * MINUTE);
      expect(changed).assertFalse();
      expect(task.actualStartTime).assertEqual(T0);
      expect(task.status).assertEqual(TaskStatus.IN_PROGRESS);
    });

    it('applyStart_on_completed_task_is_rejected', 0, () => {
      const task: Task = new Task();
      applyStart(task, T0);
      applyComplete(task, T0 + 10 * MINUTE);

      const changed: boolean = applyStart(task, T0 + 20 * MINUTE);
      expect(changed).assertFalse();
      expect(task.status).assertEqual(TaskStatus.COMPLETED);
      expect(task.actualStartTime).assertEqual(T0);
    });

    it('applyStart_on_completed_without_timing_is_rejected', 0, () => {
      // 唯一能走到「已完成」守卫的路径：用户忘了点开始就直接完成
      // （此时 actualStartTime 仍是 0，第一个守卫放行，由状态守卫拦下）。
      // 其余情况的已完成任务会被 actualStartTime > 0 那条守卫先截住。
      const task: Task = new Task();
      applyComplete(task, T0);
      expect(task.status).assertEqual(TaskStatus.COMPLETED);
      expect(task.actualStartTime).assertEqual(0);

      const changed: boolean = applyStart(task, T0 + 10 * MINUTE);
      expect(changed).assertFalse();
      expect(task.status).assertEqual(TaskStatus.COMPLETED);
      expect(task.actualStartTime).assertEqual(0);
    });

    it('applyComplete_sets_end_time_when_started', 0, () => {
      const task: Task = new Task();
      applyStart(task, T0);

      const changed: boolean = applyComplete(task, T0 + 45 * MINUTE);
      expect(changed).assertTrue();
      expect(task.status).assertEqual(TaskStatus.COMPLETED);
      expect(task.actualEndTime).assertEqual(T0 + 45 * MINUTE);
    });

    it('applyComplete_without_start_still_records_end_time', 0, () => {
      // 用户忘了点开始，直接完成。「完成」发生在哪一刻是客观事实，与按没按过开始无关 ——
      // 记下它，补记才有锚点可反推开始时间。
      const task: Task = new Task();
      const changed: boolean = applyComplete(task, T0);

      expect(changed).assertTrue();
      expect(task.status).assertEqual(TaskStatus.COMPLETED);
      expect(task.actualStartTime).assertEqual(0);
      expect(task.actualEndTime).assertEqual(T0);
      // 起点仍然是空的，所以不算「有计时数据」
      expect(task.hasTiming()).assertFalse();
    });

    it('applyComplete_without_start_does_not_fabricate_a_duration', 0, () => {
      // 这是上一条改动的红线：只有终点、没有起点，绝不能因此冒出一个耗时。
      // 详情页必须照旧显示「未记录计时」，而不是 0 分钟或一个由 createTime 凑出来的数。
      const task: Task = new Task();
      task.createTime = T0 - 3 * 60 * MINUTE;
      applyComplete(task, T0);

      const d: DeviationResult = calcDeviation(60, task.actualStartTime, task.actualEndTime);
      expect(d.kind).assertEqual(DeviationKind.NO_TIMING_DATA);
    });

    it('applyComplete_without_start_now_detects_late_completion', 0, () => {
      // 这条是那个改动的收益：此前 actualEndTime 恒为 0，逾期判断永远是 false，
      // 「没点开始但拖过截止时间才完成」被静默地判成按时。
      const task: Task = new Task();
      task.deadline = T0;
      applyComplete(task, T0 + 30 * MINUTE);
      expect(task.isCompletedLate()).assertTrue();
    });

    it('applyComplete_twice_does_not_overwrite_end_time', 0, () => {
      const task: Task = new Task();
      applyStart(task, T0);
      applyComplete(task, T0 + 30 * MINUTE);

      const changed: boolean = applyComplete(task, T0 + 90 * MINUTE);
      expect(changed).assertFalse();
      expect(task.actualEndTime).assertEqual(T0 + 30 * MINUTE);
    });

    it('applyUndoComplete_keeps_start_time', 0, () => {
      const task: Task = new Task();
      applyStart(task, T0);
      applyComplete(task, T0 + 30 * MINUTE);

      const changed: boolean = applyUndoComplete(task);
      expect(changed).assertTrue();
      expect(task.actualEndTime).assertEqual(0);
      // 起点必须保留：用户仍处于「已经开始做」的状态
      expect(task.actualStartTime).assertEqual(T0);
      expect(task.status).assertEqual(TaskStatus.IN_PROGRESS);
    });

    it('applyUndoComplete_without_prior_start_returns_to_not_started', 0, () => {
      const task: Task = new Task();
      applyComplete(task, T0);

      const changed: boolean = applyUndoComplete(task);
      expect(changed).assertTrue();
      expect(task.status).assertEqual(TaskStatus.NOT_STARTED);
      expect(task.actualStartTime).assertEqual(0);
    });

    it('applyUndoComplete_on_unfinished_task_is_rejected', 0, () => {
      const task: Task = new Task();
      const changed: boolean = applyUndoComplete(task);
      expect(changed).assertFalse();
      expect(task.status).assertEqual(TaskStatus.NOT_STARTED);
    });

    it('applyMarkUnfinished_records_end_time_when_started', 0, () => {
      const task: Task = new Task();
      applyStart(task, T0);

      const changed: boolean = applyMarkUnfinished(task, T0 + 20 * MINUTE);
      expect(changed).assertTrue();
      expect(task.status).assertEqual(TaskStatus.UNFINISHED);
      // 已投入的 20 分钟确实花掉了，是校准预估准确度的有效样本
      expect(task.actualEndTime).assertEqual(T0 + 20 * MINUTE);
    });

    it('applyMarkUnfinished_is_idempotent', 0, () => {
      const task: Task = new Task();
      applyStart(task, T0);
      applyMarkUnfinished(task, T0 + 20 * MINUTE);

      const changed: boolean = applyMarkUnfinished(task, T0 + 60 * MINUTE);
      expect(changed).assertFalse();
      expect(task.actualEndTime).assertEqual(T0 + 20 * MINUTE);
    });

    // ---- 逾期推导：不落库，由 actualEndTime > deadline 实时算出 ----

    it('isCompletedLate_is_derived_from_deadline', 0, () => {
      const onTime: Task = new Task();
      onTime.deadline = T0 + 60 * MINUTE;
      applyStart(onTime, T0);
      applyComplete(onTime, T0 + 30 * MINUTE);
      expect(onTime.isCompletedLate()).assertFalse();

      const late: Task = new Task();
      late.deadline = T0 + 60 * MINUTE;
      applyStart(late, T0);
      applyComplete(late, T0 + 90 * MINUTE);
      expect(late.isCompletedLate()).assertTrue();
    });

    it('isCompletedLate_treats_deadline_day_as_not_late', 0, () => {
      // 编辑页把截止时间存成当天 23:59:59.999，所以「当天做完」不该被判逾期。
      const deadline: number = endOfDay(new Date(2026, 5, 10, 0, 0, 0).getTime());

      const sameDay: Task = new Task();
      sameDay.deadline = deadline;
      applyStart(sameDay, deadline - 30 * MINUTE);
      applyComplete(sameDay, deadline);
      expect(sameDay.isCompletedLate()).assertFalse();

      const nextMs: Task = new Task();
      nextMs.deadline = deadline;
      applyStart(nextMs, deadline - 30 * MINUTE);
      applyComplete(nextMs, deadline + 1);
      expect(nextMs.isCompletedLate()).assertTrue();
    });

    it('isCompletedLate_is_false_without_deadline_or_before_completion', 0, () => {
      const noDeadline: Task = new Task();
      applyStart(noDeadline, T0);
      applyComplete(noDeadline, T0 + 90 * MINUTE);
      expect(noDeadline.isCompletedLate()).assertFalse();

      const inProgress: Task = new Task();
      inProgress.deadline = T0;
      applyStart(inProgress, T0 + 30 * MINUTE);
      expect(inProgress.isCompletedLate()).assertFalse();
    });

    // ---- 补记实际用时：估时校准唯一的兜底样本来源 ----

    it('isSettled_only_covers_finished_tasks', 0, () => {
      const task: Task = new Task();
      expect(isSettled(task)).assertFalse();

      applyStart(task, T0);
      expect(isSettled(task)).assertFalse();

      applyComplete(task, T0 + 30 * MINUTE);
      expect(isSettled(task)).assertTrue();

      const abandoned: Task = new Task();
      applyMarkUnfinished(abandoned, T0);
      expect(isSettled(abandoned)).assertTrue();
    });

    it('applySetActualDuration_derives_start_from_completion', 0, () => {
      // 用户忘了点开始，事后填「大概花了 30 分钟」。
      // 锚点是完成时刻，起点由它反推，两者之差恰好是用户填的数。
      const task: Task = new Task();
      task.createTime = T0 - 120 * MINUTE;
      applyComplete(task, T0);

      const changed: boolean = applySetActualDuration(task, 30);
      expect(changed).assertTrue();
      expect(task.actualEndTime).assertEqual(T0);
      expect(task.actualStartTime).assertEqual(T0 - 30 * MINUTE);
      expect(task.hasTiming()).assertTrue();
    });

    it('applySetActualDuration_produces_exactly_the_entered_minutes', 0, () => {
      // 这是补记唯一必须成立的量：差值恒等于用户填的分钟数。
      // 锚点漂不漂只影响逾期判断，不影响它。
      const task: Task = new Task();
      task.createTime = T0 - 500 * MINUTE;
      applyComplete(task, T0);
      applySetActualDuration(task, 25);

      const d: DeviationResult = calcDeviation(60, task.actualStartTime, task.actualEndTime);
      expect(d.kind).assertEqual(DeviationKind.UNDER);
      expect(d.actualMinutes).assertEqual(25);
      expect(d.diffMinutes).assertEqual(-35);
    });

    it('applySetActualDuration_falls_back_to_create_time_for_old_rows', 0, () => {
      // 本次 applyComplete 改动之前完成的老任务没有 actualEndTime，用创建时刻兜底。
      // 逾期判断会偏松，但样本本身必须仍然是有效的，不能因为缺锚点就丢掉这条数据。
      const task: Task = new Task();
      task.createTime = T0;
      task.status = TaskStatus.COMPLETED;

      const changed: boolean = applySetActualDuration(task, 20);
      expect(changed).assertTrue();
      expect(task.actualEndTime).assertEqual(T0);
      expect(task.actualStartTime).assertEqual(T0 - 20 * MINUTE);
    });

    it('applySetActualDuration_rejects_unfinished_tasks', 0, () => {
      // 还在进行中的任务，实际用时是「到现在为止」，由实时的时间戳算，
      // 不该让用户手填一个立刻就会过期的值
      const task: Task = new Task();
      task.createTime = T0;
      applyStart(task, T0);

      expect(applySetActualDuration(task, 30)).assertFalse();
      expect(task.actualStartTime).assertEqual(T0);
    });

    it('applySetActualDuration_rejects_invalid_minutes', 0, () => {
      const task: Task = new Task();
      task.createTime = T0;
      applyComplete(task, T0);

      expect(applySetActualDuration(task, 0)).assertFalse();
      expect(applySetActualDuration(task, -30)).assertFalse();
      expect(applySetActualDuration(task, 90.5)).assertFalse();
      expect(applySetActualDuration(task, MAX_ACTUAL_MINUTES + 1)).assertFalse();
      // 上限本身是合法的
      expect(applySetActualDuration(task, MAX_ACTUAL_MINUTES)).assertTrue();
    });

    it('applySetActualDuration_rejects_tasks_without_any_anchor', 0, () => {
      // 理论上到不了（create_time 是 NOT NULL），但守卫不能依赖「理论上」
      const task: Task = new Task();
      task.status = TaskStatus.COMPLETED;
      task.createTime = 0;
      task.actualEndTime = 0;

      expect(applySetActualDuration(task, 30)).assertFalse();
    });

    it('applySetActualDuration_can_correct_a_previous_entry', 0, () => {
      // 补记填错了要能改回来，否则用户只能靠「撤销完成 → 重新开始」去修一个数字，
      // 那反而会真的污染计时数据
      const task: Task = new Task();
      task.createTime = T0 - 200 * MINUTE;
      applyComplete(task, T0);

      applySetActualDuration(task, 45);
      expect(task.actualStartTime).assertEqual(T0 - 45 * MINUTE);

      applySetActualDuration(task, 15);
      expect(task.actualEndTime).assertEqual(T0);
      expect(task.actualStartTime).assertEqual(T0 - 15 * MINUTE);
    });

    it('applySetActualDuration_marks_a_late_completion_as_late', 0, () => {
      const task: Task = new Task();
      task.createTime = T0 - 200 * MINUTE;
      task.deadline = T0 - 60 * MINUTE;
      applyComplete(task, T0);

      applySetActualDuration(task, 30);
      expect(task.isCompletedLate()).assertTrue();
    });
  });
}
