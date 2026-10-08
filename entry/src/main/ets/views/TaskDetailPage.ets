import { BusinessError } from '@kit.BasicServicesKit';
import { confirmDialog, showToast } from '../common/Feedback';
import { Logger } from '../common/Logger';
import { calcDeviation, DeviationKind, DeviationResult, formatDate } from '../common/TimeUtil';
import {
  calcProgress,
  LIVE_TICK_MS,
  ProgressResult,
  ProgressStage
} from '../common/TaskProgress';
import { applyComplete, applyMarkUnfinished, applySetActualDuration, applyStart, applyUndoComplete } from '../common/TaskFlow';
import { deviationColor, deviationLabelText, durationText, statusText, QUICK_MINUTES } from '../model/TaskConstants';
import { Task, TaskStatus } from '../model/Task';
import { ROUTE_TASK_EDIT, TaskRouteParam } from '../model/RouteName';
import { TaskDao } from '../data/TaskDao';

const TAG: string = 'TaskDetailPage';

/**
 * 任务详情页：状态流转 + 预估/实际/偏差对照。
 *
 * 展示用的字段都放在独立的 @State 基本类型里，而不是直接绑 this.task 的字段 ——
 * @State 只观测到「对象被整体替换」这一层，直接改 task.status 不会触发重绘。
 * 每次改动后调用 syncFromTask() 把 Task 的状态同步回 @State。
 *
 * 间距一律用 .margin()：Row/Column 的 space 参数类型是 string | number，收不了 $r() 资源。
 */
@Component
export struct TaskDetailPage {
  taskId: number = 0;
  pathStack: NavPathStack = new NavPathStack();
  /** 状态或数据变化后通知父页刷新列表 */
  onChanged: () => void = () => {};

  /** 真实数据。普通成员，不作为渲染依据，渲染一律读下面那组 @State */
  private task: Task = new Task();

  @State titleText: string = '';
  @State status: number = TaskStatus.NOT_STARTED;
  @State estimatedMinutes: number = 0;
  @State actualStartTime: number = 0;
  @State actualEndTime: number = 0;
  @State createTime: number = 0;
  @State completedLate: boolean = false;
  @State deviationReason: string = '';
  /** 偏差原因有未保存的改动时才显示保存按钮 */
  @State reasonDirty: boolean = false;
  /** 补记实际用时的输入框原始文本，保存时才解析 */
  @State actualMinutesText: string = '';

  /**
   * 实时钟。正在计时的任务「实际耗时」是「到现在为止」，必须由它驱动。
   *
   * ⚠️ 与首页同一个规矩：**这里是本页唯一的时间来源**，@Builder 里绝不能直接写
   * `Date.now()` —— 那样这次渲染读不到任何 @State，依赖追踪断掉，分钟数会停在首帧。
   */
  @State now: number = 0;
  /** 计时器句柄，-1 表示没开（setInterval 的 id 从 0 起） */
  private tickerId: number = -1;

  aboutToAppear(): void {
    this.now = Date.now();
    this.load();
  }

  aboutToDisappear(): void {
    this.stopLiveTick();
  }

  // NavDestination 没有 onPageShow/onPageHide，用 onWillShow/onWillHide
  // （@since 12，Callback<void>）。刻意不用 onShown/onHidden：它们的回调参数类型
  // VisibilityChangeReason 的枚举成员是 @since 21，超出本工程的 API 15。

  private startLiveTick(): void {
    // 幂等：onWillShow 每次进来都调，重复开表会丢掉前一个句柄、再也停不掉
    if (this.tickerId !== -1) {
      return;
    }
    // 只有正在计时的任务才需要每 30 秒重算一次
    if (!this.isRunning()) {
      return;
    }
    this.tickerId = setInterval(() => {
      this.now = Date.now();
    }, LIVE_TICK_MS);
  }

  private stopLiveTick(): void {
    if (this.tickerId === -1) {
      return;
    }
    clearInterval(this.tickerId);
    // 复位成哨兵，否则下一次 startLiveTick 会因为「已经开着」直接 return，表再也起不来
    this.tickerId = -1;
  }

  /** 状态变了（点开始/完成/撤销）之后要重新判断该不该有表在走 */
  private syncLiveTick(): void {
    if (this.isRunning()) {
      this.startLiveTick();
    } else {
      this.stopLiveTick();
    }
  }

