/**
 * 统计页的纯计算：把一批（已经按时间窗口取回的）任务折成三块报表 ——
 * 完成情况、估时表现、分类耗时占比。
 *
 * 这是 Dayer 的第三个核心差异化逻辑（前两个是 TimeUtil 的偏差计算、EstimateBias 的倍率估计）。
 * 前两个都是**事前/事中**的一面（建任务时给建议、计时后给结论），这里是**事后**的一面：
 * 「我这个人估时到底什么水平」。同样抽成纯函数由 entry/src/test/ 直接覆盖 ——
 * 一个算错了没人看得出来的统计量，比没有这个功能更糟。
 *
 * ⚠️ 本文件禁止 import 任何 @kit 模块，也禁止使用 $r() 资源引用。
 * 分类名、耗时文案一律由页面层在渲染时调 TaskConstants 拼 —— 那个文件用了 $r()，这里不能碰。
 *
 * ⚠️ 口径刻意全部复用已有定义，不新发明概念：
 * - 「完成率」的分子分母见 computeStats 里的三桶注释；
 * - 「估得准不准」直接用 calcDeviation 的 ACCURATE 判据，
 *   否则会出现详情页说「估得准」、统计页说「不准」这种自相矛盾；
 * - 「倍率」直接调 estimateBias，连「少于 3 条不给结论」都沿用它的 MIN_SAMPLES。
 *
 * ⚠️ 已知且**刻意不修**的缺口（完成率会偏高）：
 * 从未点过「开始」就被标为「未完成」的任务，actualEndTime 是 0
 * （TaskFlow 只在计过时的任务上写结束时间），于是「创建于窗口 ∪ 结束于窗口」两条分支
 * 它都落不进去，会被漏掉。要修就得有「状态变成未完成的时刻」，而库里没有这一列 ——
 * 那就得动 schema、升 DB_VERSION，代价远大于收益。
 * 该缺口只在「任务创建于窗口之前、废弃于窗口之内」时发生，所以【全部】窗口在定义上不受影响
 * （没有东西早于时间戳 0）。页面上始终显示「已结算 N 条」，让分母可见，不藏这个口径。
 */

import { ANY_CATEGORY, BiasResult, BiasSample, estimateBias } from './EstimateBias';
import {
  calcDeviation,
  DayRange,
  DeviationKind,
  DeviationResult,
  startOfMonth,
  startOfToday,
  startOfTomorrow,
  startOfWeek
} from './TimeUtil';
import { Task, TaskStatus } from '../model/Task';

/** 时间窗口：当天 */
export const WINDOW_TODAY: number = 0;
/** 时间窗口：本周（周一零点起） */
export const WINDOW_WEEK: number = 1;
/** 时间窗口：本月（1 号零点起） */
export const WINDOW_MONTH: number = 2;
/** 时间窗口：不限（左边界为时间戳 0） */
export const WINDOW_ALL: number = 3;

/** 一个分类的耗时统计。medianRatio 只在 biasReady 为 true 时可解读 */
export class CategoryStat {
  categoryId: number = 0;
  /** 该类实际耗时合计（分钟） */
  actualMinutes: number = 0;
  /** 占窗口内总实际耗时的比例，0..1。所有分类的 share 之和为 1 */
  share: number = 0;
  biasReady: boolean = false;
  medianRatio: number = 1;
  /**
   * 真正参与倍率统计的样本条数（estimateBias 剔除非法值之后的数）。
   *
   * ⚠️ 它和 actualMinutes 的口径**不同**：只要有可比时长就会建这个桶、就计入 actualMinutes，
   * 而 estimateBias 会再剔掉 estimatedMinutes ≤ 0 的样本（用户把预估填成 0）。
   * 所以存在「这个分类在界面上有一条实实在在的耗时条、但 sampleCount 是 0」的分类。
   * 复盘建议里「还差几条就有结论」必须要求 sampleCount ≥ 1，否则会显示「这一类只记了 0 / 3 条」。
   */
  sampleCount: number = 0;
}

/** 一个时间窗口内的全部统计结果 */
export class StatsResult {
  /** 完成率的分母：窗口内**已结算**的任务数（已完成 + 未完成） */
  settledCount: number = 0;
  /** 已完成且未逾期 */
  doneOnTimeCount: number = 0;
  /** 已完成但实际结束晚于截止时间（由 Task.isCompletedLate 推导，不是一种状态） */
  doneLateCount: number = 0;
  /** 明确标为未完成 */
  unfinishedCount: number = 0;

  /** 估时指标的分母：有计时、且实测不少于 1 分钟的任务数 */
  timedCount: number = 0;
  accurateCount: number = 0;
  overCount: number = 0;
  underCount: number = 0;
  /** 窗口内被计入统计的实际耗时合计（分钟），等于各分类 actualMinutes 之和 */
  totalActualMinutes: number = 0;

  overallBias: BiasResult = BiasResult.notReady(0);
  /** 按实际耗时降序；只含真的产生过耗时的分类，不铺一排空条 */
  categories: CategoryStat[] = [];
}

/**
 * 窗口的半开区间 [from, to)。
 *
 * 右边界一律取「明天零点」而不是「窗口结束那天的 24:00」：
 * 与首页 dayRangeOf 用的是同一个边界函数，两个页面才不会在午夜差出一毫秒。
 * 【全部】的左边界取 0，即「不设下限」—— 沿用工程里「时间戳 0 表示未设置」的哨兵约定。
 */
