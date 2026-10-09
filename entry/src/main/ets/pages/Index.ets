import { BusinessError } from '@kit.BasicServicesKit';
import { showToast } from '../common/Feedback';
import { Logger } from '../common/Logger';
import {
  calcDeviation,
  DayRange,
  dayRangeOf,
  formatDate,
  isSameDay,
  shiftDays,
  startOfDay
} from '../common/TimeUtil';
import {
  calcProgress,
  LIVE_TICK_MS,
  mostUrgentRunning,
  ProgressResult,
  ProgressStage
} from '../common/TaskProgress';
import { applyComplete } from '../common/TaskFlow';
import { Task, TaskStatus } from '../model/Task';
import { ROUTE_TASK_DETAIL, ROUTE_TASK_EDIT, TaskRouteParam } from '../model/RouteName';
import { TaskDao } from '../data/TaskDao';
import { TaskListItem } from '../views/TaskListItem';
import { TaskEditPage } from '../views/TaskEditPage';
import { TaskDetailPage } from '../views/TaskDetailPage';

const TAG: string = 'Index';

/**
 * 首页：今日任务列表 + 进行中任务的实时进度卡片。
 *
 * 路由用 Navigation + NavPathStack + NavDestination（SDK 推荐方案），不用 router。
 * pathStack 是**普通成员而不是 @State** —— Navigation 需要的是栈对象本身，
 * 加 @State 只会让整个栈参与无谓的依赖追踪。
 */
@Entry
@Component
struct Index {
  private pathStack: NavPathStack = new NavPathStack();
  @State tasks: Task[] = [];
  /** 首次查询完成前不显示空状态，否则会先闪一下「今天还没有任务」 */
  @State loaded: boolean = false;
  /** 竞态令牌：两次快速刷新会并发两次查询，后返回的未必是最新的 */
  private loadToken: number = 0;

  /**
   * 实时钟。**这里是全页唯一的时间来源**，卡片里所有「已用/还剩」都必须读它。
   *
   * ⚠️ 绝不能在 @Builder 里直接写 `Date.now()`：那样这次渲染就没有读到任何 @State，
   * ArkUI 的依赖追踪断掉，卡片会永久停在首帧。这与 TaskEditPage 上那个
   * `if (this.baseMinutes > 0)` 是同一类 bug —— 当时参考卡片整块不渲染，编译器不报错。
   */
  @State tick: number = 0;

  /**
   * 正在浏览的那一天的**本地零点**。翻到历史上的某天时，这里就是那天的 00:00。
   *
   * 存零点而不是「任意一个该天内的时刻」：让状态本身是规范形式，比较与展示都能直接用，
   * 也避免「同一天的两个不同锚点被当成两天」。
   *
   * ⚠️ 初始化必须晚于 this.tick = Date.now()（见 aboutToAppear）：留 0 的话首次查询
   * 会拿 1970-01-01 去查，首页空白且没有任何报错。
   */
  @State selectedDayStart: number = 0;
  /** 计时器句柄，-1 表示没开。setInterval 返回的 id 从 0 起，所以哨兵不能用 0 */
  private tickerId: number = -1;
  /** 只有页面可见时才允许开表，避免 reload 在页面隐藏后回来又把表点着 */
  private visible: boolean = false;

  /**
   * 已经被用户「知道了」的那条提示，形如 `任务id:阶段:预估分钟`。
   *
   * 只存内存、不落库：重启后再提醒一次是可接受的（任务确实还超着），
   * 而为它加一列 + 写一次迁移不值得。
   *
   * 必须是 @State —— 普通成员的话点「知道了」界面不会刷新，提示不会消失。
   */
  @State ackedKey: string = '';

  aboutToAppear(): void {
    // 先给 tick 一个真实值：留 0 的话首帧 now=0，算出的已用时间是负的（会被夹到 0），
    // 卡片会先闪一下「已用 0 分钟」
    this.tick = Date.now();
    // 顺序不能颠倒：reload 依赖 selectedDayStart 已经指向今天
    this.selectedDayStart = startOfDay(this.tick);
    this.reload();
  }

  aboutToDisappear(): void {
    this.visible = false;
    this.stopTicker();
  }

  /** @Entry 页面才有页面生命周期；计时器只在页面可见时走 */
  onPageShow(): void {
    this.visible = true;
    this.tick = Date.now();
    this.syncTicker();
  }

