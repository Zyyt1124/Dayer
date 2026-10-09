import { describe, it, expect } from '@ohos/hypium';
import {
  ANY_CATEGORY,
  BiasResult,
  BiasSample,
  MIN_SAMPLES,
  estimateBias,
  ratioTenth,
  ratioWhole,
  suggestedMinutes
} from '../main/ets/common/EstimateBias';

const WORK: number = 0;
const STUDY: number = 1;

/** 浮点不能用 assertEqual 直接比，逐位相等在插值计算里本来就不该强求 */
function near(actual: number, expected: number): boolean {
  return Math.abs(actual - expected) < 1e-9;
}

/** 造一批「预估都是 base，实际分别是 actuals」的同类样本 */
function samplesIn(categoryId: number, base: number, actuals: number[]): BiasSample[] {
  const list: BiasSample[] = [];
  for (const actual of actuals) {
    list.push(new BiasSample(categoryId, base, actual));
  }
  return list;
}

export default function estimateBiasTest() {
  describe('EstimateBias', () => {

    it('not_ready_below_min_samples', 0, () => {
      // 用两条记录编出来的倍率是编造，不是建议 —— 宁可不给数字
      const samples: BiasSample[] = samplesIn(WORK, 100, [120, 140]);
      const bias: BiasResult = estimateBias(samples, WORK);

      expect(MIN_SAMPLES).assertEqual(3);
      expect(samples.length < MIN_SAMPLES).assertTrue();
      expect(bias.ready).assertFalse();
      expect(bias.sampleCount).assertEqual(2);
      // 未就绪时倍率给 1.0（「就按你估的来」），但调用方只能靠 ready 判断
      expect(bias.medianRatio).assertEqual(1);
    });

    it('not_ready_with_no_samples_at_all', 0, () => {
      const bias: BiasResult = estimateBias([], WORK);
      expect(bias.ready).assertFalse();
      expect(bias.sampleCount).assertEqual(0);
    });

    it('ready_exactly_at_min_samples', 0, () => {
      const bias: BiasResult = estimateBias(samplesIn(WORK, 100, [100, 100, 100]), WORK);
      expect(bias.ready).assertTrue();
      expect(bias.sampleCount).assertEqual(MIN_SAMPLES);
      expect(near(bias.medianRatio, 1)).assertTrue();
    });

    it('uses_the_median_not_the_mean', 0, () => {
      // 倍率 1.2 / 1.5 / 3.0：中位数 1.5，均值 1.9。
      // 取中位数才不会被一次离谱的翻车把建议整体拉高。
      const bias: BiasResult = estimateBias(samplesIn(WORK, 100, [120, 150, 300]), WORK);

      expect(near(bias.medianRatio, 1.5)).assertTrue();
      expect(near(bias.medianRatio, 1.9)).assertFalse();
    });

    it('clamps_absurd_ratios', 0, () => {
      // 预估 10 分钟实际干了 10 小时 = 60 倍，典型来源是预估少打一位。
      // 中位数能扛住离群值，但样本只有 3 条时「离群值」就是中位数本身，所以逐条夹紧。
      const samples: BiasSample[] = [
        new BiasSample(WORK, 10, 600),
        new BiasSample(WORK, 100, 100),
        new BiasSample(WORK, 100, 100)
      ];
      const bias: BiasResult = estimateBias(samples, WORK);

      expect(bias.ready).assertTrue();
      expect(near(bias.medianRatio, 1)).assertTrue();
      // 夹紧到上限 5 之后，上四分位是 (1 + 5) / 2 = 3；不夹紧会是 (1 + 60) / 2 = 30.5
      expect(near(bias.ratioHigh, 3)).assertTrue();
    });

    it('clamps_an_absurdly_small_ratio_too', 0, () => {
      const samples: BiasSample[] = [
        new BiasSample(WORK, 1000, 10),
        new BiasSample(WORK, 100, 100),
        new BiasSample(WORK, 100, 100)
      ];
      const bias: BiasResult = estimateBias(samples, WORK);

      // 夹紧到下限 0.2：下四分位是 (0.2 + 1) / 2 = 0.6；不夹紧会是 (0.01 + 1) / 2 = 0.505
      expect(near(bias.ratioLow, 0.6)).assertTrue();
    });

    it('returns_quartiles_that_bracket_the_median', 0, () => {
      const bias: BiasResult = estimateBias(samplesIn(WORK, 100, [100, 200, 300]), WORK);

      expect(near(bias.medianRatio, 2)).assertTrue();
      expect(near(bias.ratioLow, 1.5)).assertTrue();
      expect(near(bias.ratioHigh, 2.5)).assertTrue();
      expect(bias.ratioLow <= bias.medianRatio).assertTrue();
      expect(bias.medianRatio <= bias.ratioHigh).assertTrue();
    });

    it('filters_by_category', 0, () => {
      const samples: BiasSample[] = [
        new BiasSample(WORK, 100, 140),
        new BiasSample(WORK, 100, 160),
        new BiasSample(WORK, 100, 150),
        new BiasSample(STUDY, 100, 300),
        new BiasSample(STUDY, 100, 300)
      ];
      const work: BiasResult = estimateBias(samples, WORK);

      expect(work.ready).assertTrue();
      expect(work.sampleCount).assertEqual(3);
      expect(near(work.medianRatio, 1.5)).assertTrue();

      // 学习那两条不够 MIN_SAMPLES，必须给出「不够」而不是拿工作的一起算
      const study: BiasResult = estimateBias(samples, STUDY);
      expect(study.ready).assertFalse();
      expect(study.sampleCount).assertEqual(2);
    });

    it('any_category_pools_everything', 0, () => {
      const samples: BiasSample[] = [
        new BiasSample(WORK, 100, 200),
        new BiasSample(STUDY, 100, 200),
        new BiasSample(4, 100, 200)
      ];
      const bias: BiasResult = estimateBias(samples, ANY_CATEGORY);

      expect(bias.ready).assertTrue();
      expect(bias.sampleCount).assertEqual(3);
      expect(near(bias.medianRatio, 2)).assertTrue();
    });

    it('skips_samples_that_cannot_produce_a_ratio', 0, () => {
      // 预估或实际为 0 的样本算不出比值。当成 1.0 混进去会稀释掉真实偏差，
      // 而稀释的后果是「建议」看起来比实际更保守，用户按它做又会超。
      const samples: BiasSample[] = [
        new BiasSample(WORK, 0, 120),
        new BiasSample(WORK, 100, 0),
        new BiasSample(WORK, 100, 200),
        new BiasSample(WORK, 100, 200),
        new BiasSample(WORK, 100, 200)
      ];
      const bias: BiasResult = estimateBias(samples, WORK);

      expect(bias.sampleCount).assertEqual(3);
      expect(near(bias.medianRatio, 2)).assertTrue();
    });

    it('invalid_samples_alone_leave_it_not_ready', 0, () => {
      const samples: BiasSample[] = [
        new BiasSample(WORK, 0, 0),
        new BiasSample(WORK, 100, 0)
      ];
      const bias: BiasResult = estimateBias(samples, WORK);
      expect(bias.ready).assertFalse();
      expect(bias.sampleCount).assertEqual(0);
    });

    it('suggested_minutes_scales_by_the_median', 0, () => {
      const bias: BiasResult = estimateBias(samplesIn(WORK, 100, [140, 140, 140]), WORK);
      expect(suggestedMinutes(60, bias)).assertEqual(84);
      expect(suggestedMinutes(15, bias)).assertEqual(21);
    });

    it('suggested_minutes_returns_own_estimate_when_not_ready', 0, () => {
      // 样本不足时不做任何放大，原样返回用户自己的预估
      const bias: BiasResult = BiasResult.notReady(1);
      expect(suggestedMinutes(60, bias)).assertEqual(60);
    });

    it('suggested_minutes_never_drops_to_zero', 0, () => {
      // 强烈高估自己的用户，样本倍率低到 0.1，被夹紧到下限 0.2。
      // 「建议 0 分钟」没有意义，最少也得给 1 分钟。
      const samples: BiasSample[] = [
        new BiasSample(WORK, 600, 60),
        new BiasSample(WORK, 600, 60),
        new BiasSample(WORK, 600, 60)
      ];
      const bias: BiasResult = estimateBias(samples, WORK);

      expect(near(bias.medianRatio, 0.2)).assertTrue();
      // 5 × 0.2 = 1，正常路径
      expect(suggestedMinutes(5, bias)).assertEqual(1);
      // 1 × 0.2 = 0.2 → round 成 0，被下限兜住
      expect(suggestedMinutes(1, bias)).assertEqual(1);
    });

    // ---- 倍率的整数位/小数位拆分 ----
    // 显示层（ratioText 与复盘建议的句子）共用这一份拆分，所以它自己的边界要被钉住

    it('ratioWhole_and_ratioTenth_split_tenths', 0, () => {
      expect(ratioWhole(14)).assertEqual(1);
      expect(ratioTenth(14)).assertEqual(4);
      // 整倍：小数位是 0，不是省略
      expect(ratioWhole(10)).assertEqual(1);
      expect(ratioTenth(10)).assertEqual(0);
      // 不满一倍
      expect(ratioWhole(8)).assertEqual(0);
      expect(ratioTenth(8)).assertEqual(8);
      // 超过十倍（clampRatio 的上界是 5，但显示层不该依赖那个上界）
      expect(ratioWhole(52)).assertEqual(5);
      expect(ratioTenth(52)).assertEqual(2);
    });

    it('ratioWhole_and_ratioTenth_clamp_non_positive_to_zero', 0, () => {
      // 与重构前的 ratioText 逐位一致：没有「0 倍」这种说法
      expect(ratioWhole(0)).assertEqual(0);
      expect(ratioTenth(0)).assertEqual(0);
      expect(ratioWhole(-5)).assertEqual(0);
      expect(ratioTenth(-5)).assertEqual(0);
    });

    it('ratioWhole_and_ratioTenth_round_float_tenths', 0, () => {
      // tenths 由 Math.round(medianRatio * 10) 产生，但这里也要经得起浮点残留
      expect(ratioWhole(14.000000000000002)).assertEqual(1);
      expect(ratioTenth(14.000000000000002)).assertEqual(4);
      expect(ratioTenth(13.6)).assertEqual(4);
    });

    it('is_deterministic_regardless_of_input_order', 0, () => {
      // 中位数和分位数都不该依赖样本的排列顺序
      const ascending: BiasSample[] = samplesIn(WORK, 100, [100, 200, 300]);
      const shuffled: BiasSample[] = samplesIn(WORK, 100, [300, 100, 200]);

      const a: BiasResult = estimateBias(ascending, WORK);
      const b: BiasResult = estimateBias(shuffled, WORK);

      expect(near(b.medianRatio, a.medianRatio)).assertTrue();
      expect(near(b.ratioLow, a.ratioLow)).assertTrue();
      expect(near(b.ratioHigh, a.ratioHigh)).assertTrue();
    });
  });
}
