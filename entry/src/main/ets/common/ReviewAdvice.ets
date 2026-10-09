/**
 * 智能复盘建议：把统计量翻译成**可行动的句子**（需求文档 四.2）。
 *
 * TaskStats 把数据**摆了出来**，但没替用户**下结论**。这一层补上结论 ——
 * 「你这类任务实际通常花到预估的 1.5 倍，下次照着预留」。
 * 它是「规划-执行-复盘-优化」闭环的最后一环：前三环（录入预估、计时、偏差复盘）都已落地。
 *
 * ⚠️ 本文件禁止 import 任何 @kit 模块，也禁止使用 $r() 资源引用。
 * 这里只产出「建议码 + 数值参数」，文案由页面层调 TaskConstants 拼 —— 那个文件用了 $r()，
 * 这里不能碰。这样七条规则的**判据与排序**才能被 entry/src/test/ 直接钉住。
 *
 * ⚠️ 口径的三个刻意选择：
 *
 * 1. **依据是「全部历史」，与统计页的页签无关。** 建议是对**这个人**说的，
 *    不是对「今天」说的 —— 用今日窗口只会得到「今天只记了 1 条」这种没法行动的话。
 *    代价是它和统计页【今日】那些数字不同源，所以卡片上必须写明「基于全部 N 条」。
 *    附带的强保证：数据源区间直接复用 statsWindow(now, WINDOW_ALL)，
 *    与【全部】页签逐毫秒一致，不会走岔成两套「全部」的定义。
 *
 * 2. **不做时间窗**（不只看最近 90 天）。TaskDao 的头注释写着「近期样本比半年前更能代表
 *    现在的手速」，对「行动建议」来说旧样本的代表性确实更差。但 v1 不做，因为那要新引入
 *    「为什么是 90 天」这个阈值，且会破坏上面那条「与【全部】页签一致」的性质。
 *    要做就单独做，别在这里悄悄加一个窗。
 *
 * 3. **建议用的是 computeStats 的分类倍率，不是 TaskDao.queryCompletedDurations。**
 *    编辑页的教练卡走后者（只算已完成的任务），这里必须走前者 ——
 *    否则同一屏上「分类耗时卡说 1.4 倍」和「复盘卡说 1.5 倍」会并列出现。
 *    代价是一条「计时了 2 小时但被标未完成」的任务会进分类倍率；
 *    这是可接受的：isComparable 已经排除了无计时/异常/过短的，而用户真的花了那 2 小时。
 */

import { ANY_CATEGORY, MIN_SAMPLES } from './EstimateBias';
import { CategoryStat, completedCount, computeStats, StatsResult } from './TaskStats';
import { Task, TaskPriority, TaskStatus } from '../model/Task';

/**
 * 建议的种类。
 *
 * ⚠️ 枚举值**就是排序权重**（越小越先展示），不是随手编的序号 —— 顺序 = 严重度，
 * 不是下面这些规则在代码里的书写顺序。排序时直接按 code 升序，省掉一张 rank 表。
 *
 * 排序理由：
 * - COMPLETION_LOW 最前：交不出去的活比估不准的活严重。
 * - CATEGORY_OVER 第二：这是本 App 的核心差异化（估时校准），且它带来的是**实际损失**。
 * - LATE 第三：截止时间是硬约束，踩线是明确的失败信号。
 * - PRIORITY_LOW 第四：重要的事没做完，但它是「分配」问题不是「估时」问题。
 * - TIMING_COVERAGE 第五：这是**元问题**（数据不够），说得再多也不如一条具体建议有用，
 *   但必须说 —— 不说用户永远不知道为什么这里没建议。
 * - CATEGORY_NEAR 第六：进度提示，不是问题。
 * - CATEGORY_UNDER 最后：它是**好消息**（可以少留点余量），不该挤掉任何一条警告。
 */
export enum AdviceCode {
  COMPLETION_LOW = 0,
  CATEGORY_OVER = 1,
  LATE = 2,
  PRIORITY_LOW = 3,
  TIMING_COVERAGE = 4,
  CATEGORY_NEAR = 5,
  CATEGORY_UNDER = 6
}

