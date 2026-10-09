/**
 * NavDestination 的路由名与跳转参数。
 *
 * 参数必须用 class 实例，不能用对象字面量 —— ArkTS 的 arkts-no-untyped-obj-literals
 * 规则会拒绝，因为 NavPathStack 的 param 上下文类型是 unknown/Object。
 */

export const ROUTE_TASK_EDIT: string = 'TaskEdit';
export const ROUTE_TASK_DETAIL: string = 'TaskDetail';

/** 跳转参数只带 id，目标页自己去 DAO 查最新数据，避免在栈上传递会过期的对象快照 */
export class TaskRouteParam {
  taskId: number;

  /**
   * 新任务的创建时间戳；**0 = 用此刻**（沿用 Task 里「时间戳 0 表示未设置」的哨兵约定）。
   *
   * 只有「首页翻到历史日后补记」这一条路会填它，填的是**那一天的本地零点** ——
   * queryByDay 的归档口径是「创建于该日」，零点必然落在 [那天, 次日) 区间内，
   * 任务于是归到那一天。详情页路由复用同一个类，但它永远不读这个字段。
   */
  createTime: number;

  constructor(taskId: number, createTime: number = 0) {
    this.taskId = taskId;
    this.createTime = createTime;
  }
}
