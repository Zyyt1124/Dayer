import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../common/Logger';
import { DB_VERSION, migrationSteps } from './Migration';

const TAG: string = 'DbHelper';
const STORE_NAME: string = 'dayer.db';

/**
 * 数据库句柄的持有者。
 *
 * 缓存的是 **Promise** 而不是 RdbStore 实例：EntryAbility.onCreate 是同步的，
 * 而 getRdbStore 是异步的（getRdbStoreSync 是 @since 24，本工程不能用），
 * 页面可能在初始化完成前就发起查询。缓存 Promise 让所有调用方 await 同一件事，
 * 不会拿到一个还没就绪的空引用。
 */
export class DbHelper {
  private static appContext: common.Context | null = null;
  private static storePromise: Promise<relationalStore.RdbStore> | null = null;

  /** 由 EntryAbility.onCreate 调用，把宿主 Context 交给数据层 */
  static init(context: common.Context): void {
    DbHelper.appContext = context;
  }

  static getStore(): Promise<relationalStore.RdbStore> {
    let pending: Promise<relationalStore.RdbStore> | null = DbHelper.storePromise;
    if (pending === null) {
      pending = DbHelper.open().catch((err: BusinessError) => {
        // 必须重置：否则打开失败后，后续每次调用都会拿到同一个已 rejected 的 Promise
        DbHelper.storePromise = null;
        // 日志已由 open() 的 catch 打出，这里只负责重置与继续上抛
        throw err as Error;
      });
      DbHelper.storePromise = pending;
    }
    return pending;
  }

  private static async open(): Promise<relationalStore.RdbStore> {
    const ctx: common.Context | null = DbHelper.appContext;
    if (ctx === null) {
      throw new Error('DbHelper.init() was not called before use');
    }
    const config: relationalStore.StoreConfig = {
      name: STORE_NAME,
      // 任务内容属于个人隐私数据，放沙箱内，安全等级取最低档即可
      securityLevel: relationalStore.SecurityLevel.S1
    };
    // getRdbStore / executeSql 的 .d.ts 都带 @throws，ArkTS 要求显式处理。
    // 这里不吞异常：记录后原样抛出，交给 getStore 的 catch 重置缓存的 Promise。
    try {
      const store: relationalStore.RdbStore = await relationalStore.getRdbStore(ctx, config);
      await DbHelper.migrate(store);
      Logger.info(TAG, 'rdb store ready');
      return store;
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.error(TAG, `open store failed: ${e.code} ${e.message}`);
      throw e as Error;
    }
  }

  /**
   * 把库结构升到 DB_VERSION。
   *
   * 顺序很重要：**先把所有语句执行完，最后才回写版本号**。
   * 若中途某条失败，版本号还是旧的，下次启动会整段重跑 —— 而每条 SQL 都要求自身幂等
   * （见 Migration.ets），所以重跑是安全的。反过来先写版本号，失败的迁移会被永久跳过，
   * 库就卡在半新半旧的状态上。
   *
   * 版本号读写都在这一个方法里，失败时抛出去由 open() 统一记日志 ——
   * 迁移失败必须让整个数据层起不来，不能带着错误的结构继续跑。
   */
  private static async migrate(store: relationalStore.RdbStore): Promise<void> {
    const from: number = store.version;
    const steps: string[] = migrationSteps(from, DB_VERSION);

    if (steps.length === 0) {
      if (from === DB_VERSION) {
        Logger.info(TAG, `db schema up to date at v${from}`);
      } else {
        // 只会是 from > DB_VERSION：装了旧版 App 覆盖新库。不动数据，也不回写版本号。
        Logger.warn(TAG, `db schema v${from} is newer than v${DB_VERSION}, skip migration`);
      }
      return;
    }

    for (let i = 0; i < steps.length; i++) {
      // executeSql 的 .d.ts 带 @throws，ArkTS 要求就地处理 —— 只让外层 open() 兜住
      // 会报「Function may throw exceptions. Special handling is required.」
      try {
        await store.executeSql(steps[i]);
      } catch (err) {
        // 带上是第几步：只看到一句 SQL 报错，无法判断是哪个版本号的变更出了问题。
        // 这里刻意**不回写版本号**，异常抛给 open()，下次启动整段重跑（每步都幂等）。
        const e: BusinessError = err as BusinessError;
        Logger.error(TAG, `migration step ${i + 1}/${steps.length} failed: ${e.code} ${e.message}`);
        throw e as Error;
      }
    }
    store.version = DB_VERSION;
    Logger.info(TAG, `db schema migrated v${from} -> v${DB_VERSION}, ${steps.length} step(s)`);
  }
}
