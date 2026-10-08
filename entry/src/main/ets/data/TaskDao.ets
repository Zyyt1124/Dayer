import { relationalStore } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { BiasSample } from '../common/EstimateBias';
import { Logger } from '../common/Logger';
import { MS_PER_MINUTE } from '../common/TimeUtil';
import { Task, TaskStatus } from '../model/Task';
import { DbHelper } from './DbHelper';
import { TABLE_TASK, TaskCol } from './TaskSchema';

const TAG: string = 'TaskDao';

/** 每个分类最多取多少条。再多也是半年前的手速，参考价值反而下降 */
export const HISTORY_LIMIT: number = 50;

/**
 * 扫描上限，防止多年积累的数据把整表读进内存。正常使用永远够不到。
 * ⚠️ 必须声明在 QUERY_COMPLETED_SQL **之前** —— SQL 是模块加载时求值的模板字符串，
 * 引用后面声明的 const 会撞上暂时性死区，直接抛 ReferenceError。
 */
const SCAN_LIMIT: number = 1000;

/**
 * 估时校准的历史样本。
 *
 * 只取**已完成**的任务，不取「未完成」的：用户主动放弃的活本来就只做了一半，
 * 拿它的耗时去说明「你总是高估」是错误归因 —— 少做不等于估错了。
 *
 * 按结束时间倒序：近期样本比半年前更能代表现在的手速。
 * 这里的 LIMIT 只兜底病态数据；真正的取样上限是**按分类**算的（见查询方法里的 taken），
 * 不能直接用 SQL 的 LIMIT 封顶 —— 那限制的是所有分类的总数，
 * 会让用得少的分类被用得多的分类挤掉，静默退化成「样本不够」。
 */
const QUERY_COMPLETED_SQL: string =
  `SELECT ${TaskCol.CATEGORY_ID}, ${TaskCol.ESTIMATED_MINUTES}, ` +
  `${TaskCol.ACTUAL_START_TIME}, ${TaskCol.ACTUAL_END_TIME} ` +
  `FROM ${TABLE_TASK} ` +
  `WHERE ${TaskCol.STATUS} = ${TaskStatus.COMPLETED} ` +
  `AND ${TaskCol.ACTUAL_START_TIME} IS NOT NULL ` +
  `AND ${TaskCol.ACTUAL_END_TIME} IS NOT NULL ` +
  `AND ${TaskCol.ACTUAL_END_TIME} > ${TaskCol.ACTUAL_START_TIME} ` +
  `ORDER BY ${TaskCol.ACTUAL_END_TIME} DESC LIMIT ${SCAN_LIMIT}`;

/**
 * 「某一天有哪些任务」的判定：**创建于该日 ∪ 结束于该日**（半开区间 [dayStart, dayEnd)）。
 *
 * 为什么口径是「∪ 结束于该日」而不是「∪ 未完成」：一条 10 月 5 日创建、今天才做完的任务，
 * 在点「完成」的那一刻会掉出 create_time 区间、状态也不再是「未完成」，于是从首页消失 ——
 * 用户刚做完一件事，它就不见了。换成「结束于该日」后，完成动作本身把它带进当天的视图。
 *
 * ⚠️ 三条看似多余的写法的理由：
 * - `IS NOT NULL`：SQLite 三值逻辑下 `NULL >= x` 求值为 NULL（假），不加也对。写上是为了
 *   读的人不必在脑子里过一遍三值逻辑，且日后给这列建索引时优化器更容易走区间。
 * - 不加 `DISTINCT`：单表扫描，一行最多命中一次，OR 不产生重复行。
 * - 绑参顺序是 [dayStart, dayEnd, dayStart, dayEnd]，与四个 `?` 的位置一一对应。
 */
const QUERY_BY_DAY_WHERE: string =
  `(${TaskCol.CREATE_TIME} >= ? AND ${TaskCol.CREATE_TIME} < ?) ` +
  `OR (${TaskCol.ACTUAL_END_TIME} IS NOT NULL ` +
  `AND ${TaskCol.ACTUAL_END_TIME} >= ? AND ${TaskCol.ACTUAL_END_TIME} < ?)`;