export function statsWindow(now: number, window: number): DayRange {
  const end: number = startOfTomorrow(now);
  if (window === WINDOW_ALL) {
    return new DayRange(0, end);
  }
  if (window === WINDOW_WEEK) {
    return new DayRange(startOfWeek(now), end);
  }
  if (window === WINDOW_MONTH) {
    return new DayRange(startOfMonth(now), end);
  }
  return new DayRange(startOfToday(now), end);
}

/**
 * 这条任务的实测值能不能拿来做估计 —— 只有三个有结论的 kind 算数。
 *
 * NO_TIMING_DATA（从没点过开始）没有实测值可谈；
 * TIME_ANOMALY（结束早于开始）是系统时间被改，那个差值不是耗时；
 * TOO_SHORT（实测不足 1 分钟）的理由见 TimeUtil 里的长注释 —— 放它进来会把统计
 * 污染成「我一直在高估」（一个 23 秒的误触任务能造出一句「节省 1 小时」）。
 */
function isComparable(kind: DeviationKind): boolean {
  return kind === DeviationKind.ACCURATE
    || kind === DeviationKind.OVER
    || kind === DeviationKind.UNDER;
}

/** 取出该分类的统计槽位，没有就新建一个。分类最多五个，线性查找比建 Map 更省事 */
function bucketFor(buckets: CategoryStat[], categoryId: number): CategoryStat {
  for (const bucket of buckets) {
    if (bucket.categoryId === categoryId) {
      return bucket;
    }
  }
  const created: CategoryStat = new CategoryStat();
  created.categoryId = categoryId;
  buckets.push(created);
  return created;
}

/**
 * 完成率的分子。**延期完成也算完成** —— 它只是晚了，不是没做完。
 *
 * 三桶分开计数是需求文档要求的展示形式（已完成 / 延期 / 未完成），
 * 但比率只分「做完没做完」两种，不把延期当成失败 —— 那会让一个习惯踩点交活的人
 * 看到一份和事实不符的完成率。
 *
 * 返回的是分子而不是比率本身：页面把它和 settledCount 并排显示成「15 / 20」。
 * 分数比百分数信息量大 —— 分母必须看得见，用户才知道这个比例建立在 2 条还是 200 条记录上。
 */
export function completedCount(stats: StatsResult): number {
  return stats.doneOnTimeCount + stats.doneLateCount;
}

/**
 * 折出统计结果。
 *
 * @param tasks 已经按窗口取回的任务（区间由 SQL 负责），因此这个函数不需要 now
 */
export function computeStats(tasks: Task[]): StatsResult {
  const result: StatsResult = new StatsResult();
  const samples: BiasSample[] = [];
  const buckets: CategoryStat[] = [];

  for (const task of tasks) {
    // ---- 完成情况：三桶 ----
    // 「待开始」「进行中」不进分母：一个今天刚建、还没轮到做的任务，
    // 既不算完成也不算失败，把它计成失败会让【今日】的完成率永远接近 0。
    if (task.status === TaskStatus.UNFINISHED) {
      result.unfinishedCount = result.unfinishedCount + 1;
      result.settledCount = result.settledCount + 1;
    } else if (task.isCompleted()) {
      if (task.isCompletedLate()) {
        result.doneLateCount = result.doneLateCount + 1;
      } else {
        result.doneOnTimeCount = result.doneOnTimeCount + 1;
      }
      result.settledCount = result.settledCount + 1;
    }

    // ---- 估时表现 ----
    const deviation: DeviationResult = calcDeviation(
      task.estimatedMinutes, task.actualStartTime, task.actualEndTime);
    if (!isComparable(deviation.kind)) {
      continue;
    }

    result.timedCount = result.timedCount + 1;
    if (deviation.kind === DeviationKind.ACCURATE) {
      result.accurateCount = result.accurateCount + 1;
    } else if (deviation.kind === DeviationKind.OVER) {
      result.overCount = result.overCount + 1;
    } else {
      result.underCount = result.underCount + 1;
    }

    result.totalActualMinutes = result.totalActualMinutes + deviation.actualMinutes;
    samples.push(new BiasSample(task.categoryId, task.estimatedMinutes, deviation.actualMinutes));
    const bucket: CategoryStat = bucketFor(buckets, task.categoryId);
    bucket.actualMinutes = bucket.actualMinutes + deviation.actualMinutes;
  }

  // 耗时降序；同耗时按分类 id 升序兜底，否则两个分类耗时一样时顺序会随任务顺序漂，
  // 同一份数据两次打开可能长得不一样。
  buckets.sort((a: CategoryStat, b: CategoryStat) => {
    if (b.actualMinutes !== a.actualMinutes) {
      return b.actualMinutes - a.actualMinutes;
    }
    return a.categoryId - b.categoryId;
  });

  for (const bucket of buckets) {
    bucket.share = result.totalActualMinutes > 0
      ? bucket.actualMinutes / result.totalActualMinutes
      : 0;
    // 按分类估倍率时直接复用 estimateBias 自己的分类过滤，不再维护一份分组样本表 ——
    // 两处过滤逻辑迟早会走岔，而走岔的表现是「整体倍率和分类倍率对不上」。
    const bias: BiasResult = estimateBias(samples, bucket.categoryId);
    bucket.biasReady = bias.ready;
    bucket.medianRatio = bias.medianRatio;
    bucket.sampleCount = bias.sampleCount;
  }

  result.categories = buckets;
  result.overallBias = estimateBias(samples, ANY_CATEGORY);
  return result;
}
