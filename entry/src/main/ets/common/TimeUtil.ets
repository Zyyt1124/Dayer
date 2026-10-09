/**
 * 时间与耗时计算的纯函数。这些是 Dayer 的核心差异化逻辑（预估 vs 实际），
 * 因此单独抽出来由 entry/src/test/ 的本地单测直接覆盖。
 *
 * ⚠️ 本文件禁止 import 任何 @kit 模块，也禁止使用 $r() 资源引用。
 * 本地单测不跑在设备运行时上，这些依赖会让测试无法执行。
 */

/** 导出给同样需要做毫秒/分钟换算的纯函数（TaskFlow 的补记、ReminderPlan 的时点计算） */
export const MS_PER_MINUTE: number = 60000;
/** 容差下限：即使预计耗时很短，也允许 5 分钟的偏差 */
const TOLERANCE_MIN_MINUTES: number = 5;
/** 容差比例：预计耗时的 10% */
const TOLERANCE_RATIO: number = 0.1;

/** 预估偏差的判定结果 */
export enum DeviationKind {
  /** 从未点过「开始」，没有计时数据，不应编造耗时 */
  NO_TIMING_DATA = 0,
  /** 实际结束早于实际开始，通常是用户改了系统时间 */
  TIME_ANOMALY = 1,
  /** 与实际耗时基本吻合 */
  ACCURATE = 2,
  /** 实际耗时超出预计 */
  OVER = 3,
  /** 实际耗时少于预计 */
  UNDER = 4,
  /**
   * 有计时数据，但实际耗时不足 1 分钟 —— 算不出有意义的偏差。
   *
   * 存在的理由是一个真实缺陷：`Math.round` 会把 23 秒折算成 0 分钟，
   * 于是一个「预估 60 分钟、实点两下就完成」的误触任务被判成「节省 1小时」。
   * 用户误触开始/完成就能造出这种行，而它会把整个估时统计污染成「我一直在高估」。
   *
   * 数值只能追加、不能重排（5 接在 4 后面）。枚举值本身不落库，但既有取值保持不变
   * 能让「翻旧日志对不上号」这种事不发生。
   */
  TOO_SHORT = 5
}

/**
 * 偏差计算结果。actualMinutes 在没数据/异常时不可解读，
 * 调用方必须先看 kind 再决定是否展示 actualMinutes 与 diffMinutes。
 */
export class DeviationResult {
  kind: DeviationKind;
  /** 实际耗时（分钟），仅当 kind 为 ACCURATE/OVER/UNDER 时有效 */
  actualMinutes: number;
  /** 实际 − 预计（分钟），仅当 kind 为 ACCURATE/OVER/UNDER 时有效 */
  diffMinutes: number;

  constructor(kind: DeviationKind, actualMinutes: number, diffMinutes: number) {
    this.kind = kind;
    this.actualMinutes = actualMinutes;
    this.diffMinutes = diffMinutes;
  }
}

/**
 * 由时间戳推导实际耗时并算出与预计的偏差。
 *
 * @param estimatedMinutes 预计耗时（分钟）
 * @param actualStartTime  实际开始时间戳，0 表示未记录
 * @param actualEndTime    实际结束时间戳，0 表示未记录
 */
export function calcDeviation(estimatedMinutes: number,
                              actualStartTime: number,
                              actualEndTime: number): DeviationResult {
  if (actualStartTime <= 0 || actualEndTime <= 0) {
    return new DeviationResult(DeviationKind.NO_TIMING_DATA, 0, 0);
  }

  // Date.now() 是墙上时钟，用户改系统时间会让结束早于开始。
  // 夹紧到 0 并单独标记，避免显示出一个负数构成的假「节省」。
  //
  // ⚠️ 这一条必须留在下面那条「不足 1 分钟」**之前**：时钟被拨回时
  // end - start 是负数，也满足 `< MS_PER_MINUTE`，顺序反了就会把「时间异常」
  // 误报成「耗时过短」，把一个需要用户注意的问题降级成一句中性描述。
  if (actualEndTime < actualStartTime) {
    return new DeviationResult(DeviationKind.TIME_ANOMALY, 0, 0);
  }

  // 不足 1 分钟的实测耗时算不出偏差：四舍五入会得到 0 分钟，
  // 60 分钟的预估于是被读成「节省 1小时」（实测：一个 23 秒的误触任务）。
  // 阈值取整分钟而不是「四舍五入后为 0」：45 秒也会被舍成 1 分钟，
  // 而一个「耗时 1 分钟、预估 8 小时」的结论同样没有意义。
  if (actualEndTime - actualStartTime < MS_PER_MINUTE) {
    return new DeviationResult(DeviationKind.TOO_SHORT, 0, 0);
  }

  const actualMinutes: number = Math.round((actualEndTime - actualStartTime) / MS_PER_MINUTE);
  const diffMinutes: number = actualMinutes - estimatedMinutes;

  const tolerance: number = Math.max(TOLERANCE_MIN_MINUTES, estimatedMinutes * TOLERANCE_RATIO);
  if (Math.abs(diffMinutes) <= tolerance) {
    return new DeviationResult(DeviationKind.ACCURATE, actualMinutes, diffMinutes);
  }
  const kind: DeviationKind = diffMinutes > 0 ? DeviationKind.OVER : DeviationKind.UNDER;
  return new DeviationResult(kind, actualMinutes, diffMinutes);
}