/** 未完成排前面，再按优先级，最后按创建时间。历史日与今日共用，排序不会随视图跳变 */
const QUERY_BY_DAY_ORDER: string =
  ` ORDER BY ${TaskCol.STATUS} ASC, ${TaskCol.PRIORITY} DESC, ${TaskCol.CREATE_TIME} ASC`;

/** 历史上的某一天 */
const QUERY_BY_DAY_SQL: string =
  `SELECT * FROM ${TABLE_TASK} WHERE ${QUERY_BY_DAY_WHERE}${QUERY_BY_DAY_ORDER}`;

/**
 * 今天 = 上面那条 + **所有尚未完成的任务**。
 * 未完成的跨天任务不能从列表里消失，否则用户会以为它被删了。
 * 只有「今天」能加这个分支：加到历史日上会把所有未完成任务灌进每一个过去的日子。
 */
const QUERY_TODAY_SQL: string =
  `SELECT * FROM ${TABLE_TASK} WHERE (${QUERY_BY_DAY_WHERE}) ` +
  `OR ${TaskCol.STATUS} IN (${TaskStatus.NOT_STARTED}, ${TaskStatus.IN_PROGRESS})` +
  QUERY_BY_DAY_ORDER;

const QUERY_BY_ID_SQL: string = `SELECT * FROM ${TABLE_TASK} WHERE ${TaskCol.ID} = ?`;

/** 时间戳：0（内存哨兵）→ NULL */
function toColumnValue(timestamp: number): relationalStore.ValueType {
  return timestamp > 0 ? timestamp : null;
}

function toBucket(task: Task): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {};
  bucket[TaskCol.TITLE] = task.title;
  bucket[TaskCol.DETAIL] = task.detail;
  bucket[TaskCol.ESTIMATED_MINUTES] = task.estimatedMinutes;
  bucket[TaskCol.PRIORITY] = task.priority;
  bucket[TaskCol.CATEGORY_ID] = task.categoryId;
  bucket[TaskCol.STATUS] = task.status;
  bucket[TaskCol.CREATE_TIME] = task.createTime;
  bucket[TaskCol.PLAN_START_TIME] = toColumnValue(task.planStartTime);
  bucket[TaskCol.DEADLINE] = toColumnValue(task.deadline);
  bucket[TaskCol.ACTUAL_START_TIME] = toColumnValue(task.actualStartTime);
  bucket[TaskCol.ACTUAL_END_TIME] = toColumnValue(task.actualEndTime);
  bucket[TaskCol.DEVIATION_REASON] = task.deviationReason;
  return bucket;
}

/**
 * 任务的持久化访问。
 *
 * 每个改动都是单行操作，因此不使用事务 —— 同步的 beginTransaction() 包住 await 的
 * 异步写有丢数据的风险（SDK 文档明确警告），日后若需批量应改用 createTransaction()。
 *
 * 所有 relationalStore 接口在 .d.ts 里都带 @throws，ArkTS 的 ArkTSCheck 要求显式处理，
 * 否则每个调用点都会报 "Function may throw exceptions"。因此这里每个操作都是一个完整的
 * try/catch：捕获、记日志、原样上抛 —— 不吞异常，调用方仍要自己 .catch()。
 */
export class TaskDao {

  /** 插入并返回自增主键 */
  static async insert(task: Task): Promise<number> {
    try {
      const store: relationalStore.RdbStore = await DbHelper.getStore();
      const rowId: number = await store.insert(TABLE_TASK, toBucket(task));
      Logger.info(TAG, `insert task id=${rowId}`);
      return rowId;
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.error(TAG, `insert failed: ${e.code} ${e.message}`);
      throw e as Error;
    }
  }

  /** 整行更新，以 task.id 定位 */
  static async update(task: Task): Promise<void> {
    try {
      const store: relationalStore.RdbStore = await DbHelper.getStore();
      const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(TABLE_TASK);
      predicates.equalTo(TaskCol.ID, task.id);
      await store.update(toBucket(task), predicates);
      Logger.info(TAG, `update task id=${task.id} status=${task.status}`);
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.error(TAG, `update failed: ${e.code} ${e.message}`);
      throw e as Error;
    }
  }