  /**
   * 从编辑页返回时也要重新拉一次：编辑页是通过 PageMap 构造的，
   * 它的 onChanged 只回调到首页，传不到本页，所以本页用「每次显示都自查」来兜底。
   */
  private load(): void {
    TaskDao.queryById(this.taskId)
      .then((task: Task | null) => {
        if (task === null) {
          Logger.warn(TAG, `task ${this.taskId} not found`);
          return;
        }
        this.task = task;
        this.syncFromTask();
        // 从库里读回的状态才是真的：可能这次进来它已经是「已完成」了
        this.syncLiveTick();
      })
      .catch((err: BusinessError) => {
        Logger.error(TAG, `load task ${this.taskId} failed: ${err.code} ${err.message}`);
        showToast(this.getUIContext(), $r('app.string.toast_load_failed'));
      });
  }

  private syncFromTask(): void {
    // 每次同步数据都重新对一次钟：从后台回来时 now 可能已经是几分钟前的值了
    this.now = Date.now();
    this.titleText = this.task.title;
    this.status = this.task.status;
    this.estimatedMinutes = this.task.estimatedMinutes;
    this.actualStartTime = this.task.actualStartTime;
    this.actualEndTime = this.task.actualEndTime;
    this.createTime = this.task.createTime;
    this.completedLate = this.task.isCompletedLate();
    this.deviationReason = this.task.deviationReason;
    this.reasonDirty = false;
    // 已有计时数据就把当前值填进补记框，用户要改就是在原值上改
    this.actualMinutesText = this.hasDeviationNumber()
      ? this.deviation().actualMinutes.toString()
      : '';
  }

  private deviation(): DeviationResult {
    return calcDeviation(this.estimatedMinutes, this.actualStartTime, this.actualEndTime);
  }

  /** 只有算出真实耗时的三种结论才带数字 */
  private hasDeviationNumber(): boolean {
    const kind: DeviationKind = this.deviation().kind;
    return kind === DeviationKind.ACCURATE || kind === DeviationKind.OVER || kind === DeviationKind.UNDER;
  }

  /**
   * 正在计时：点过开始、还没结束。
   *
   * 这一段此前是错的：`calcDeviation` 在 actualEndTime 为 0 时返回 NO_TIMING_DATA，
   * 于是一个已经跑了 20 分钟的任务在详情页显示「未记录计时」，与事实相反。
   */
  private isRunning(): boolean {
    return this.status === TaskStatus.IN_PROGRESS && this.actualStartTime > 0;
  }

  private liveProgress(): ProgressResult {
    return calcProgress(this.estimatedMinutes, this.actualStartTime, this.now);
  }

  /**
   * 第二栏的表头。计时中写「已用」而不是「实际耗时」—— 后者听着像最终值，
   * 而此刻它只是「到目前为止」，任务可能还要再跑一小时。
   */
  private actualColumnLabel(): Resource {
    return this.isRunning()
      ? $r('app.string.label_progress_elapsed')
      : $r('app.string.label_actual_time');
  }

  /** 第二栏的数值。计时中是已用时长，结束后才是实际耗时或结论 */
  private actualColumnText(): Resource {
    if (this.isRunning()) {
      return durationText(this.liveProgress().elapsedMinutes);
    }
    return this.hasDeviationNumber()
      ? durationText(this.deviation().actualMinutes)
      : deviationLabelText(this.deviation().kind);
  }

  /**
   * 第三栏的表头。计时中还没有结论可说，所以这一栏说的是进度而不是「偏差」；
   * 「还剩 / 已超出」本身就把方向说清楚了，数值只放时长。
   *
   * 表头承载文案、数值只放时长，是为了不让三栏中的任何一栏折行：
   * 这里曾经把整句「已用 13 分钟」塞进第二栏，三栏各占 1/3 宽度，
   * 它比相邻两栏多出一个数字的宽度，于是「分钟」两个字被拆到第二行。
   */
  private deviationColumnLabel(): Resource {
    if (!this.isRunning()) {
      return $r('app.string.label_deviation');
    }
    return this.liveProgress().stage === ProgressStage.OVER
      ? $r('app.string.label_progress_over')
      : $r('app.string.label_progress_remaining');
  }

  /** 第三栏的数值。计时中是剩余/超出时长（方向由表头给出），结束后才是偏差数字或结论 */
  private deviationColumnText(): Resource {
    if (this.isRunning()) {
      const progress: ProgressResult = this.liveProgress();
      return progress.stage === ProgressStage.OVER
        ? durationText(Math.abs(progress.remainingMinutes))
        : durationText(progress.remainingMinutes);
    }
    return this.hasDeviationNumber()
      ? durationText(Math.abs(this.deviation().diffMinutes))
      : deviationLabelText(this.deviation().kind);
  }

