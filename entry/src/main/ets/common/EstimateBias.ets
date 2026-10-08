/**
 * 统计「你这类任务通常要花预估的几倍」。
 *
 * 这是 Dayer 的第二个核心差异化逻辑（第一个是 TimeUtil 的偏差计算），同样抽成纯函数
 * 由 entry/src/test/ 直接覆盖 —— 一个算错了没人看得出来的统计量，比没有这个功能更糟。
 *
 * ⚠️ 本文件禁止 import 任何 @kit 模块，也禁止使用 $r() 资源引用。
 *
 * 为什么用「参考类别预测」而不是一个固定倍率：
 * 固定倍率（例如全站统一按预估 ×1.4 预留）对 15 分钟的小事和 3 小时的大活不可能同时成立，
 * 用户算两次就会发现数字对不上，之后「估时校准」就退化成一个假闭环。
 * 这里改成读用户自己同类任务的历史比值分布：中位数给出中心，四分位给出「坏尾巴」。
 */

/**
 * 少于这么多条记录就不给建议。
 * 宁可直说「记录还不够」，也不要用两条数据编出一个倍率 —— 那是编造，不是建议。
 */
export const MIN_SAMPLES: number = 3;

/** 不限分类时传给 estimateBias 的哨兵值 */
export const ANY_CATEGORY: number = -1;

/**
 * 单条样本倍率的上下限。
 * 中位数本身能扛住个别离群值，但样本只有 3 条时「个别离群值」就是中位数本身。
 * 典型来源是预估填错一位（把 60 分钟写成 6 分钟，倍率直接变成 10 倍）。
 */
const MIN_RATIO: number = 0.2;
const MAX_RATIO: number = 5;

/** 一条历史记录：某次任务填的预估、它实际花了多久、属于哪一类 */
export class BiasSample {
  categoryId: number;
  estimatedMinutes: number;
  actualMinutes: number;

  constructor(categoryId: number, estimatedMinutes: number, actualMinutes: number) {
    this.categoryId = categoryId;
    this.estimatedMinutes = estimatedMinutes;
    this.actualMinutes = actualMinutes;
  }
}

/** 统计结果。ready 为 false 时数值字段一律不可解读，调用方必须先看 ready */
export class BiasResult {
  ready: boolean;
  /** 真正参与统计的样本条数（已剔除非法值） */
  sampleCount: number;
  /** 中位倍率 = 实际 ÷ 预估。1.0 表示估得准，1.4 表示通常要超四成 */
  medianRatio: number;
  /** 四分位下界：状态好的时候落在哪 */
  ratioLow: number;
  /** 四分位上界：坏尾巴能到哪 */
  ratioHigh: number;

  constructor(ready: boolean, sampleCount: number,
              medianRatio: number, ratioLow: number, ratioHigh: number) {
    this.ready = ready;
    this.sampleCount = sampleCount;
    this.medianRatio = medianRatio;
    this.ratioLow = ratioLow;
    this.ratioHigh = ratioHigh;
  }

  /** 样本不足时的占位结果：倍率一律给 1.0（「就按你估的来」），调用方只能靠 ready 判断 */
  static notReady(sampleCount: number): BiasResult {
    return new BiasResult(false, sampleCount, 1, 1, 1);
  }
}

function clampRatio(ratio: number): number {
  if (ratio < MIN_RATIO) {
    return MIN_RATIO;
  }
  if (ratio > MAX_RATIO) {
    return MAX_RATIO;
  }
  return ratio;
}

/**
 * 线性插值分位数（等价于 Excel 的 PERCENTILE.INC）。
 * 样本量大时它就是常规分位数；样本量小时（3 条取中位数）正好落在正中间那一条上，
 * 不会像「取最近排名」那样在小样本下产生肉眼可见的偏差。
 */
function percentile(sorted: number[], p: number): number {
  if (sorted.length === 1) {
    return sorted[0];
  }
  const index: number = p * (sorted.length - 1);
  const lower: number = Math.floor(index);
  const upper: number = Math.ceil(index);
  if (lower === upper) {
    return sorted[lower];
  }
  return sorted[lower] * (upper - index) + sorted[upper] * (index - lower);
}

/**
 * 从历史样本估算偏差倍率。
 *
 * @param samples    历史样本，通常是 TaskDao.queryCompletedDurations() 的结果
 * @param categoryId 只统计这一分类；传 ANY_CATEGORY 表示不限分类
 */
export function estimateBias(samples: BiasSample[], categoryId: number): BiasResult {
  const ratios: number[] = [];
  for (const sample of samples) {
    if (categoryId !== ANY_CATEGORY && sample.categoryId !== categoryId) {
      continue;
    }
    // 预估或实际为 0 的样本算不出比值，直接跳过而不是当成 1.0 —— 那会稀释掉真实偏差
    if (sample.estimatedMinutes <= 0 || sample.actualMinutes <= 0) {
      continue;
    }
    ratios.push(clampRatio(sample.actualMinutes / sample.estimatedMinutes));
  }

  if (ratios.length < MIN_SAMPLES) {
    return BiasResult.notReady(ratios.length);
  }

  ratios.sort((a: number, b: number) => a - b);
  return new BiasResult(true, ratios.length,
    percentile(ratios, 0.5),
    percentile(ratios, 0.25),
    percentile(ratios, 0.75));
}

/**
 * 按中位倍率换算「这件事建议预留多久」。
 *
 * 取中位数而不是上界：给出一个一半情况下能兑现的数字，比给出一个几乎必然超出的数字有用 ——
 * 后者只会让用户放弃看这个建议。上界留给调用方按需展示（「最多可能到 …」）。
 * 样本不足时原样返回用户自己的预估，不做任何放大。
 */
export function suggestedMinutes(estimatedMinutes: number, bias: BiasResult): number {
  if (!bias.ready || estimatedMinutes <= 0) {
    return estimatedMinutes;
  }
  const suggested: number = Math.round(estimatedMinutes * bias.medianRatio);
  return suggested > 0 ? suggested : 1;
}