  onPageHide(): void {
    this.visible = false;
    // 切后台就停表：一个每 30 秒醒一次的定时器在用户看不见的时候只会白耗电
    this.stopTicker();
  }

  // ---------- 日期浏览 ----------

  /**
   * 当前看的是不是今天。
   *
   * ⚠️ 比较对象是 **this.tick**，不是 Date.now()。tick 是全页唯一的时间来源（见它的注释），
   * 在这里另读一次时钟会让「跨零点」这件事在页面的不同位置得出不同答案。
   */
  private isToday(): boolean {
    return isSameDay(this.selectedDayStart, this.tick);
  }

  /** 下一天是否可以翻：不允许翻到未来 */
  private canGoNextDay(): boolean {
    return !this.isToday();
  }

  private goPrevDay(): void {
    this.selectedDayStart = startOfDay(shiftDays(this.selectedDayStart, -1));
    this.reload();
  }

  private goNextDay(): void {
    if (!this.canGoNextDay()) {
      return;
    }
    this.selectedDayStart = startOfDay(shiftDays(this.selectedDayStart, 1));
    this.reload();
  }

  private goToday(): void {
    // 事件回调里读时钟是允许的（约束只针对 build() 与 @Builder）。
    // 这里必须重读：在历史日停留时 ticker 是停的，this.tick 可能已经停在几个小时前，
    // 拿它去算「今天」在跨过零点后会得到昨天。
    this.tick = Date.now();
    this.selectedDayStart = startOfDay(this.tick);
    this.reload();
  }

  private reload(): void {
    const token: number = ++this.loadToken;
    const range: DayRange = dayRangeOf(this.selectedDayStart);
    // 第三个参数只对「今天」为真：未完成的跨天任务不能从今天的列表里消失，
    // 但它们不该出现在任何一个历史日上（否则每一天都会列出全部未完成任务）
    TaskDao.queryByDay(range.start, range.end, this.isToday())
      .then((rows: Task[]) => {
        if (token !== this.loadToken) {
          return;
        }
        this.tasks = rows;
        this.loaded = true;
        // 用户从详情页点「开始」再返回时，进行中的任务是在这次 reload 之后才出现的。
        // 只在 onPageShow 里判断会漏掉这一路，导致卡片要等下次切页面才出来。
        this.syncTicker();
      })
      .catch((err: BusinessError) => {
        if (token !== this.loadToken) {
          return;
        }
        this.loaded = true;
        Logger.error(TAG, `queryByDay failed: ${err.code} ${err.message}`);
        showToast(this.getUIContext(), $r('app.string.toast_load_failed'));
        // 查询失败也必须过一遍表。翻到历史日时若这次查询恰好失败，上面那份
        // 「今天有任务在跑」的旧状态会让定时器继续每 30 秒醒一次。
        // 停表只看 isToday()、不看这次查到的行，所以这里拿旧 tasks 判断是安全的。
        this.syncTicker();
      });
  }

  // ---------- 计时器 ----------

  private hasRunningTask(): boolean {
    for (const task of this.tasks) {
      if (task.status === TaskStatus.IN_PROGRESS) {
        return true;
      }
    }
    return false;
  }

  /**
   * 可见 + 看的是今天 + 有进行中的任务，才该有表在走。任一条件不满足都停表。
   *
   * 历史日必须停表，两个理由：那个每 30 秒醒一次的定时器在回溯场景下只是白耗电；
   * 而且历史日的列表里可能含「那天创建、至今没做完」的任务，让表继续走会给人一种
   * 界面在「实时」跟踪一个过去时刻的错觉 —— 它不是。
   */
  private syncTicker(): void {
    if (this.visible && this.isToday() && this.hasRunningTask()) {
      this.startTicker();
    } else {
      this.stopTicker();
    }
  }

  private startTicker(): void {
    // 幂等。onPageShow 和 reload 都会调到这里，重复开表会丢掉前一个句柄、再也停不掉
    if (this.tickerId !== -1) {
      return;
    }
    this.tickerId = setInterval(() => {
      // 整个 tick 里只做这一件事：不查库、不算偏差结论。
      // 每 30 秒发一次查询既没必要，也会让列表看起来在闪。
      this.tick = Date.now();
    }, LIVE_TICK_MS);
  }