/**
 * 一条建议。
 *
 * 字段按 code 才有意义 —— 这是本工程处理这类「一个载体、多种变体」的既有手法
 * （见 TimeUtil.DeviationResult 的头注释：kind 为 NO_TIMING_DATA 时 actualMinutes 不可解读，
 * 调用方必须先看 kind）。ArkTS 没有联合类型，判别字段 + 宽字段是这里最干净的写法。
 *
 * 各 code 的字段契约：
 *
 * | code            | categoryId     | tenths        | numerator / denominator        |
 * |-----------------|----------------|---------------|--------------------------------|
 * | CATEGORY_OVER   | 该分类         | 中位倍率      | 样本数 / 0（不用分数）          |
 * | CATEGORY_UNDER  | 该分类         | 中位倍率      | 样本数 / 0（不用分数）          |
 * | CATEGORY_NEAR   | 该分类         | 0（不用）     | 已记样本数 / MIN_SAMPLES        |
 * | TIMING_COVERAGE | ANY_CATEGORY   | 0（不用）     | 记了计时的条数 / 已结算条数     |
 * | COMPLETION_LOW  | ANY_CATEGORY   | 0（不用）     | 未完成条数 / 已结算条数         |
 * | LATE            | ANY_CATEGORY   | 0（不用）     | 延期完成条数 / 有截止时间的已完成条数 |
 * | PRIORITY_LOW    | ANY_CATEGORY   | 0（不用）     | 高优先级已完成 / 高优先级已结算 |
 *
 * **numerator / denominator 的统一不变量**：只要两者有用，就恒构成一个真分数
 * （分子 ≤ 分母），含义是「被点名的那部分 ÷ 依据总量」。
 */
export class Advice {
  code: AdviceCode;
  /** 仅分类类建议有意义；其余一律 ANY_CATEGORY */
  categoryId: number;
  /** 仅倍率类建议有意义（十分位整数，1.4 倍存 14）；其余一律 0 */
  tenths: number;
  numerator: number;
  denominator: number;

  constructor(code: AdviceCode, categoryId: number, tenths: number,
              numerator: number, denominator: number) {
    this.code = code;
    this.categoryId = categoryId;
    this.tenths = tenths;
    this.numerator = numerator;
    this.denominator = denominator;
  }

  /** 分类类建议（带分类名与倍率）的构造 */
  static category(code: AdviceCode, categoryId: number, tenths: number, samples: number): Advice {
    return new Advice(code, categoryId, tenths, samples, 0);
  }

  /** 计数类建议（分子/分母构成分数）的构造 */
  static fraction(code: AdviceCode, numerator: number, denominator: number): Advice {
    return new Advice(code, ANY_CATEGORY, 0, numerator, denominator);
  }
}

/** 复盘结果。advices 已排序、已截断，页面直接渲染即可 */
export class ReviewResult {
  advices: Advice[] = [];
  /**
   * 数据量够不够下结论。**只在 advices 为空时才有意义**（两者是 else 关系，不会同屏矛盾）：
   * advices 非空时它一定是 true。
   */
  hasEnoughData: boolean = false;
  /** 依据的已结算条数（全历史）。卡片副标题显示它 —— 分母必须看得见 */
  basisCount: number = 0;
  /** 依据的可比计时条数（全历史） */
  timedCount: number = 0;
}

/**
 * 比率类建议的最小证据量。
 *
 * ⚠️ 刻意**比 MIN_SAMPLES(=3) 更严**，别「统一」成 3：
 * 倍率是一个**描述**（「你这类事大概要花 1.4 倍」），3 条就够描述；
 * 而建议是一条**行动指令**（「下次按这个数预留」），要用户改自己的行为，
 * 门槛就必须更高。描述错了只是不好看，指令错了是要误事的。
 */
const MIN_SETTLED: number = 5;

