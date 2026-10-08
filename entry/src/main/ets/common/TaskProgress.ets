import { MS_PER_MINUTE } from './TimeUtil';
import { Task, TaskStatus } from '../model/Task';

/**
 * 「一个正在计时的任务，跑到预估时长的哪个位置了」的纯函数计算。
 *
 * 抽出来的理由和 TimeUtil / ReminderPlan 一样：这里的边界（预估为 0、时钟被拨回、
 * 正好 80%、正好 100%）全是算错也看不出来、在真机上又极难复现的地方，必须能逐条断言。
 *
 * ⚠️ 本文件禁止 import 任何 @kit 模块，也禁止使用 $r() 资源引用。
 *
 * 为什么停在 80% 而不是等到 100%：到点才说话，用户能做的只剩「事后记账」；
 * 80% 时还剩两成，够决定「收尾」还是「去改预估」，这才叫纠偏而不是通报。
 */

/**
 * 预警时点：预估时长的 80%。
 * **这里是唯一定义**，ReminderPlan 从本文件 import —— 两处各写一个 0.8，
 * 改了一处漏了另一处就会得到两套互相矛盾的时点。
 */
export const WARN_RATIO: number = 0.8;

/**
 * 前台刷新间隔。卡片上最小的显示单位是分钟，1 秒一跳纯属白耗电。
 * 30 秒的代价是分钟数最多迟 30 秒才跳，可以接受。
 */
export const LIVE_TICK_MS: number = 30000;

/** 进行中任务的进度阶段 */
export enum ProgressStage {
  /** 没点过开始，或预估 ≤ 0 —— 算不出进度，不该画进度条 */
  NO_BASELINE = 0,
  /** 还没到 80% */
  RUNNING = 1,
  /** 到了 80%、还没到 100% —— 纠偏时点一 */
  NEAR_LIMIT = 2,
  /** 已达到预估时长 —— 纠偏时点二 */
  OVER = 3
}

/**
 * 进度快照。四个字段都由同一批入参算出，所以整体返回而不是分开调四个函数 ——
 * 分开调会让调用方有可能拿到两次计算之间不一致的一组数。
 */
export class ProgressResult {
  stage: ProgressStage;
  /** 已用分钟，**向下取整**：「已用 12 分钟」不该因为 12 分 59 秒就跳成 13 */
  elapsedMinutes: number;
  /**
   * 距离预估时长的分钟数，**带符号**：
   * - `> 0`：还剩这么多（**向上取整**，还剩 30 秒显示「还剩 1 分钟」比「还剩 0 分钟」诚实）
   * - `= 0`：恰好等于预估时长的那一瞬（下一跳就会变成负数）
   * - `< 0`：已超出这么多
   * 无基准时恒为 0。
   */
  remainingMinutes: number;
  /** 进度百分比 0..100，上限夹到 100（超时了也不显示 130%），无基准时为 0 */
  percent: number;

  constructor(stage: ProgressStage, elapsedMinutes: number, remainingMinutes: number, percent: number) {
    this.stage = stage;
    this.elapsedMinutes = elapsedMinutes;
    this.remainingMinutes = remainingMinutes;
    this.percent = percent;
  }
}

/**
 * 算出某个进行中任务此刻的进度。
 *
 * @param estimatedMinutes 预计耗时（分钟）
 * @param actualStartTime  实际开始时间戳，0 表示没点过开始
 * @param now              当前时间戳，由调用方传入以保证可测
 */
export function calcProgress(estimatedMinutes: number,
                             actualStartTime: number,
                             now: number): ProgressResult {
  // 预估 ≤ 0 必须在这里拦掉，否则下面 elapsedMs / plannedMs 会得到 Infinity，
  // stage 永远停在 OVER —— 用户会收到一个怎么点都消不掉的假「已超时」提示。
  // 编辑页会强制预估 > 0，但老数据、导入数据都可能带上 0，守卫不能依赖「理论上」。
  if (actualStartTime <= 0 || estimatedMinutes <= 0) {
    return new ProgressResult(ProgressStage.NO_BASELINE, 0, 0, 0);
  }

  // Date.now() 是墙上时钟，用户把时间往回拨会让 now < actualStartTime。
  // 夹紧到 0，否则会算出负的已用时间，再喂给 percent 会得到负数。
  const elapsedMs: number = now > actualStartTime ? now - actualStartTime : 0;
  const elapsedMinutes: number = Math.floor(elapsedMs / MS_PER_MINUTE);
  const plannedMs: number = estimatedMinutes * MS_PER_MINUTE;
  const percent: number = Math.min(100, Math.floor(elapsedMs * 100 / plannedMs));

  // 边界含等号：正好 100% 就按「已到点」算
  if (elapsedMs >= plannedMs) {
    const overMinutes: number = Math.ceil((elapsedMs - plannedMs) / MS_PER_MINUTE);
    return new ProgressResult(ProgressStage.OVER, elapsedMinutes, -overMinutes, 100);
  }

  const remainingMinutes: number = Math.ceil((plannedMs - elapsedMs) / MS_PER_MINUTE);
  // 同理含等号：正好 80% 就进入预警
  const stage: ProgressStage =
    elapsedMs >= plannedMs * WARN_RATIO ? ProgressStage.NEAR_LIMIT : ProgressStage.RUNNING;
  return new ProgressResult(stage, elapsedMinutes, remainingMinutes, percent);
}

/**
 * 挑出首页卡片要展示的那一个：所有进行中任务里「已用 / 预计」比值最大的。
 *
 * 比值最大 = 最可能已经跑偏的那个，而不是「最近开始的」或「优先级最高的」——
 * 后者在用户已经超时 40 分钟时还去关心一个刚开的新任务，属于答非所问。
 *
 * 排序必须完全确定，否则同一屏两次渲染可能给出不同的卡片、单测也没法断言：
 * 比值相同时取 `actualStartTime` 更早的（先开始先操心）。
 */
export function mostUrgentRunning(tasks: Task[], now: number): Task | null {
  let best: Task | null = null;
  // 从 -2 起：算不出进度的任务排 -1，任何有基准的任务（percent ≥ 0）都排在它前面，
  // 于是「没有基准」只会在它是唯一一个进行中任务时才被选中。
  let bestRank: number = -2;

  for (const task of tasks) {
    if (task.status !== TaskStatus.IN_PROGRESS) {
      continue;
    }
    const progress: ProgressResult = calcProgress(task.estimatedMinutes, task.actualStartTime, now);
    const rank: number =
      progress.stage === ProgressStage.NO_BASELINE ? -1 : progress.percent;

    const wins: boolean = rank > bestRank
      || (rank === bestRank && best !== null && task.actualStartTime < best.actualStartTime);
    if (wins) {
      best = task;
      bestRank = rank;
    }
  }
  return best;
}