  private stopTicker(): void {
    if (this.tickerId === -1) {
      return;
    }
    clearInterval(this.tickerId);
    // 必须复位成哨兵：留着旧句柄的话下一次 startTicker 会因为「已经开着」直接 return，
    // 表就再也起不来了
    this.tickerId = -1;
  }

  // ---------- 进行中卡片的数据 ----------

  /**
   * 卡片要展示的那一个任务。同时有多个进行中任务时只呈现**最该注意的**那个
   * （已用/预计 比值最大），其余仍在下面的列表里以「进行中」可见。
   */
  private focusTask(): Task | null {
    return mostUrgentRunning(this.tasks, this.tick);
  }

  /** 卡片标题。没有焦点任务时给空串，让渲染路径不需要处理 null */
  private focusTitle(): string {
    const task: Task | null = this.focusTask();
    return task === null ? '' : task.title;
  }

  private focusProgress(): ProgressResult {
    const task: Task | null = this.focusTask();
    if (task === null) {
      return new ProgressResult(ProgressStage.NO_BASELINE, 0, 0, 0);
    }
    return calcProgress(task.estimatedMinutes, task.actualStartTime, this.tick);
  }

  private focusHasBaseline(): boolean {
    return this.focusProgress().stage !== ProgressStage.NO_BASELINE;
  }

  private focusIsOver(): boolean {
    return this.focusProgress().stage === ProgressStage.OVER;
  }

  private focusPercent(): number {
    return this.focusProgress().percent;
  }

  private focusElapsedMinutes(): number {
    return this.focusProgress().elapsedMinutes;
  }

  /** 恒 ≥ 1：距离预估时长还有多少分钟；超时后由 focusOverMinutes 表达 */
  private focusRemainingMinutes(): number {
    return this.focusProgress().remainingMinutes;
  }

  /** 超时多少分钟，恒 ≥ 0 */
  private focusOverMinutes(): number {
    return Math.abs(this.focusProgress().remainingMinutes);
  }

  // ---------- 80% / 100% 纠偏提示 ----------

  /**
   * 提示的身份。空的表示此刻不该有提示。
   *
   * 含 stage：80% 确认过之后，100% 还要再说一次（两个时点是两次独立介入）。
   * 含 estimatedMinutes：用户把预估改大之后要重新武装 —— 否则「15 分钟改成 2 小时」
   * 之后这个任务再也不会提醒，而他恰恰刚表达了「我打算做得更久」。
   */
  private promptKey(): string {
    const task: Task | null = this.focusTask();
    const stage: ProgressStage = this.focusProgress().stage;
    if (task === null) {
      return '';
    }
    if (stage !== ProgressStage.NEAR_LIMIT && stage !== ProgressStage.OVER) {
      return '';
    }
    return `${task.id}:${stage}:${task.estimatedMinutes}`;
  }

  private promptVisible(): boolean {
    const key: string = this.promptKey();
    return key.length > 0 && key !== this.ackedKey;
  }

  private promptText(): Resource {
    return this.focusIsOver()
      ? $r('app.string.progress_prompt_over')
      : $r('app.string.progress_prompt_near');
  }

  private promptColor(): Resource {
    return this.focusIsOver() ? $r('app.color.deviation_over') : $r('app.color.accent');
  }

  private acknowledgePrompt(): void {
    this.ackedKey = this.promptKey();
  }

  // ---------- 卡片上的动作 ----------

  private openFocusDetail(): void {
    const task: Task | null = this.focusTask();
    if (task !== null) {
      this.openDetail(task.id);
    }
  }

  /**
   * 卡片上直接完成。
   *
   * ⚠️ 这里刻意**没有**「改成 X 分钟」这类按钮。那等于让我们替用户改写他填的
   * estimatedMinutes，而「预估 vs 实际」的落差是这个应用唯一的学习信号 ——
   * 抹掉它，估时校准就成了空转。想改预估请用户自己进详情页/编辑页改，
   * 那是他的判断，不是我们替他抹账。
   */
  private completeFocusTask(): void {
    const task: Task | null = this.focusTask();
    if (task === null) {
      return;
    }
    // 守卫在 TaskFlow 里：已完成的任务返回 false，不落库也不刷新，
    // 避免「连点两下把结束时间推后」这类静默错误
    if (!applyComplete(task, Date.now())) {
      return;
    }
    TaskDao.update(task)
      .then(() => {
        this.reload();
      })
      .catch((err: BusinessError) => {
        Logger.error(TAG, `complete task ${task.id} failed: ${err.code} ${err.message}`);
        showToast(this.getUIContext(), $r('app.string.toast_save_failed'));
        // 失败时刚才那次内存改动必须撤回。reload 会用库里的真值整体替换 this.tasks，
        // 否则界面显示「已完成」、库里还是「进行中」，用户下次进来才发现它变回去了。
        this.reload();
      });
  }