  static async remove(id: number): Promise<void> {
    try {
      const store: relationalStore.RdbStore = await DbHelper.getStore();
      const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(TABLE_TASK);
      predicates.equalTo(TaskCol.ID, id);
      await store.delete(predicates);
      Logger.info(TAG, `delete task id=${id}`);
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.error(TAG, `delete failed: ${e.code} ${e.message}`);
      throw e as Error;
    }
  }

  /** 查不到返回 null，由调用方决定怎么处理 */
  static async queryById(id: number): Promise<Task | null> {
    const rows: Task[] = await TaskDao.queryTasks(QUERY_BY_ID_SQL, [id]);
    return rows.length > 0 ? rows[0] : null;
  }

  /**
   * 某一天的任务（创建于该日 ∪ 结束于该日）。区间由调用方用 TimeUtil.dayRangeOf 算好传进来，
   * 保持这里是纯粹的取数、不带任何「今天是几号」的判断。
   *
   * @param includeUnfinished 是否连尚未完成的任务一起返回。**只对「今天」传 true** ——
   *        它的作用是让未完成的跨天任务不从首页消失（用户会以为被删了）。
   *        历史日传 true 会把所有未完成任务灌进每一个过去的日子。
   */
  static queryByDay(dayStart: number, dayEnd: number, includeUnfinished: boolean): Promise<Task[]> {
    const sql: string = includeUnfinished ? QUERY_TODAY_SQL : QUERY_BY_DAY_SQL;
    return TaskDao.queryTasks(sql, [dayStart, dayEnd, dayStart, dayEnd]);
  }

  /**
   * 取「已完成且有计时」的历史样本，供 EstimateBias 统计偏差倍率。
   *
   * 一次取回全部分类而不是按分类分别查：编辑页上点分类 chip 要立刻看到建议，
   * 每点一次发一次查询既慢又会引入响应乱序的隐患；几千条样本在内存里过滤的成本可以忽略。
   *
   * 每分类各留 limit 条：SQL 已经按结束时间倒序，所以每个分类最先遇到的 limit 条
   * 正好就是它最近的那 limit 条。
   *
   * 不复用 queryTasks()：那条路径要映射完整的 13 列 Task，而这里只要 4 列，
   * 且返回的是统计样本而不是任务实体，混用会让两个概念越来越黏。
   */
  static async queryCompletedDurations(limit: number): Promise<BiasSample[]> {
    const samples: BiasSample[] = [];
    const safeLimit: number = limit > 0 ? Math.floor(limit) : HISTORY_LIMIT;
    /** 分类 → 已收录条数。用来做「每分类各自封顶」 */
    const taken: Map<number, number> = new Map();
    let rs: relationalStore.ResultSet | null = null;
    try {
      const store: relationalStore.RdbStore = await DbHelper.getStore();
      rs = await store.querySql(QUERY_COMPLETED_SQL, []);

      const iCategory: number = rs.getColumnIndex(TaskCol.CATEGORY_ID);
      const iEstimated: number = rs.getColumnIndex(TaskCol.ESTIMATED_MINUTES);
      const iStart: number = rs.getColumnIndex(TaskCol.ACTUAL_START_TIME);
      const iEnd: number = rs.getColumnIndex(TaskCol.ACTUAL_END_TIME);

      while (rs.goToNextRow()) {
        const start: number = rs.getLong(iStart);
        const end: number = rs.getLong(iEnd);

        // 与 calcDeviation 的 TOO_SHORT 同一个口径：实测不足 1 分钟的任务推不出倍率，
        // 让它们进样本只会把中位数往下拽，而且会造成「视图说没数据、教练却拿它当样本」
        // 这种自相矛盾。
        //
        // ⚠️ 必须在**占额度之前**跳过。额度先占再判断的话，被跳过的行会白吃掉该分类
        // 的名额，样本变少但不报错，用户看到的是「样本还太少」而不是「有数据被丢了」。
        if (end - start < MS_PER_MINUTE) {
          continue;
        }

        const categoryId: number = rs.getLong(iCategory);
        const used: number = taken.get(categoryId) ?? 0;
        if (used >= safeLimit) {
          continue;
        }
        taken.set(categoryId, used + 1);

        const estimated: number = rs.getLong(iEstimated);
        // 分钟换算放在这里而不是 SQL 里：除法取整的规则属于业务，写进 SQL 就没法单测了
        samples.push(new BiasSample(categoryId, estimated,
          Math.round((end - start) / MS_PER_MINUTE)));
      }
      Logger.info(TAG, `history samples: ${samples.length} over ${taken.size} category(ies)`);
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.error(TAG, `query history failed: ${e.code} ${e.message}`);
      throw e as Error;
    } finally {
      if (rs !== null) {
        try {
          rs.close();
        } catch (err) {
          const e: BusinessError = err as BusinessError;
          Logger.warn(TAG, `close resultSet failed: ${e.code} ${e.message}`);
        }
      }
    }
    return samples;
  }