  private deviationColumnColor(): Resource {
    if (this.isRunning()) {
      // 计时中不是好坏评价，超时了才转暖色
      return this.liveProgress().stage === ProgressStage.OVER
        ? $r('app.color.deviation_over')
        : $r('app.color.accent');
    }
    return deviationColor(this.deviation().kind);
  }

  private isSettled(): boolean {
    return this.status === TaskStatus.COMPLETED || this.status === TaskStatus.UNFINISHED;
  }

  private persist(): void {
    TaskDao.update(this.task)
      .then(() => {
        this.syncFromTask();
        // 完成之后表就该停了，别让一个已经结束的任务继续每 30 秒重算一次
        this.syncLiveTick();
        this.onChanged();
      })
      .catch((err: BusinessError) => {
        Logger.error(TAG, `update task ${this.taskId} failed: ${err.code} ${err.message}`);
        showToast(this.getUIContext(), $r('app.string.toast_save_failed'));
      });
  }

  // 状态流转的守卫都在 TaskFlow 里：函数返回 false 表示这次点击是无效的重复操作，
  // 不落库、不刷新，避免「点两下把开始时间推后」这类静默错误。
  private onStart(): void {
    if (applyStart(this.task, Date.now())) {
      this.persist();
    }
  }

  private onComplete(): void {
    if (applyComplete(this.task, Date.now())) {
      this.persist();
    }
  }

  private onUndoComplete(): void {
    if (applyUndoComplete(this.task)) {
      this.persist();
    }
  }

  private onMarkUnfinished(): void {
    if (applyMarkUnfinished(this.task, Date.now())) {
      this.persist();
    }
  }

  private onSaveReason(): void {
    this.task.deviationReason = this.deviationReason;
    this.persist();
  }

  /** 与编辑页 parseMinutes 同一套规则：非法输入一律归 0，由校验统一拦下 */
  private parseActualMinutes(): number {
    if (this.actualMinutesText.length === 0) {
      return 0;
    }
    const parsed: number = Number.parseInt(this.actualMinutesText, 10);
    return Number.isNaN(parsed) ? 0 : parsed;
  }

  /**
   * 补记实际用时。
   * 用户忘了点「开始」时，这是他唯一能贡献样本的入口 —— 没有样本，
   * 「你这类任务通常是预估的几倍」就永远算不出来。
   */
  private onSaveActualMinutes(): void {
    const minutes: number = this.parseActualMinutes();
    if (minutes <= 0) {
      showToast(this.getUIContext(), $r('app.string.error_actual_invalid'));
      return;
    }
    if (applySetActualDuration(this.task, minutes)) {
      this.persist();
    }
  }

  private onEdit(): void {
    this.pathStack.pushPathByName(ROUTE_TASK_EDIT, new TaskRouteParam(this.taskId));
  }

  private onDelete(): void {
    confirmDialog(this.getUIContext(),
      $r('app.string.dialog_delete_title'),
      $r('app.string.dialog_delete_message'),
      $r('app.string.dialog_confirm'),
      $r('app.string.dialog_cancel'),
      () => {
        this.doDelete();
      });
  }

  private doDelete(): void {
    TaskDao.remove(this.taskId)
      .then(() => {
        this.onChanged();
        this.pathStack.pop();
      })
      .catch((err: BusinessError) => {
        Logger.error(TAG, `delete task ${this.taskId} failed: ${err.code} ${err.message}`);
        showToast(this.getUIContext(), $r('app.string.toast_delete_failed'));
      });
  }