  /**
   * ForEach 的 key 必须由**被渲染的字段**派生，只用 id 会因行复用而不刷新。
   * 代价是任意字段变化都会重建该行 —— 本期编辑都在独立页面，无害；
   * 但这也意味着日后不能加行内标题编辑（每次按键都会重建并丢焦点）。
   *
   * 注意这里**不能**把 this.tick 拼进来：那会让每次计时跳动都重建全部列表行，
   * 而实时数字本来就只在卡片里显示（卡片在 ForEach 之外，自己读 tick）。
   */
  private keyOf(task: Task): string {
    return `${task.id}:${task.status}:${task.title}:${task.estimatedMinutes}:${task.priority}:`
      + `${task.actualStartTime}:${task.actualEndTime}:${task.deadline}`;
  }

  private openDetail(taskId: number): void {
    this.pathStack.pushPathByName(ROUTE_TASK_DETAIL, new TaskRouteParam(taskId));
  }

  private openNewTask(): void {
    // taskId = 0 表示新建
    this.pathStack.pushPathByName(ROUTE_TASK_EDIT, new TaskRouteParam(0));
  }

  /**
   * 路由表。每个分支必须只有一个根节点，且**不能给这些自定义组件挂任何属性或事件**
   * （官方 navDestination 文档：否则只会显示空白内容）。
   *
   * param 声明成 TaskRouteParam 而不是 unknown：ArkTS 的 arkts-no-any-unknown 规则
   * 禁止在代码里出现 unknown，而 navDestination 的文档明确说明「unknown 可以替换成
   * 用户自定义类型」，所以这里直接用具体类型。instanceof 守卫保留 —— 声明类型不影响
   * 运行时判断，万一有别的调用方传了别的参数，宁可什么都不渲染也不要崩。
   *
   * 刷新机制刻意不用 NavPathStack 的 onPop 回调：它只在 pop(result) 带结果时触发，
   * 系统返回手势调的是无参 pop()，会静默漏刷新。改为把回调作为组件构造参数直接传给目标页，
   * 这样任何退出路径都能刷新，也不需要 @State/@Prop/@Link/@Watch 之外的装饰器。
   */
  @Builder
  PageMap(name: string, param: TaskRouteParam) {
    if (name === ROUTE_TASK_EDIT && param instanceof TaskRouteParam) {
      TaskEditPage({
        taskId: param.taskId,
        pathStack: this.pathStack,
        onChanged: () => {
          this.reload();
        }
      })
    } else if (name === ROUTE_TASK_DETAIL && param instanceof TaskRouteParam) {
      TaskDetailPage({
        taskId: param.taskId,
        pathStack: this.pathStack,
        onChanged: () => {
          this.reload();
        }
      })
    }
  }