  /**
   * 唯一的查询路径，按 id 与按今日都走这里，避免两处重复 13 列的映射。
   *
   * 逐列显式取值而不用 getRow()：后者返回的 ValueType 联合里含 bigint/Uint8Array/Asset，
   * 每次读都要窄化，而 getLong/getString 返回的已经是确定类型。
   * 列下标取一次复用整轮循环，避免每行都按列名查表。
   */
  private static async queryTasks(sql: string, args: relationalStore.ValueType[]): Promise<Task[]> {
    const rows: Task[] = [];
    let rs: relationalStore.ResultSet | null = null;
    try {
      const store: relationalStore.RdbStore = await DbHelper.getStore();
      rs = await store.querySql(sql, args);

      const iId: number = rs.getColumnIndex(TaskCol.ID);
      const iTitle: number = rs.getColumnIndex(TaskCol.TITLE);
      const iDetail: number = rs.getColumnIndex(TaskCol.DETAIL);
      const iEstimated: number = rs.getColumnIndex(TaskCol.ESTIMATED_MINUTES);
      const iPriority: number = rs.getColumnIndex(TaskCol.PRIORITY);
      const iCategory: number = rs.getColumnIndex(TaskCol.CATEGORY_ID);
      const iStatus: number = rs.getColumnIndex(TaskCol.STATUS);
      const iCreateTime: number = rs.getColumnIndex(TaskCol.CREATE_TIME);
      const iPlanStart: number = rs.getColumnIndex(TaskCol.PLAN_START_TIME);
      const iDeadline: number = rs.getColumnIndex(TaskCol.DEADLINE);
      const iActualStart: number = rs.getColumnIndex(TaskCol.ACTUAL_START_TIME);
      const iActualEnd: number = rs.getColumnIndex(TaskCol.ACTUAL_END_TIME);
      const iReason: number = rs.getColumnIndex(TaskCol.DEVIATION_REASON);

      while (rs.goToNextRow()) {
        const task: Task = new Task();
        task.id = rs.getLong(iId);
        task.title = rs.getString(iTitle);
        task.detail = rs.getString(iDetail);
        task.estimatedMinutes = rs.getLong(iEstimated);
        task.priority = rs.getLong(iPriority);
        task.categoryId = rs.getLong(iCategory);
        task.status = rs.getLong(iStatus);
        task.createTime = rs.getLong(iCreateTime);
        // 只有这 4 个时间戳列可为 NULL，其余列建表时都是 NOT NULL，
        // 所以只有它们需要判空：NULL → 0（内存哨兵）
        task.planStartTime = rs.isColumnNull(iPlanStart) ? 0 : rs.getLong(iPlanStart);
        task.deadline = rs.isColumnNull(iDeadline) ? 0 : rs.getLong(iDeadline);
        task.actualStartTime = rs.isColumnNull(iActualStart) ? 0 : rs.getLong(iActualStart);
        task.actualEndTime = rs.isColumnNull(iActualEnd) ? 0 : rs.getLong(iActualEnd);
        task.deviationReason = rs.getString(iReason);
        rows.push(task);
      }
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.error(TAG, `query failed: ${e.code} ${e.message}`);
      throw e as Error;
    } finally {
      // ResultSet 不会靠 GC 自动释放，必须显式关闭；关失败也只能记一笔，
      // 不能盖掉 try 里真正的查询异常。
      if (rs !== null) {
        try {
          rs.close();
        } catch (err) {
          const e: BusinessError = err as BusinessError;
          Logger.warn(TAG, `close resultSet failed: ${e.code} ${e.message}`);
        }
      }
    }
    return rows;
  }
}