/**
 * 判定「普遍超时 / 普遍提前」的倍率线，单位是**十分位整数**（12 = 1.2 倍）。
 *
 * ⚠️ 两个「必须」：
 *
 * 1. 必须严格大于 calcDeviation 的「估得准」带（|diff| ≤ max(5, est×10%)，即倍率 ≤ 1.1）。
 *    否则同一屏上会出现「上面说大多数估得准、下面说这一类普遍超时」这种自相矛盾。
 *    1.2 留了 0.1 的余量，改动它时要连着 TOLERANCE_RATIO 一起想。
 *
 * 2. 必须与**分类卡上显示的那个数**判同一个量，所以这里用 Math.round(倍率×10) 的十分位，
 *    而不是原始的 medianRatio 浮点值。
 *    实测踩到过：工作类的真实中位倍率是 0.8333，卡上显示「0.8 倍」，而 0.8333 <= 0.8 为假
 *    → 不发建议。于是两个都显示「0.8 倍」的用户，一个收到「工作类通常能提前做完」、
 *    另一个收不到，屏上没有任何东西能解释这个差别 —— 0.75 和 0.83 会四舍五入成同一个
 *    「0.8 倍」，却分属线的两侧。
 *    改成比十分位后，规则变成一句用户能自己核对的话：卡上那个数碰到线，就出建议。
 */
const DRIFT_OVER_TENTHS: number = 12;
const DRIFT_UNDER_TENTHS: number = 8;

/** 完成率低于此值才提示。用整数交叉相乘判断，不写浮点比较 */
const COMPLETION_FLOOR_TENTHS: number = 7;

/** 延期完成的占比达到此值才提示 */
const LATE_CEILING_TENTHS: number = 3;

/**
 * 延期类建议的最小基数：**有截止时间的已完成任务**条数。
 * 没有这个下限，1 条完成、1 条延期就会触发「100% 都在踩线」。
 */
const MIN_LATE_BASE: number = 3;

/** 高优先级规则的绝对水位与相对落差；两侧都要求的最小条数 */
const PRIORITY_FLOOR_TENTHS: number = 7;
const PRIORITY_MARGIN_TENTHS: number = 2;
/**
 * 高优先级规则两侧各自的最小条数。
 * 3 条时完成率只能取 0/0.33/0.67/1，一格之差就翻面，判据太脆。
 */
const MIN_PRIORITY_SIDE: number = 4;

/** 分类偏差类（超时 + 提前）最多几条 —— 防止同一维度吃满整张卡 */
const MAX_CATEGORY_ADVICE: number = 2;
/** 卡片最多显示几条建议 */
export const MAX_ADVICE: number = 3;

/** 收集分类偏差候选时用的小载体：倍数偏差幅度 + 建议本身 */
class DriftCandidate {
  advice: Advice;
  /** 与 1.0 的距离（十分位），用于取最严重的几条 */
  distance: number;

  constructor(advice: Advice, distance: number) {
    this.advice = advice;
    this.distance = distance;
  }
}

/** 与 1.0 的距离（十分位）。1.5 → 5，0.8 → 2 */
function driftDistance(tenths: number): number {
  const diff: number = tenths - 10;
  return diff < 0 ? -diff : diff;
}

/** 收集分类偏差候选：高估的排前面，同幅度按分类 id 升序兜底 */
function collectDrift(categories: CategoryStat[]): Advice[] {
  const candidates: DriftCandidate[] = [];
  for (const category of categories) {
    if (!category.biasReady) {
      continue;
    }
    const tenths: number = Math.round(category.medianRatio * 10);
    if (tenths >= DRIFT_OVER_TENTHS) {
      candidates.push(new DriftCandidate(
        Advice.category(AdviceCode.CATEGORY_OVER, category.categoryId, tenths, category.sampleCount),
        driftDistance(tenths)));
    } else if (tenths <= DRIFT_UNDER_TENTHS) {
      candidates.push(new DriftCandidate(
        Advice.category(AdviceCode.CATEGORY_UNDER, category.categoryId, tenths, category.sampleCount),
        driftDistance(tenths)));
    }
  }

  // 最严重的在前；同幅度按分类 id 升序，否则两个分类倍率一样时顺序会随任务顺序漂
  candidates.sort((a: DriftCandidate, b: DriftCandidate) => {
    if (b.distance !== a.distance) {
      return b.distance - a.distance;
    }
    return a.advice.categoryId - b.advice.categoryId;
  });

  const picked: Advice[] = [];
  for (const candidate of candidates) {
    if (picked.length >= MAX_CATEGORY_ADVICE) {
      break;
    }
    picked.push(candidate.advice);
  }
  return picked;
}