  /**
   * 空状态。文案按「今天 / 历史日」分支 —— 历史日说「今天还没有任务」是直接说错话。
   * 历史日也不显示「新建一个任务…」那句引导：在回溯场景下劝人新建毫无意义。
   *
   * ⚠️ 无参数 @Builder，在函数体里读 this.isToday()（理由见 RunningCard 的注释）
   */
  @Builder
  EmptyState() {
    Column() {
      Text(this.isToday() ? $r('app.string.home_empty') : $r('app.string.history_empty'))
        .fontSize($r('app.float.font_subtitle'))
        .fontColor($r('app.color.text_secondary'))
        .margin({ bottom: $r('app.float.spacing_small') })
      if (this.isToday()) {
        Text($r('app.string.home_empty_hint'))
          .fontSize($r('app.float.font_caption'))
          .fontColor($r('app.color.text_tertiary'))
          .textAlign(TextAlign.Center)
      }
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /** 日期条中间那行字：今天说「今日」，其余日子给 YYYY-MM-DD */
  private dayLabel(): ResourceStr {
    return this.isToday() ? $r('app.string.home_title') : formatDate(this.selectedDayStart);
  }

  /**
   * 顶部日期切换条，挂在 Navigation 的 title 区（.title 收 CustomBuilder，@since 8）。
   *
   * 它取代了写死的 .title($r('app.string.home_title'))：标题写死「今日」的话，
   * 翻到历史日会明目张胆地说错话。
   *
   * ⚠️ 无参数 @Builder。带参数会按值传递，翻日期时这里不会重绘 —— 症状是列表变了、
   * 日期标签却停在原处（本项目在 TaskDetailPage.MetricColumn 上吃过一次同类亏）。
   * ⚠️ 间距只用 .margin()/.padding()：Row/Column 的 space 收不了 $r() 资源。
   */
  @Builder
  DaySwitcher() {
    Row() {
      Text($r('app.string.day_prev'))
        .fontSize($r('app.float.font_title'))
        .fontColor($r('app.color.accent'))
        .padding({ left: $r('app.float.spacing_medium'), right: $r('app.float.spacing_medium') })
        .onClick(() => {
          this.goPrevDay();
        })

      Column() {
        Text(this.dayLabel())
          .fontSize($r('app.float.font_subtitle'))
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
        if (!this.isToday()) {
          Text($r('app.string.action_back_to_today'))
            .fontSize($r('app.float.font_small'))
            .fontColor($r('app.color.accent'))
            .margin({ top: $r('app.float.spacing_xsmall') })
            .onClick(() => {
              this.goToday();
            })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Center)

      // 未来不可翻：今天时这个箭头置灰且不可点
      Text($r('app.string.day_next'))
        .fontSize($r('app.float.font_title'))
        .fontColor(this.canGoNextDay() ? $r('app.color.accent') : $r('app.color.text_tertiary'))
        .padding({ left: $r('app.float.spacing_medium'), right: $r('app.float.spacing_medium') })
        .enabled(this.canGoNextDay())
        .onClick(() => {
          this.goNextDay();
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  /**
   * 进行中任务的实时卡片。
   *
   * ⚠️ 无参数的 @Builder，理由见 TaskDetailPage.MetricRow 上方那段注释：
   * 带参数的 @Builder 按值传递，状态变化不会引起内部重绘。
   *
   * ⚠️ 必须挂在 ForEach **之外**。列表行 TaskListItem 收的是 @Prop 基本类型，
   * 而 ForEach 的 key 由渲染字段派生 —— 一个只变了 this.tick 的标量刷新，
   * 依赖追踪不会经过那些 key 没变的行，新的分钟数推不进去。
   * 卡片直接挂在 Column 下、自己读 this.tick，才能每跳一次就重绘。
   */
  @Builder
  RunningCard() {
    Column() {
      // 可点区只包内容。下面那块提示与按钮刻意做成它的**兄弟节点**而不是子节点：
      // ArkUI 的点击事件会不会冒泡到祖先节点我不想凭记忆下注，
      // 结构上错开就完全不用赌，也不会出现「点完成顺手跳进详情页」。
      Column() {
        Row() {
          Text($r('app.string.status_in_progress'))
            .fontSize($r('app.float.font_small'))
            .fontColor($r('app.color.accent'))
            .backgroundColor($r('app.color.tag_background'))
            .borderRadius($r('app.float.radius_tag'))
            .padding({
              left: $r('app.float.spacing_small'),
              right: $r('app.float.spacing_small'),
              top: $r('app.float.spacing_xsmall'),
              bottom: $r('app.float.spacing_xsmall')
            })
            .margin({ right: $r('app.float.spacing_small') })

          Text(this.focusTitle())
            .fontSize($r('app.float.font_body'))
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        // 没点开始或没填预估就算不出进度。这时只显示标题，不画进度条 ——
        // 画一条恒为 0 的条比不画更糟：用户会读成「一点没动」，
        // 而事实是「这个任务算不出进度」，两者该说的话不一样。
        if (this.focusHasBaseline()) {
          Progress({ value: this.focusPercent(), total: 100, type: ProgressType.Linear })
            .color(this.focusIsOver() ? $r('app.color.deviation_over') : $r('app.color.accent'))
            .backgroundColor($r('app.color.tag_background'))
            .width('100%')
            .margin({ top: $r('app.float.spacing_medium') })

          Row() {
            Text($r('app.string.progress_elapsed', this.focusElapsedMinutes()))
              .fontSize($r('app.float.font_small'))
              .fontColor($r('app.color.text_secondary'))
              .margin({ right: $r('app.float.spacing_medium') })

            // 超时后不再说「还剩负数分钟」，换成正着说的「已超出」
            if (this.focusIsOver()) {
              Text($r('app.string.progress_over', this.focusOverMinutes()))
                .fontSize($r('app.float.font_small'))
                .fontColor($r('app.color.deviation_over'))
            } else {
              Text($r('app.string.progress_remaining', this.focusRemainingMinutes()))
                .fontSize($r('app.float.font_small'))
                .fontColor($r('app.color.text_secondary'))
            }
          }
          .width('100%')
          .margin({ top: $r('app.float.spacing_small') })
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .onClick(() => {
        this.openFocusDetail();
      })

      if (this.promptVisible()) {
        Text(this.promptText())
          .fontSize($r('app.float.font_caption'))
          .fontColor(this.promptColor())
          .width('100%')
          .margin({ top: $r('app.float.spacing_medium') })

        Row() {
          Button($r('app.string.action_complete'))
            .layoutWeight(1)
            .height($r('app.float.height_button'))
            .margin({ right: $r('app.float.spacing_medium') })
            .onClick(() => {
              this.completeFocusTask();
            })

          // 「知道了」只是把这条提示收起来，不动任何数据 —— 用户还在做，只是不想被念
          Button($r('app.string.progress_ack'))
            .layoutWeight(1)
            .height($r('app.float.height_button'))
            .backgroundColor($r('app.color.tag_background'))
            .fontColor($r('app.color.text_primary'))
            .onClick(() => {
              this.acknowledgePrompt();
            })
        }
        .width('100%')
        .margin({ top: $r('app.float.spacing_medium') })
      }
    }
    .width('100%')
    .padding($r('app.float.spacing_large'))
    .backgroundColor($r('app.color.card_background'))
    .borderRadius($r('app.float.radius_card'))
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: $r('app.float.spacing_medium') })
  }

  build() {
    Navigation(this.pathStack) {
      Column() {
        // 进行中的任务排在最上面：它是此刻唯一还在变化的东西。
        // 只在今天显示 —— 历史日的列表里完全可能含「那天创建、至今没做完」的任务，
        // 而「已用/还剩」是此刻的进度，把它贴到一个过去的日子上就是在编造历史。
        if (this.isToday() && this.focusTask() !== null) {
          this.RunningCard()
        }

        if (this.loaded && this.tasks.length === 0) {
          this.EmptyState()
        } else {
          List() {
            ForEach(this.tasks, (task: Task) => {
              ListItem() {
                TaskListItem({
                  title: task.title,
                  status: task.status,
                  estimatedMinutes: task.estimatedMinutes,
                  priority: task.priority,
                  completedLate: task.isCompletedLate(),
                  deviationKind: calcDeviation(task.estimatedMinutes, task.actualStartTime, task.actualEndTime).kind,
                  diffMinutes: calcDeviation(task.estimatedMinutes, task.actualStartTime, task.actualEndTime).diffMinutes
                })
              }
              .margin({ bottom: $r('app.float.spacing_medium') })
              .onClick(() => {
                this.openDetail(task.id);
              })
            }, (task: Task) => this.keyOf(task))
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
        }

        // 新建只在今天给。历史日点它，新任务的创建时间是此刻，不会出现在正在浏览的那一天 ——
        // 一个按钮做完事却在别处生效，比干脆不显示更让人困惑。
        if (this.isToday()) {
          Button($r('app.string.action_new_task'))
            .width('100%')
            .height($r('app.float.height_button'))
            .margin({ top: $r('app.float.spacing_medium') })
            .onClick(() => {
              this.openNewTask();
            })
        }
      }
      .width('100%')
      .height('100%')
      .padding($r('app.float.spacing_large'))
      .backgroundColor($r('app.color.page_background'))
    }
    .title(this.DaySwitcher)
    .navDestination(this.PageMap)
  }
}