/** 耗时的结构化表示，由视图层拼成带单位的文案（避免在这里硬编码中文字符串） */
export class DurationParts {
  hours: number;
  minutes: number;

  constructor(hours: number, minutes: number) {
    this.hours = hours;
    this.minutes = minutes;
  }
}

/** 把分钟数拆成小时 + 分钟 */
export function splitDuration(totalMinutes: number): DurationParts {
  const safe: number = totalMinutes > 0 ? Math.floor(totalMinutes) : 0;
  return new DurationParts(Math.floor(safe / 60), safe % 60);
}

/** 任意时刻 → 它所属那天的本地零点。`startOfToday` 的泛化，名字不再绑死「今天」 */
export function startOfDay(anchor: number): number {
  const d: Date = new Date(anchor);
  d.setHours(0, 0, 0, 0);
  return d.getTime();
}

/**
 * 按**日历天**平移，保留本地钟面时刻。
 *
 * ⚠️ 绝不能写成 `anchor ± delta * 86400000`：一天的毫秒数不是常量。在有夏令时/时区规则
 * 切换的地区，某一天只有 23 小时或长达 25 小时，加减固定毫秒会落到相邻那天的 23:00 或
 * 01:00 —— 对一个「日零点」锚点来说就是整体错了一天，半开区间随之整段偏移。
 * `setDate` 走的是日历运算，闰年、月末、跨年由运行时统一处理（1月31日 +1 → 2月1日，
 * 而不是一个不存在的「1月32日」）。
 *
 * 本文件**刻意不提供 MS_PER_DAY** —— 提供了就一定会有人拿它去做日的加减。
 */
export function shiftDays(anchor: number, delta: number): number {
  const d: Date = new Date(anchor);
  d.setDate(d.getDate() + delta);
  return d.getTime();
}

/** 两个时间戳是否落在同一个本地日历日 */
export function isSameDay(a: number, b: number): boolean {
  return startOfDay(a) === startOfDay(b);
}

/** 一天的半开区间 [start, end)。用 class 而非对象字面量，规避 arkts-no-untyped-obj-literals */
export class DayRange {
  start: number;
  end: number;

  constructor(start: number, end: number) {
    this.start = start;
    this.end = end;
  }
}

/**
 * 某时刻所属那一天的半开区间 [当天零点, 次日零点)。
 * 半开而非闭区间：这样相邻两天无缝拼接（今天的 end 就是明天的 start），
 * 任何时间戳都恰好落进一天，不会出现「边界那一刻两天都查不到」或「两天都查得到」。
 */
export function dayRangeOf(anchor: number): DayRange {
  const start: number = startOfDay(anchor);
  return new DayRange(start, startOfDay(shiftDays(start, 1)));
}

/** 当天零点的时间戳，用于「今日」任务的查询区间 */
export function startOfToday(now: number): number {
  return startOfDay(now);
}

/** 次日零点的时间戳（区间右开边界） */
export function startOfTomorrow(now: number): number {
  return dayRangeOf(now).end;
}

/**
 * 某时刻所属那一周的零点，**以周一为一周之始**（中文语境下「本周」的默认含义）。
 *
 * `getDay()` 里 0 是周日、1 是周一，直接减 1 会让周日算出 -1 天、落到上一周的周六，
 * 于是「本周」在周日那天整整少算一周。加 6 再取模把周日映射成 6（距本周一已过 6 天），
 * 一周七天就都落在 0..6 上。
 *
 * 平移走 `shiftDays` 而不是 `- offset * 86400000` —— 理由见 shiftDays 自己的注释；
 * 外层再套一次 `startOfDay` 是为了让跨夏令时切换周的钟面漂移归零。
 */
export function startOfWeek(anchor: number): number {
  const dayOfWeek: number = new Date(anchor).getDay();
  const daysSinceMonday: number = (dayOfWeek + 6) % 7;
  return startOfDay(shiftDays(startOfDay(anchor), -daysSinceMonday));
}

/**
 * 某时刻所属那个月 1 号的零点。
 *
 * 用 `setDate(1)` 直接改日历字段，不经由「减掉今天是几号」的算术：
 * 1 号减 1 天会落到上个月最后一天（3 月 1 日 → 2 月 28/29 日），
 * 那是「上个月末」而不是「本月 1 号」，是这类代码最常见的差一天。
 */
export function startOfMonth(anchor: number): number {
  const d: Date = new Date(anchor);
  d.setDate(1);
  d.setHours(0, 0, 0, 0);
  return d.getTime();
}

/** 把某一天的时间戳推到当天 23:59:59.999 */
export function endOfDay(timestamp: number): number {
  const d: Date = new Date(timestamp);
  d.setHours(23, 59, 59, 999);
  return d.getTime();
}

/**
 * 格式化为 YYYY-MM-DD。
 * 不用 toLocaleDateString()：它依赖设备区域设置，同一个时间戳在不同设置下文案不同，
 * 而截止时间是需要稳定呈现的数据。
 */
export function formatDate(timestamp: number): string {
  const d: Date = new Date(timestamp);
  const month: string = String(d.getMonth() + 1).padStart(2, '0');
  const day: string = String(d.getDate()).padStart(2, '0');
  return `${d.getFullYear()}-${month}-${day}`;
}