/**
 * 「差几条就有结论」：取样本最多（最接近 ready）的那个分类，**最多一条**
 * —— 两条「还差几条」并列排在一起只是噪声，说一条最有进展的就够了。
 *
 * ⚠️ 必须要求 sampleCount ≥ 1：computeStats 按「有可比时长」建分类桶，
 * 而 estimateBias 会再剔掉 estimatedMinutes ≤ 0 的样本 —— 于是存在
 * 「分类卡上有一条实实在在的耗时条、但 sampleCount 是 0」的分类（预估被填成 0）。
 * 不排掉它会显示「这一类只记了 0 / 3 条」，而用户明明看得到那条耗时。
 *
 * 用 bestSamples = 0 当哨兵而不是 `CategoryStat | undefined`：
 * 本工程的实体类一律非可选、不用 undefined 表达「没有」（见 Task.ets 头注释），
 * 这里沿用同一个写法。
 */
function collectNear(categories: CategoryStat[]): Advice[] {
  let bestId: number = ANY_CATEGORY;
  let bestSamples: number = 0;
  for (const category of categories) {
    if (category.biasReady || category.sampleCount < 1) {
      continue;
    }
    // 样本最多的那个最接近有结论；并列按分类 id 升序，保证顺序不随任务顺序漂
    if (category.sampleCount > bestSamples
      || (category.sampleCount === bestSamples && bestId !== ANY_CATEGORY
        && category.categoryId < bestId)) {
      bestId = category.categoryId;
      bestSamples = category.sampleCount;
    }
  }
  if (bestId === ANY_CATEGORY) {
    return [];
  }
  const picked: Advice[] = [];
  // ⚠️ 这里必须走完整构造、把 bestId 带出去，**不能**用 Advice.fraction ——
  // 那个工厂会把 categoryId 置成 ANY_CATEGORY，而这条建议的 chip 要显示分类名，
  // categoryText(ANY_CATEGORY) 的兜底分支返回的是「工作」，
  // 一条「学习类还差 1 条」会顶着一个「工作」标签。
  picked.push(new Advice(AdviceCode.CATEGORY_NEAR, bestId, 0, bestSamples, MIN_SAMPLES));
  return picked;
}

/** 计数类建议的统计量：这些数 StatsResult 里没有，得从任务上现算 */
class TaskTally {
  /** 已完成且有截止时间的条数 —— LATE 的分母 */
  lateBase: number = 0;
  doneLate: number = 0;
  highSettled: number = 0;
  highCompleted: number = 0;
  /**
   * **非**高优先级（中 + 低）的条数。叫 other 不叫 low：这里的「低」指的是
   * 「不在高优先级那一档」，与 TaskPriority.LOW 不是一回事，用 low 会读错。
   * 两侧的最小条数要各自满足，所以两侧都得单独数。
   */
  otherSettled: number = 0;
  otherCompleted: number = 0;
}

function tally(tasks: Task[]): TaskTally {
  const result: TaskTally = new TaskTally();
  for (const task of tasks) {
    const high: boolean = task.priority === TaskPriority.HIGH;
    const settled: boolean = task.status === TaskStatus.UNFINISHED || task.isCompleted();
    if (settled) {
      if (high) {
        result.highSettled = result.highSettled + 1;
      } else {
        result.otherSettled = result.otherSettled + 1;
      }
    }
    if (task.isCompleted()) {
      if (high) {
        result.highCompleted = result.highCompleted + 1;
      } else {
        result.otherCompleted = result.otherCompleted + 1;
      }
      // ⚠️ LATE 的分母只能是「已完成且有截止时间」的条数。
      // 不能用 settledCount（会被「未完成」稀释），也不能用 completedCount ——
      // Task.isCompletedLate() 要求 deadline > 0，从不设截止时间的人算出来恒为 0，
      // 拿一个恒为 0 的分子配一个真实的分母，只会得出一句「你从不延期」的假话。
      if (task.deadline > 0) {
        result.lateBase = result.lateBase + 1;
        if (task.isCompletedLate()) {
          result.doneLate = result.doneLate + 1;
        }
      }
    }
  }
  return result;
}

/**
 * 造出这个用户当前最该看到的几条建议。
 *
 * **刻意只收 tasks 一个参数**，内部自己调 computeStats：若签名写成 (stats, tasks)，
 * 调用点太容易传成「当前窗口的 stats + 全历史的 tasks」，算出来的建议和它依据的分母
 * 对不上，而且**不会报错**。单参数让这个错误根本写不出来。代价是【全部】页签下
 * computeStats 跑两遍 —— 个人任务量下可忽略。
 */