  /**
   * 核心对照区：预计 / 实际 / 偏差。
   *
   * ⚠️ 刻意写成**无参数**的 @Builder，所有值都在内部直接读 this.*。
   * 带参数的 @Builder 默认按值传递，状态变量变化**不会**引起其内部重绘 ——
   * 官方《@Builder装饰器：自定义构建函数》原文：「当传递的参数为状态变量时，
   * 状态变量的改变不会引起@Builder方法内的UI刷新」，只有「单参数 + 对象字面量」
   * 的按引用传递才刷新。此前写成 MetricColumn(label, value, color) 三个参数，
   * 整块卡片便永久停在首帧：同一份 deviation() 在两处给出互相排斥的结论 ——
   * 卡片第三栏显示「未记录计时」，紧邻其下直接渲染的那行却显示「节省」。
   * 官方对这类场景的建议就是「通过 this 访问组件的状态变量，而不是通过参数传递」。
   *
   * 本卡片有两种形态：任务结束后是「预计 / 实际 / 偏差」三个结论；**正在计时**时是
   * 「预计 / 已用 / 当前进度」+ 进度条。后者此前显示的是「未记录计时」——
   * calcDeviation 在 actualEndTime 为 0 时确实无话可说，但那个位置恰恰是事实的反面：
   * 一个已经跑了 20 分钟的任务被写成「没计时」。
   */
  @Builder
  MetricRow() {
    Column() {
      Row() {
        Column() {
          Text($r('app.string.label_estimated_time'))
            .fontSize($r('app.float.font_small'))
            .fontColor($r('app.color.text_tertiary'))
            .margin({ bottom: $r('app.float.spacing_xsmall') })
          // 三栏都只占 1/3 宽，值却是「未记录计时」这样的 5 个字，18fp 下放不进一行。
          // 用自适应字号而不是 maxLines(2)：折行会让这一格变成两行高，三栏的表头就不在同一条
          // 基线上（实测中间那栏折行后，左右两个表头看起来一个偏上一个偏下）。
          // 官方 @since 7 的 minFontSize / maxFontSize：与 maxLines 搭配使用时按需缩小，
          // 默认策略 TextHeightAdaptivePolicy.MAX_LINES_FIRST 正是「装不下就缩」。
          // ⚠️ 自适应生效时 fontSize 会被忽略，所以这里刻意不写 .fontSize()，
          // 而是把 font_subtitle 作为 maxFontSize 传入 —— 短值时大小与其它栏完全一致。
          Text(durationText(this.estimatedMinutes))
            .maxLines(1)
            .minFontSize($r('app.float.font_small'))
            .maxFontSize($r('app.float.font_subtitle'))
            .fontColor($r('app.color.text_primary'))
            .textAlign(TextAlign.Center)
        }
        .alignItems(HorizontalAlign.Center)
        .layoutWeight(1)
        .margin({ right: $r('app.float.spacing_medium') })

        Column() {
          Text(this.actualColumnLabel())
            .fontSize($r('app.float.font_small'))
            .fontColor($r('app.color.text_tertiary'))
            .margin({ bottom: $r('app.float.spacing_xsmall') })
          Text(this.actualColumnText())
            .maxLines(1)
            .minFontSize($r('app.float.font_small'))
            .maxFontSize($r('app.float.font_subtitle'))
            .fontColor($r('app.color.text_primary'))
            .textAlign(TextAlign.Center)
        }
        .alignItems(HorizontalAlign.Center)
        .layoutWeight(1)
        .margin({ right: $r('app.float.spacing_medium') })

        Column() {
          // 计时中这一栏说的不是「偏差」（还没有结论），而是「还剩 / 已超出」，
          // 表头必须跟着换 —— 否则「预估偏差：还剩 3 分钟」是两件事混在一起
          Text(this.deviationColumnLabel())
            .fontSize($r('app.float.font_small'))
            .fontColor($r('app.color.text_tertiary'))
            .margin({ bottom: $r('app.float.spacing_xsmall') })
          Text(this.deviationColumnText())
            .maxLines(1)
            .minFontSize($r('app.float.font_small'))
            .maxFontSize($r('app.float.font_subtitle'))
            .fontColor(this.deviationColumnColor())
            .textAlign(TextAlign.Center)
        }
        .alignItems(HorizontalAlign.Center)
        .layoutWeight(1)
      }
      .width('100%')

      // 计时中把「已用 / 预计」画成条。三栏数字要一个个读，条形是一眼就能看出还剩多少，
      // 而这一屏最该被一眼看到的恰恰就是「还剩多少」。
      if (this.isRunning()) {
        Progress({ value: this.liveProgress().percent, total: 100, type: ProgressType.Linear })
          .color(this.deviationColumnColor())
          .backgroundColor($r('app.color.tag_background'))
          .width('100%')
          .margin({ top: $r('app.float.spacing_large') })
      }
    }
    .width('100%')
    .padding($r('app.float.spacing_large'))
    .backgroundColor($r('app.color.card_background'))
    .borderRadius($r('app.float.radius_card'))
    .margin({ bottom: $r('app.float.spacing_large') })
  }

