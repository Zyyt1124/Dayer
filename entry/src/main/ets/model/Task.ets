/**
 * 任务状态。
 * 刻意没有「延期完成」这一档：是否逾期完成由 actualEndTime > deadline 实时推导，
 * 与「预估是否准确」是两个独立维度，混进状态枚举会让每个「是否已完成」的判断都要额外
 * 知道它是完成态，撤销路径还要反向映射。
 */
export enum TaskStatus {
  NOT_STARTED = 0,
  IN_PROGRESS = 1,
  COMPLETED = 2,
  UNFINISHED = 3
}

export enum TaskPriority {
  LOW = 0,
  MEDIUM = 1,
  HIGH = 2
}

/** 本期内置的固定分类，没有独立数据表，名称走 $r('app.string.category_*') 资源 */
export enum TaskCategory {
  WORK = 0,
  STUDY = 1,
  LIFE = 2,
  ENTERTAINMENT = 3,
  FITNESS = 4
}

/**
 * 任务实体。
 *
 * 所有字段都是非可选的且带默认值，因为 relationalStore 的 ValueType 不包含 undefined，
 * 字段可空会让 ValuesBucket 无法构造。
 *
 * 约定：时间戳字段用 **0 表示「未设置」**（内存中的哨兵值），落库时统一转成 NULL，
 * 读出时再由 DAO 把 NULL 转回 0。这样内存里不需要处理 null，SQL 里又能用
 * isColumnNull 正确判断。
 *
 * 实际耗时不是字段 —— 它由 actualEndTime - actualStartTime 推导（见 TimeUtil），
 * 不落库，避免冗余数据漂移。
 */
export class Task {
  id: number = 0;
  title: string = '';
  detail: string = '';
  /** 预计耗时（分钟）—— 本应用的核心字段 */
  estimatedMinutes: number = 0;
  priority: number = TaskPriority.MEDIUM;
  categoryId: number = TaskCategory.WORK;
  status: number = TaskStatus.NOT_STARTED;
  createTime: number = 0;
  /** 预计开始时间戳，0 = 未设置 */
  planStartTime: number = 0;
  /** 截止时间戳，0 = 未设置 */
  deadline: number = 0;
  /** 实际开始时间戳，0 = 未开始。由「开始」动作写入，之后不再覆盖 */
  actualStartTime: number = 0;
  /** 实际结束时间戳，0 = 未结束。撤销完成时清除，保留 actualStartTime */
  actualEndTime: number = 0;
  /** 耗时偏差原因（选填） */
  deviationReason: string = '';

  /** 是否已经点过「开始」 */
  hasTiming(): boolean {
    return this.actualStartTime > 0;
  }

  /** 是否处于完成态 */
  isCompleted(): boolean {
    return this.status === TaskStatus.COMPLETED;
  }

  /** 是否逾期完成：仅在已完成且有截止时间时有意义 */
  isCompletedLate(): boolean {
    return this.isCompleted() && this.deadline > 0 && this.actualEndTime > this.deadline;
  }
}