export function buildReview(tasks: Task[]): ReviewResult {
  const result: ReviewResult = new ReviewResult();
  const stats: StatsResult = computeStats(tasks);
  const tallyResult: TaskTally = tally(tasks);

  result.basisCount = stats.settledCount;
  result.timedCount = stats.timedCount;
  // 「数据够不够下结论」= 两条准入线之一成立：结算量够，或计时样本够。
  // 全部由 stats 派生，不自己另立一套门槛。
  result.hasEnoughData = stats.settledCount >= MIN_SETTLED || stats.timedCount >= MIN_SAMPLES;

  const candidates: Advice[] = [];
  const completed: number = completedCount(stats);

  // ---- 估时：分类普遍超时 / 提前 ----
  for (const advice of collectDrift(stats.categories)) {
    candidates.push(advice);
  }

  // ---- 完成度：完成率偏低 ----
  // 一律**先判分母门槛、再算比率**，不把「不触发」押在 NaN 的比较语义上
  if (stats.settledCount >= MIN_SETTLED
    && (completed * 10) < (stats.settledCount * COMPLETION_FLOOR_TENTHS)) {
    candidates.push(Advice.fraction(
      AdviceCode.COMPLETION_LOW, stats.unfinishedCount, stats.settledCount));
  }

  // ---- 完成度：延期完成占比偏高 ----
  if (tallyResult.lateBase >= MIN_LATE_BASE
    && (tallyResult.doneLate * 10) >= (tallyResult.lateBase * LATE_CEILING_TENTHS)) {
    candidates.push(Advice.fraction(
      AdviceCode.LATE, tallyResult.doneLate, tallyResult.lateBase));
  }

  // ---- 优先级：高优先级完成率既低于绝对水位、又低于其他任务 ----
  //
  // 与「非高优先级」比，而不是与整体比：整体**包含高优先级自身**，
  // 子集和含自身的超集比，差异会被自己稀释掉，越重要的事越看不出来。
  if (tallyResult.highSettled >= MIN_PRIORITY_SIDE
    && tallyResult.otherSettled >= MIN_PRIORITY_SIDE
    && (tallyResult.highCompleted * 10) < (tallyResult.highSettled * PRIORITY_FLOOR_TENTHS)
    && (tallyResult.highCompleted * tallyResult.otherSettled * 10)
      < (tallyResult.otherCompleted * tallyResult.highSettled * 10
        - tallyResult.highSettled * tallyResult.otherSettled * PRIORITY_MARGIN_TENTHS)) {
    candidates.push(Advice.fraction(
      AdviceCode.PRIORITY_LOW, tallyResult.highCompleted, tallyResult.highSettled));
  }

  // ---- 元问题：计时覆盖率太低 ----
  if (stats.settledCount >= MIN_SETTLED && (stats.timedCount * 2) < stats.settledCount) {
    candidates.push(Advice.fraction(
      AdviceCode.TIMING_COVERAGE, stats.timedCount, stats.settledCount));
  }

  // ---- 进度提示：某个分类快够样本了 ----
  // 要求全局也有点结算量，否则新用户装好第一天就会看到「某类只记了 1 条」，
  // 那不是建议，那是在陈述他刚装了这个 App。
  if (stats.settledCount >= MIN_SAMPLES) {
    for (const advice of collectNear(stats.categories)) {
      candidates.push(advice);
    }
  }

  // 统一排序：code 升序 → 偏差幅度降序 → 分类 id 升序。
  // 三个键合起来是**全序**，所以既不依赖 Array.sort 的稳定性，
  // 也保证「最严重的在前」而不是「碰巧排在前」。
  candidates.sort((a: Advice, b: Advice) => {
    if (a.code !== b.code) {
      return a.code - b.code;
    }
    const da: number = driftDistance(a.tenths);
    const db: number = driftDistance(b.tenths);
    if (db !== da) {
      return db - da;
    }
    return a.categoryId - b.categoryId;
  });

  const picked: Advice[] = [];
  for (const advice of candidates) {
    if (picked.length >= MAX_ADVICE) {
      break;
    }
    picked.push(advice);
  }
  result.advices = picked;
  return result;
}
