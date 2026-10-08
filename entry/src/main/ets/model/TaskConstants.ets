import { DeviationKind } from '../common/TimeUtil';
import { TaskPriority, TaskStatus } from './Task';


/**
 * 枚举值 → 资源文案的静态映射。
 *
 * $r('app.string.xxx') 的 key 必须是字符串字面量，不能拼接（$r('app.string.' + name) 会被拒绝），
 * 所以这里只能写成 if/else 而不是查表 + 动态 key。
 */

export function priorityText(priority: number): Resource {
  if (priority === TaskPriority.HIGH) {
    return $r('app.string.priority_high');
  }
  if (priority === TaskPriority.LOW) {
    return $r('app.string.priority_low');
  }
  return $r('app.string.priority_medium');
}

export function categoryText(categoryId: number): Resource {
  if (categoryId === 1) {
    return $r('app.string.category_study');
  }
  if (categoryId === 2) {
    return $r('app.string.category_life');
  }
  if (categoryId === 3) {
    return $r('app.string.category_entertainment');
  }
  if (categoryId === 4) {
    return $r('app.string.category_fitness');
  }
  return $r('app.string.category_work');
}

export function statusText(status: number): Resource {
  if (status === TaskStatus.IN_PROGRESS) {
    return $r('app.string.status_in_progress');
  }
  if (status === TaskStatus.COMPLETED) {
    return $r('app.string.status_completed');
  }
  if (status === TaskStatus.UNFINISHED) {
    return $r('app.string.status_unfinished');
  }
  return $r('app.string.status_not_started');
}

/** 耗时文案：按小时/分钟自动选择单位 */
export function durationText(totalMinutes: number): Resource {
  const safe: number = totalMinutes > 0 ? Math.floor(totalMinutes) : 0;
  const hours: number = Math.floor(safe / 60);
  const minutes: number = safe % 60;
  if (hours > 0 && minutes > 0) {
    return $r('app.string.duration_hour_minute', hours, minutes);
  }
  if (hours > 0) {
    return $r('app.string.duration_hour', hours);
  }
  return $r('app.string.duration_minute', minutes);
}

/**
 * 快捷耗时选项（分钟），覆盖绝大多数「一件事大概多久」的判断。
 * 编辑页填预估、详情页补记实际用时共用同一组，免得两个页面给出的选项不一样。
 */
export const QUICK_MINUTES: number[] = [15, 30, 45, 60, 90, 120];

/**
 * 倍率文案：「1.4 倍」。
 *
 * 入参是倍率的**十分位整数**（1.4 倍传 14），而不是浮点数 —— 两处原因：
 * 1. 资源占位符只有 %d 可用（已是全工程既定写法，见 duration_* 几个 key），
 *    小数只能拆成整数位和小数位两个 %d；
 * 2. @State 里存整数比存浮点稳妥，不会出现 1.4000000000000001 这种显示。
 */
export function ratioText(tenths: number): Resource {
  const safe: number = tenths > 0 ? Math.round(tenths) : 0;
  return $r('app.string.coach_ratio', Math.floor(safe / 10), safe % 10);
}

/**
 * 偏差结论的标签文案。
 *
 * `TOO_SHORT`（实测不足 1 分钟）刻意不单独给一条文案，落到最后的
 * 「未记录计时」上 —— 这是产品决定：不足一分钟的实测值推不出任何结论，
 * 与其新造一个「计时过短」让用户琢磨，不如和「根本没计时」一样处理。
 * 想改成年后者只需在这里插一个分支 + 加一条资源，不用动 TimeUtil。
 */
export function deviationLabelText(kind: DeviationKind): Resource {
  if (kind === DeviationKind.ACCURATE) {
    return $r('app.string.deviation_accurate');
  }
  if (kind === DeviationKind.OVER) {
    return $r('app.string.deviation_over');
  }
  if (kind === DeviationKind.UNDER) {
    return $r('app.string.deviation_under');
  }
  if (kind === DeviationKind.TIME_ANOMALY) {
    return $r('app.string.deviation_time_anomaly');
  }
  return $r('app.string.deviation_no_timing');
}

/**
 * 偏差结论对应的颜色。
 * 「超出」用暖色（需要重视），「节省」用绿色（正向），
 * 无数据/时间异常/耗时过短都用中性灰 —— 它们不是好坏评价，只是「没结论」。
 */
export function deviationColor(kind: DeviationKind): Resource {
  if (kind === DeviationKind.OVER) {
    return $r('app.color.deviation_over');
  }
  if (kind === DeviationKind.UNDER) {
    return $r('app.color.deviation_under');
  }
  if (kind === DeviationKind.ACCURATE) {
    return $r('app.color.deviation_accurate');
  }
  return $r('app.color.deviation_neutral');
}

/** 优先级对应的强调色，用于列表左侧的竖条与标签 */
export function priorityColor(priority: number): Resource {
  if (priority === TaskPriority.HIGH) {
    return $r('app.color.priority_high');
  }
  if (priority === TaskPriority.LOW) {
    return $r('app.color.priority_low');
  }
  return $r('app.color.priority_medium');
}
