import { describe, it, expect } from '@ohos/hypium';
import { DB_VERSION, migrationSteps } from '../main/ets/data/Migration';

export default function migrationTest() {
  describe('Migration', () => {

    it('fresh_database_gets_the_initial_schema', 0, () => {
      // 全新库读出来是 0，「没写过版本号的老库」读出来同样是 0 ——
      // 两者走同一条路，所以这一个用例同时覆盖「新装」与「从无版本号升级」。
      // 断言「包含建表语句」而不是「长度为 1」：日后 DB_VERSION 涨到 2、3 时，
      // 从 0 升上来必然要连跑多步，写死长度会让这条测试变成每次加表都要改的噪音。
      const steps: string[] = migrationSteps(0, DB_VERSION);
      expect(steps.length > 0).assertTrue();
      let hasCreateTable: boolean = false;
      for (const sql of steps) {
        if (sql.indexOf('CREATE TABLE IF NOT EXISTS') >= 0) {
          hasCreateTable = true;
        }
      }
      expect(hasCreateTable).assertTrue();
    });

    it('up_to_date_database_runs_nothing', 0, () => {
      // 已经是最新版就一句都不跑，否则每次启动都在重复执行 DDL
      expect(migrationSteps(DB_VERSION, DB_VERSION).length).assertEqual(0);
    });

    it('downgrade_runs_nothing', 0, () => {
      // 装了旧版 App 覆盖新库：一条语句都不许执行 —— 旧 SQL 改新数据是单向的损坏
      expect(migrationSteps(DB_VERSION + 1, DB_VERSION).length).assertEqual(0);
      expect(migrationSteps(99, DB_VERSION).length).assertEqual(0);
    });

    it('non_positive_version_is_treated_as_no_schema', 0, () => {
      // 0 与负数都必须和「从 0 开始」走同一条路；-1 是防御性地覆盖「版本号读出异常值」
      expect(migrationSteps(-1, DB_VERSION).length)
        .assertEqual(migrationSteps(0, DB_VERSION).length);
    });

    it('repeated_calls_give_identical_steps', 0, () => {
      // 迁移中途失败后下次启动会整段重跑，同一个入参必须给出同样的结果
      const first: string[] = migrationSteps(0, DB_VERSION);
      const second: string[] = migrationSteps(0, DB_VERSION);
      expect(second.length).assertEqual(first.length);
      for (let i = 0; i < first.length; i++) {
        expect(second[i]).assertEqual(first[i]);
      }
    });

    it('every_step_is_itself_idempotent_sql', 0, () => {
      // 重跑安全的前提：每步 DDL 自身幂等。当前唯一一步是建表，必须带 IF NOT EXISTS。
      const steps: string[] = migrationSteps(0, DB_VERSION);
      for (const sql of steps) {
        expect(sql.indexOf('IF NOT EXISTS') >= 0).assertTrue();
      }
    });

    it('db_version_is_a_positive_integer', 0, () => {
      // .d.ts 对 RdbStore.version 明确写着「must be an integer greater than 0」，
      // 写成 0 会在 store.version = DB_VERSION 那一行运行时报 401
      expect(DB_VERSION > 0).assertTrue();
      expect(Math.floor(DB_VERSION)).assertEqual(DB_VERSION);
    });
  });
}
