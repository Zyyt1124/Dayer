import { Task, TaskStatus } from '../model/Task';
import { MS_PER_MINUTE } from './TimeUtil';

/**
 * 任务状态流转的守卫逻辑。
 *
 * 抽成纯函数而不是写在页面里，有两个原因：
 * 1. 本地单测（entry/src/test/）不跑设备运行时，只有不依赖 @kit 的纯逻辑才测得动；
 * 2. 状态机是最容易出「重复点两下就错了」的地方，值得逐条断言。
 *
 * ⚠️ 与 TimeUtil 一样：本文件禁止 import 任何 @kit 模块。
 *
 * 所有 apply* 都返回「状态是否真的变了」：
 * 返回 false 表示这次操作是无效的重复操作，调用方据此决定要不要落库、要不要提示。
 * 时间戳一律由调用方传入 now，不在函数内部取 Date.now()，保证可测。
 */

/**
 * 开始任务。
 * 已经有 actualStartTime 时不覆盖 —— 否则「开始 → 进行中 → 再点开始」会把起点推后，
 * 实际耗时被悄悄缩短。
 */
export function applyStart(task: Task, now: number): boolean {
  if (task.actualStartTime > 0) {
    return false;
  }
  if (task.status === TaskStatus.COMPLETED) {
    return false;
  }
  task.actualStartTime = now;
  task.status = TaskStatus.IN_PROGRESS;
  return true;
}

/**
 * 完成任务。
 * 重复点完成返回 false，不会用第二次的时间覆盖第一次的结束时间。
 *
 * 没点过开始也可以完成（用户忘了点），此时**照样记录 actualEndTime** ——
 * 「完成」这个动作发生在哪一刻是客观事实，与有没有按过「开始」无关。理由两条：
 * 1. 补记用时需要一个锚点才能反推开始时间。若两个时间戳都是 0，补记就无从下手，
 *    而补记是估时校准唯一的样本来源；
 * 2. 修掉一个真实缺陷：「没点开始但拖过截止时间才完成」此前 actualEndTime 恒为 0，
 *    isCompletedLate() 因此永远返回 false，逾期任务被静默地判成按时。
 *
 * ⚠️ 这不影响偏差计算：calcDeviation 以 actualStartTime 为准，没有起点时仍然返回
 * NO_TIMING_DATA，详情页照旧显示「未记录计时」，不会凭空冒出一个 0 分钟的假耗时。
 */
export function applyComplete(task: Task, now: number): boolean {
  if (task.status === TaskStatus.COMPLETED) {
    return false;
  }
  task.actualEndTime = now;
  task.status = TaskStatus.COMPLETED;
  return true;
}

/**
 * 撤销完成。
 * 只清 actualEndTime，**保留 actualStartTime** —— 用户仍然处于「已经开始做这件事」
 * 的状态，把起点也清掉会让之前真正投入的时间凭空消失。
 * 未开始过的任务撤销完成则退回「待开始」。
 */
export function applyUndoComplete(task: Task): boolean {
  if (task.status !== TaskStatus.COMPLETED) {
    return false;
  }
  task.actualEndTime = 0;
  task.status = task.actualStartTime > 0 ? TaskStatus.IN_PROGRESS : TaskStatus.NOT_STARTED;
  return true;
}

/**
 * 标记为未完成（放弃/中断）。
 * 已经开始过就记下结束时间：这段时间确实花掉了，是校准预估准确度的有效样本。
 */
export function applyMarkUnfinished(task: Task, now: number): boolean {
  if (task.status === TaskStatus.UNFINISHED) {
    return false;
  }
  if (task.actualStartTime > 0) {
    task.actualEndTime = now;
  }
  task.status = TaskStatus.UNFINISHED;
  return true;
}

/** 补记用时的上限：一天。超过这个数几乎必然是误输入，而不是真的连做了 25 小时 */
export const MAX_ACTUAL_MINUTES: number = 24 * 60;

/** 任务是否已经结束（完成或标记未完成）。只有结束了的任务才有「实际用时」可言 */
export function isSettled(task: Task): boolean {
  return task.status === TaskStatus.COMPLETED || task.status === TaskStatus.UNFINISHED;
}

/**
 * 补记实际用时。
 *
 * 用户忘了点「开始」，但记得这件事大概花了多久 —— 这是估时校准唯一的兜底样本来源。
 * 完全没有它，「你通常低估多少」就必须等到用户养成按「开始」的习惯之后才算得出来。
 *
 * 锚点优先取 actualEndTime（完成时刻），没有则退回 createTime（创建时刻）。
 * ⚠️ 锚点只影响 isCompletedLate() 的逾期判断，**不影响耗时差值** ——
 * 差值恒等于用户填的分钟数，而差值才是估时教练唯一关心的量。
 * 本次 applyComplete 改动之前完成的老任务没有 actualEndTime，用创建时刻兜底：
 * 逾期判断可能偏松，但这条样本本身仍然有效，比丢掉它强。
 *
 * 刻意**允许覆盖已有的计时数据**：补记填错了要能改回来，否则用户只能靠
 * 「撤销完成 → 重新开始」去修一个数字，那反而会真的污染计时。界面上只在
 * 「未记录计时」时主动提示补记，但守卫本身不做这个区分。
 *
 * 刻意**不收 now 参数**（其余 apply* 都收）：这里的时间戳完全由锚点推导，
 * 传一个进来却不用，只会让人误以为它取的是当前时间。
 *
 * @returns 是否真的改动了。false 表示入参非法或任务还没结束
 */
export function applySetActualDuration(task: Task, minutes: number): boolean {
  if (!Number.isInteger(minutes) || minutes <= 0 || minutes > MAX_ACTUAL_MINUTES) {
    return false;
  }
  if (!isSettled(task)) {
    return false;
  }
  const anchor: number = task.actualEndTime > 0 ? task.actualEndTime : task.createTime;
  if (anchor <= 0) {
    return false;
  }
  task.actualStartTime = anchor - minutes * MS_PER_MINUTE;
  task.actualEndTime = anchor;
  return true;
}