  /**
   * 补记实际用时。
   *
   * 同样是无参数的 @Builder（理由见 MetricRow 上方那段注释）。
   * 只在任务已结束（完成/未完成）时渲染 —— 还在进行中的任务，实际用时是「到现在为止」，
   * 那个数由实际的开始/结束时间戳算，不该让用户手填一个会立刻过期的值。
   */
  @Builder
  ActualDurationCard() {
    Column() {
      Text($r('app.string.label_actual_input'))
        .fontSize($r('app.float.font_caption'))
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .margin({ bottom: $r('app.float.spacing_small') })

      TextInput({ text: this.actualMinutesText, placeholder: $r('app.string.placeholder_actual_input') })
        .type(InputType.Number)
        .maxLength(4)
        .height($r('app.float.height_input'))
        .onChange((value: string) => {
          this.actualMinutesText = value;
        })

      // Flex + Wrap：六个选项一行放不下，Row 会把最后两个挤出屏幕
      // （实测「1小时30分钟」贴到右边缘、「2小时」完全不可见）
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(QUICK_MINUTES, (item: number) => {
          Text(durationText(item))
            .fontSize($r('app.float.font_small'))
            .fontColor($r('app.color.text_secondary'))
            // tag_background 而不是 card_background：本卡片自身就是 card_background（#FFFFFF），
            // 同色相叠等于没有底色，按钮会退化成一行散字，看不出可点
            .backgroundColor($r('app.color.tag_background'))
            .borderRadius($r('app.float.radius_tag'))
            .padding({
              left: $r('app.float.spacing_small'),
              right: $r('app.float.spacing_small'),
              top: $r('app.float.spacing_xsmall'),
              bottom: $r('app.float.spacing_xsmall')
            })
            .margin({
              right: $r('app.float.spacing_small'),
              bottom: $r('app.float.spacing_xsmall')
            })
            .onClick(() => {
              this.actualMinutesText = item.toString();
            })
        }, (item: number) => `actual-quick-${item}`)
      }
      .width('100%')
      .margin({ top: $r('app.float.spacing_small') })

      // 已经有计时数据时这句话就不成立了，只在「未记录计时」时提示
      if (this.actualStartTime <= 0) {
        Text($r('app.string.hint_actual_input'))
          .fontSize($r('app.float.font_small'))
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
          .margin({ top: $r('app.float.spacing_small') })
      }

      Button($r('app.string.action_apply_actual'))
        .width('100%')
        .height($r('app.float.height_button'))
        .margin({ top: $r('app.float.spacing_medium') })
        .onClick(() => {
          this.onSaveActualMinutes();
        })
    }
    .width('100%')
    .padding($r('app.float.spacing_large'))
    .backgroundColor($r('app.color.card_background'))
    .borderRadius($r('app.float.radius_card'))
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: $r('app.float.spacing_large') })
  }

  build() {
    NavDestination() {
      Scroll() {
        Column() {

          Column() {
            Text(this.titleText)
              .fontSize($r('app.float.font_title'))
              .fontColor($r('app.color.text_primary'))
              .width('100%')
              .margin({ bottom: $r('app.float.spacing_small') })

            Row() {
              Text(statusText(this.status))
                .fontSize($r('app.float.font_small'))
                .fontColor($r('app.color.text_secondary'))
                .backgroundColor($r('app.color.tag_background'))
                .borderRadius($r('app.float.radius_tag'))
                .padding({
                  left: $r('app.float.spacing_small'),
                  right: $r('app.float.spacing_small'),
                  top: $r('app.float.spacing_xsmall'),
                  bottom: $r('app.float.spacing_xsmall')
                })
                .margin({ right: $r('app.float.spacing_small') })

              if (this.completedLate) {
                Text($r('app.string.badge_completed_late'))
                  .fontSize($r('app.float.font_small'))
                  .fontColor($r('app.color.deviation_over'))
                  .backgroundColor($r('app.color.tag_background'))
                  .borderRadius($r('app.float.radius_tag'))
                  .padding({
                    left: $r('app.float.spacing_small'),
                    right: $r('app.float.spacing_small'),
                    top: $r('app.float.spacing_xsmall'),
                    bottom: $r('app.float.spacing_xsmall')
                  })
              }
            }
            .width('100%')
          }
          .width('100%')
          .padding($r('app.float.spacing_large'))
          .backgroundColor($r('app.color.card_background'))
          .borderRadius($r('app.float.radius_card'))
          .alignItems(HorizontalAlign.Start)
          .margin({ bottom: $r('app.float.spacing_large') })

          // 核心对照区：预计 / 实际 / 偏差
          this.MetricRow()

          if (this.isSettled()) {
            Text(deviationLabelText(this.deviation().kind))
              .fontSize($r('app.float.font_caption'))
              .fontColor(deviationColor(this.deviation().kind))
              .width('100%')
              .margin({ bottom: $r('app.float.spacing_large') })

            // 补记卡紧跟在对照区下方：填完立刻能看到三栏数字随之变化，
            // 因果关系放在同一屏里才看得出
            this.ActualDurationCard()
          }

          // 偏差原因：事后复盘时最有价值的一栏
          Column() {
            Row() {
              Text($r('app.string.label_deviation_reason'))
                .fontSize($r('app.float.font_caption'))
                .fontColor($r('app.color.text_secondary'))
                .layoutWeight(1)
                .textAlign(TextAlign.Start)

              if (this.reasonDirty) {
                Text($r('app.string.action_save'))
                  .fontSize($r('app.float.font_caption'))
                  .fontColor($r('app.color.accent'))
                  .onClick(() => {
                    this.onSaveReason();
                  })
              }
            }
            .width('100%')
            .margin({ bottom: $r('app.float.spacing_small') })

            TextArea({ text: this.deviationReason, placeholder: $r('app.string.placeholder_deviation_reason') })
              .height($r('app.float.height_textarea'))
              .onChange((value: string) => {
                this.deviationReason = value;
                this.reasonDirty = true;
              })
          }
          .width('100%')
          .padding($r('app.float.spacing_large'))
          .backgroundColor($r('app.color.card_background'))
          .borderRadius($r('app.float.radius_card'))
          .margin({ bottom: $r('app.float.spacing_large') })

          Text(formatDate(this.createTime))
            .fontSize($r('app.float.font_small'))
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .margin({ bottom: $r('app.float.spacing_large') })

          // 状态流转按钮：按当前状态只给出合法动作，非法动作根本不渲染
          Row() {
            if (this.status === TaskStatus.NOT_STARTED) {
              Button($r('app.string.action_start'))
                .layoutWeight(1)
                .height($r('app.float.height_button'))
                .margin({ right: $r('app.float.spacing_medium') })
                .onClick(() => {
                  this.onStart();
                })
            }
            if (this.status === TaskStatus.NOT_STARTED || this.status === TaskStatus.IN_PROGRESS) {
              Button($r('app.string.action_complete'))
                .layoutWeight(1)
                .height($r('app.float.height_button'))
                .margin({ right: $r('app.float.spacing_medium') })
                .onClick(() => {
                  this.onComplete();
                })
              Button($r('app.string.action_mark_unfinished'))
                .layoutWeight(1)
                .height($r('app.float.height_button'))
                .backgroundColor($r('app.color.tag_background'))
                .fontColor($r('app.color.text_primary'))
                .onClick(() => {
                  this.onMarkUnfinished();
                })
            }
            if (this.status === TaskStatus.COMPLETED) {
              Button($r('app.string.action_undo_complete'))
                .layoutWeight(1)
                .height($r('app.float.height_button'))
                .onClick(() => {
                  this.onUndoComplete();
                })
            }
          }
          .width('100%')
          .margin({ bottom: $r('app.float.spacing_medium') })

          Row() {
            Button($r('app.string.action_edit'))
              .layoutWeight(1)
              .height($r('app.float.height_button'))
              .backgroundColor($r('app.color.tag_background'))
              .fontColor($r('app.color.text_primary'))
              .margin({ right: $r('app.float.spacing_medium') })
              .onClick(() => {
                this.onEdit();
              })

            Button($r('app.string.action_delete'))
              .layoutWeight(1)
              .height($r('app.float.height_button'))
              .backgroundColor($r('app.color.tag_background'))
              .fontColor($r('app.color.deviation_over'))
              .onClick(() => {
                this.onDelete();
              })
          }
          .width('100%')
        }
        .width('100%')
        .padding($r('app.float.spacing_large'))
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_background'))
      .align(Alignment.Top)
    }
    .title($r('app.string.detail_title'))
    .onWillShow(() => {
      // onWillShow 是 Callback<void>（@since 12）。刻意不用 onShown：
      // 它的回调参数类型 VisibilityChangeReason 的枚举成员是 @since 21，超出本工程的 API 15。
      this.now = Date.now();
      this.load();
    })
    .onWillHide(() => {
      // 看不见了就停表：一个每 30 秒醒一次、又没人看的定时器只是白耗电。
      // 下一次 onWillShow 会经 load() → syncLiveTick() 重新判断该不该开。
      this.stopLiveTick();
    })
  }
}
