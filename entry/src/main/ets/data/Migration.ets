import { CREATE_TASK_TABLE_SQL } from './TaskSchema';

/**
 * 数据库表结构的版本管理。
 *
 * ⚠️ 与 TimeUtil / TaskFlow 一样，本文件**禁止 import 任何 @kit 模块** ——
 * 「当前是第几版」「从某一版升到另一版该跑哪几条语句」都是纯逻辑，
 * 要能被 entry/src/test/ 的本地单测直接覆盖。真正执行 SQL 的只有 DbHelper。
 *
 * 为什么需要它：relationalStore **没有**安卓 SQLiteOpenHelper 那样的 onUpgrade 回调。
 * 官方给的方案是自己读写 `RdbStore.version`（@since 10，已核对 .d.ts），再决定执行哪些语句。
 * 而且 `StoreConfig` 里**根本没有 version 字段**，版本号只能在开库之后写。
 *
 * 关键前提：本工程此前的代码**从没写过版本号**，所以已经装在机器上的库读出来是 0。
 * 因此版本 0 必须走「建立初始结构」那条路，否则老库会因为「无需迁移」而丢掉表结构。
 */

/** 当前表结构版本。**每次改动表结构都要 +1，并在下面 MIGRATIONS 里补一条对应语句。** */
export const DB_VERSION: number = 1;

/** 一条结构变更：把库升到 version 这个版本号时，需要执行的 SQL */
class MigrationStep {
  version: number;
  sql: string;

  constructor(version: number, sql: string) {
    this.version = version;
    this.sql = sql;
  }
}

/**
 * 全部结构变更，按 version 升序。
 *
 * 每条的 sql 都必须**自身幂等**（建表带 IF NOT EXISTS；加列前先判断列是否存在），
 * 因为迁移中途失败时下次启动会整段重跑。见 migrate() 的注释。
 */
const MIGRATIONS: MigrationStep[] = [
  // v1：初始结构，唯一的 task 表
  new MigrationStep(1, CREATE_TASK_TABLE_SQL)
];

/**
 * 从 from 版升到 to 版需要执行的 SQL。
 *
 * 三种边界情形是这里唯一容易写错的地方，逐条单测覆盖：
 * - `from === to`：空数组，已经是最新，一句都不跑；
 * - `from > to`：空数组。**降级不执行任何语句，调用方也不要回写版本号** ——
 *   用户装了旧版 App 覆盖新库时，宁可让它跑在「结构比预期新」的库上，
 *   也不能拿旧 SQL 去改坏数据；等装回新版自然恢复；
 * - `from <= 0`：视为「还没有任何结构」，会跑到版本 1 的建表语句。
 *   新装的库和本工程此前没写过版本号的老库都落在这里。
 */
export function migrationSteps(from: number, to: number): string[] {
  if (from >= to) {
    return [];
  }
  const steps: string[] = [];
  for (const step of MIGRATIONS) {
    if (step.version > from && step.version <= to) {
      steps.push(step.sql);
    }
  }
  return steps;
}
