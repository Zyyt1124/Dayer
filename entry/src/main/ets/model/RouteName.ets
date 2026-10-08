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

  constructor(taskId: number) {
    this.taskId = taskId;
  }
}
