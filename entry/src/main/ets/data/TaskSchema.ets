/**
 * task 表的唯一权威定义。建表与查询都从这里取列名，避免两边字符串写岔。
 * 单独成文件是为了让 DbHelper 与 TaskDao 都能引用而不产生循环依赖。
 */

export const TABLE_TASK: string = 'task';

export class TaskCol {
  static readonly ID: string = 'id';
  static readonly TITLE: string = 'title';
  static readonly DETAIL: string = 'detail';
  static readonly ESTIMATED_MINUTES: string = 'estimated_minutes';
  static readonly PRIORITY: string = 'priority';
  static readonly CATEGORY_ID: string = 'category_id';
  static readonly STATUS: string = 'status';
  static readonly CREATE_TIME: string = 'create_time';
  static readonly PLAN_START_TIME: string = 'plan_start_time';
  static readonly DEADLINE: string = 'deadline';
  static readonly ACTUAL_START_TIME: string = 'actual_start_time';
  static readonly ACTUAL_END_TIME: string = 'actual_end_time';
  static readonly DEVIATION_REASON: string = 'deviation_reason';
}

/**
 * 时间戳列一律可空，用 NULL 表示「未设置」而不是 0 —— 0 是合法时间戳（1970），
 * 当哨兵会让 SQL 判断和推导逻辑都变得含糊。内存里的 Task 用 0 表示未设置，
 * 由 TaskDao 在读写边界做转换。
 */
export const CREATE_TASK_TABLE_SQL: string =
  `CREATE TABLE IF NOT EXISTS ${TABLE_TASK} (` +
    `${TaskCol.ID} INTEGER PRIMARY KEY AUTOINCREMENT, ` +
    `${TaskCol.TITLE} TEXT NOT NULL, ` +
    `${TaskCol.DETAIL} TEXT NOT NULL DEFAULT '', ` +
    `${TaskCol.ESTIMATED_MINUTES} INTEGER NOT NULL DEFAULT 0, ` +
    `${TaskCol.PRIORITY} INTEGER NOT NULL DEFAULT 1, ` +
    `${TaskCol.CATEGORY_ID} INTEGER NOT NULL DEFAULT 0, ` +
    `${TaskCol.STATUS} INTEGER NOT NULL DEFAULT 0, ` +
    `${TaskCol.CREATE_TIME} INTEGER NOT NULL DEFAULT 0, ` +
    `${TaskCol.PLAN_START_TIME} INTEGER, ` +
    `${TaskCol.DEADLINE} INTEGER, ` +
    `${TaskCol.ACTUAL_START_TIME} INTEGER, ` +
    `${TaskCol.ACTUAL_END_TIME} INTEGER, ` +
    `${TaskCol.DEVIATION_REASON} TEXT NOT NULL DEFAULT ''` +
  `)`;
