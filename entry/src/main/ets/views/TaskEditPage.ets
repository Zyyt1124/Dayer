import { BusinessError } from '@kit.BasicServicesKit';
import { showToast } from '../common/Feedback';
import { Logger } from '../common/Logger';
import { BiasResult, BiasSample, estimateBias, suggestedMinutes } from '../common/EstimateBias';
import { durationText, categoryText, priorityText, ratioText, QUICK_MINUTES } from '../model/TaskConstants';
import { endOfDay, formatDate } from '../common/TimeUtil';
import { Task, TaskCategory, TaskPriority, TaskStatus } from '../model/Task';
import { HISTORY_LIMIT, TaskDao } from '../data/TaskDao';

const TAG: string = 'TaskEditPage';
/** 与 resources 里的 error_title_too_long 文案保持一致 */
const MAX_TITLE_LENGTH: number = 50;
const PRIORITIES: number[] = [TaskPriority.LOW, TaskPriority.MEDIUM, TaskPriority.HIGH];
const CATEGORIES: number[] = [
  TaskCategory.WORK,
  TaskCategory.STUDY,
  TaskCategory.LIFE,
  TaskCategory.ENTERTAINMENT,
  TaskCategory.FITNESS
];

/**
 * 任务的录入 / 编辑页。
 *
 * 跳转参数只有 taskId（0 = 新建），数据由本页自己向 DAO 查，不在路由栈上传递对象快照。
 * pathStack 由父页直接传入 —— 省掉 NavDestinationContext 的 onReady 回调，少一层 API。
 *
 * 间距一律用 .margin()：Row/Column 的 space 参数类型是 string | number，收不了 $r() 资源。
 */
@Component
export struct TaskEditPage {
  /** 0 表示新建 */
  taskId: number = 0;
  pathStack: NavPathStack = new NavPathStack();
  /** 保存成功后通知父页刷新列表 */
  onChanged: () => void = () => {};

  @State title: string = '';
  /** 输入框里的原始字符串，保存时才解析；直接存 number 会把「正在输入的中间态」抹掉 */
  @State estimatedText: string = '';
  @State priority: number = TaskPriority.MEDIUM;
  @State categoryId: number = TaskCategory.WORK;
  @State detail: string = '';
  @State deadline: number = 0;

  /**
   * 编辑模式下载入的原任务。
   * 保存时在它身上只覆盖用户可编辑的字段，这样 status / actualStartTime / actualEndTime
   * 等状态字段不会被这一页意外清掉。
   */
  private loaded: Task = new Task();

  /** 已完成任务的历史样本，用于算「你这类任务通常是预估的几倍」 */
  private history: BiasSample[] = [];
  /** 统计结果本体。页面只把要显示的几项拷进 @State（见 refreshBias） */
  private bias: BiasResult = BiasResult.notReady(0);
  /**
   * 建议所依据的预估分钟数。
   *
   * ⚠️ 刻意与输入框解耦：用户在输入框里手打的每一次都会更新它，但点「用这个数」
   * **不会**更新它。否则就会出现「建议 84 → 采纳 → 基于 84 再建议 118 → 采纳 → 165」
   * 的自我放大，每点一下数字往上滚一轮。
   */
  private baseMinutes: number = 0;

  /**
   * 上一次由「用这个数」**程序化**写进输入框的值。
   *
   * ⚠️ 存在的理由：给 `TextInput` 的 `text` 绑定赋一个新值，组件会**回调 onChange**，
   * 就像用户手打的一样。若那次 onChange 也去更新 baseMinutes，建议就会以自己为基准
   * 自我放大 —— 实测连点 4 下「用这个数」：60 → 90 → 135 → 203 → 305，
   * 每一下都乘一次中位倍率再取整，而每次屏幕上显示的「1.5 倍」都还是对的，
   * 只有输入框在偷偷滚雪球。编译器不报错、单测也测不出（这是纯 UI 交互回路）。
   *
   * 做法是记住「自己写进去的值」，在 onChange 里认出它并跳过基准更新 ——
   * 用一个值比较而不是一个布尔开关，是因为开关一旦没被消费就会卡住，
   * 把用户下一次真实的手打也吞掉。
   */
  private appliedSuggestion: string = '';

  @State biasReady: boolean = false;
  @State biasSampleCount: number = 0;
  /** 中位倍率的十分位整数（1.4 倍存 14），避免 @State 里放浮点 */
  @State biasRatioTenths: number = 10;
  @State biasSuggested: number = 0;

  aboutToAppear(): void {
    // 历史与任务本体并行取，谁先回来都不影响另一个
    this.loadHistory();
    if (this.taskId > 0) {
      this.load();
    }
  }

  /**
   * 拉历史样本。
   * 失败只记日志**不弹提示**：拿不到历史的结果仅仅是少一条建议，
   * 不该因此拦住「录一个任务」这件正事。
   */
  private loadHistory(): void {
    TaskDao.queryCompletedDurations(HISTORY_LIMIT)
      .then((samples: BiasSample[]) => {
        this.history = samples;
        this.refreshBias();
      })
      .catch((err: BusinessError) => {
        Logger.error(TAG, `load history failed: ${err.code} ${err.message}`);
      });
  }

  /** 重算建议。分类变了、预估改了、历史回来了，都要走这里 */
  private refreshBias(): void {
    const result: BiasResult = estimateBias(this.history, this.categoryId);
    this.bias = result;
    this.biasReady = result.ready;
    this.biasSampleCount = result.sampleCount;
    this.biasRatioTenths = Math.round(result.medianRatio * 10);
    this.biasSuggested = suggestedMinutes(this.baseMinutes, result);
  }

  private load(): void {
    TaskDao.queryById(this.taskId)
      .then((task: Task | null) => {
        if (task === null) {
          Logger.warn(TAG, `task ${this.taskId} not found`);
          return;
        }
        this.loaded = task;
        this.title = task.title;
        this.estimatedText = task.estimatedMinutes > 0 ? task.estimatedMinutes.toString() : '';
        this.priority = task.priority;
        this.categoryId = task.categoryId;
        this.detail = task.detail;
        this.deadline = task.deadline;
        // 载入的是用户原本填的数，它就是建议的基准
        this.baseMinutes = task.estimatedMinutes;
        this.refreshBias();
      })
      .catch((err: BusinessError) => {
        Logger.error(TAG, `load task ${this.taskId} failed: ${err.code} ${err.message}`);
        showToast(this.getUIContext(), $r('app.string.toast_load_failed'));
      });
  }

  /** 输入框里的文本 → 分钟数；非法输入一律归 0，由校验统一拦下 */
  private parseMinutes(): number {
    if (this.estimatedText.length === 0) {
      return 0;
    }
    const parsed: number = Number.parseInt(this.estimatedText, 10);
    return Number.isNaN(parsed) ? 0 : parsed;
  }

  private onSave(): void {
    const trimmed: string = this.title.trim();
    if (trimmed.length === 0) {
      showToast(this.getUIContext(), $r('app.string.error_title_required'));
      return;
    }
    if (trimmed.length > MAX_TITLE_LENGTH) {
      showToast(this.getUIContext(), $r('app.string.error_title_too_long'));
      return;
    }
    const minutes: number = this.parseMinutes();
    if (minutes <= 0) {
      showToast(this.getUIContext(), $r('app.string.error_estimated_invalid'));
      return;
    }
    this.persist(trimmed, minutes);
  }

  private persist(title: string, minutes: number): void {
    const task: Task = this.loaded;
    task.title = title;
    task.estimatedMinutes = minutes;
    task.priority = this.priority;
    task.categoryId = this.categoryId;
    task.detail = this.detail;
    task.deadline = this.deadline;

    if (this.taskId > 0) {
      task.id = this.taskId;
      TaskDao.update(task)
        .then(() => {
          this.afterSave();
        })
        .catch((err: BusinessError) => {
          Logger.error(TAG, `update failed: ${err.code} ${err.message}`);
          showToast(this.getUIContext(), $r('app.string.toast_save_failed'));
        });
      return;
    }

    task.createTime = Date.now();
    task.status = TaskStatus.NOT_STARTED;
    TaskDao.insert(task)
      .then((rowId: number) => {
        Logger.info(TAG, `created task id=${rowId}`);
        this.afterSave();
      })
      .catch((err: BusinessError) => {
        Logger.error(TAG, `insert failed: ${err.code} ${err.message}`);
        showToast(this.getUIContext(), $r('app.string.toast_save_failed'));
      });
  }

  private afterSave(): void {
    // 先通知父页刷新，再出栈
    this.onChanged();
    this.pathStack.pop();
  }

  private pickDeadline(): void {
    const selected: Date = this.deadline > 0 ? new Date(this.deadline) : new Date();
    try {
      this.getUIContext().showDatePickerDialog({
        start: new Date(2000, 0, 1),
        end: new Date(2100, 11, 31),
        selected: selected,
        // onAccept 自 API 10 起废弃，用 onDateAccept
        onDateAccept: (value: Date) => {
          // 截止时间取当天最后一刻：「当天做完」不该被算成逾期
          this.deadline = endOfDay(value.getTime());
        }
      });
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.error(TAG, `showDatePickerDialog failed: ${e.code} ${e.message}`);
    }
  }

  /**
   * 以下是若干 @Builder：直接读 this.* 因而随状态刷新。
   * 带值参数的 @Builder 不会因参数变化而重绘，选中态就会卡住不动 ——
   * 所以只有「文案永不变化」的 FieldLabel 才带参数。
   */
  @Builder
  FieldLabel(label: Resource) {
    Text(label)
      .fontSize($r('app.float.font_caption'))
      .fontColor($r('app.color.text_secondary'))
      .width('100%')
      .margin({ bottom: $r('app.float.spacing_small') })
  }

  @Builder
  PriorityChips() {
    Row() {
      ForEach(PRIORITIES, (item: number) => {
        Text(priorityText(item))
          .fontSize($r('app.float.font_caption'))
          .fontColor(this.priority === item ? $r('app.color.card_background') : $r('app.color.text_primary'))
          .backgroundColor(this.priority === item ? $r('app.color.accent') : $r('app.color.tag_background'))
          .borderRadius($r('app.float.radius_tag'))
          .padding({
            left: $r('app.float.spacing_medium'),
            right: $r('app.float.spacing_medium'),
            top: $r('app.float.spacing_small'),
            bottom: $r('app.float.spacing_small')
          })
          .margin({ right: $r('app.float.spacing_small') })
          .onClick(() => {
            this.priority = item;
          })
      }, (item: number) => `priority-${item}`)
    }
    .width('100%')
  }

  @Builder
  CategoryChips() {
    Row() {
      ForEach(CATEGORIES, (item: number) => {
        Text(categoryText(item))
          .fontSize($r('app.float.font_caption'))
          .fontColor(this.categoryId === item ? $r('app.color.card_background') : $r('app.color.text_primary'))
          .backgroundColor(this.categoryId === item ? $r('app.color.accent') : $r('app.color.tag_background'))
          .borderRadius($r('app.float.radius_tag'))
          .padding({
            left: $r('app.float.spacing_medium'),
            right: $r('app.float.spacing_medium'),
            top: $r('app.float.spacing_small'),
            bottom: $r('app.float.spacing_small')
          })
          .margin({ right: $r('app.float.spacing_small') })
          .onClick(() => {
            this.categoryId = item;
            // 分类一换，参考的历史样本就换成另一批，建议必须跟着变
            this.refreshBias();
          })
      }, (item: number) => `category-${item}`)
    }
    .width('100%')
  }

  /**
   * 快捷耗时选项。
   * ⚠️ 用 Flex + Wrap 而不是 Row：六个选项（最长的是「1小时30分钟」）在手机宽度下
   * 一行放不下，Row 会把最后一个挤出屏幕且无法触及 —— 实测截图上「2小时」整个看不到。
   * 换行后每个按钮都要有下边距，否则折行后两行会贴在一起。
   */
  @Builder
  QuickMinutes() {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(QUICK_MINUTES, (item: number) => {
        Text(durationText(item))
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
          .margin({
            right: $r('app.float.spacing_small'),
            bottom: $r('app.float.spacing_xsmall')
          })
          .onClick(() => {
            this.estimatedText = item.toString();
            this.baseMinutes = item;
            this.refreshBias();
          })
      }, (item: number) => `quick-${item}`)
    }
    .width('100%')
    .margin({ top: $r('app.float.spacing_small') })
  }

  /**
   * 同类任务参考。
   *
   * 这是本期的核心 —— 把「你估时偏多少」放在**填预估的地方**。
   * 竞品调研里 UCL CHIWORK 2025 的实测结论是：只在事后并排展示「计划 vs 实际」
   * 对提升估时准确度没有显著效果。能改变行为的时点是「正在填这个数」的当下。
   *
   * 样本不足时直说不够，不给数字 —— 用两条记录编出来的倍率是编造，不是建议。
   */
  @Builder
  BiasCard() {
    Column() {
      Text($r('app.string.coach_reference_title'))
        .fontSize($r('app.float.font_caption'))
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .margin({ bottom: $r('app.float.spacing_small') })

      if (this.biasReady) {
        Row() {
          Text($r('app.string.coach_ready'))
            .fontSize($r('app.float.font_small'))
            .fontColor($r('app.color.text_secondary'))
          Text(ratioText(this.biasRatioTenths))
            .fontSize($r('app.float.font_body'))
            .fontColor($r('app.color.accent'))
            .margin({ left: $r('app.float.spacing_xsmall') })
        }
        .width('100%')

        Row() {
          Row() {
            Text($r('app.string.coach_suggest_label'))
              .fontSize($r('app.float.font_small'))
              .fontColor($r('app.color.text_secondary'))
            Text(durationText(this.biasSuggested))
              .fontSize($r('app.float.font_body'))
              .fontColor($r('app.color.text_primary'))
              .margin({ left: $r('app.float.spacing_xsmall') })
          }
          .layoutWeight(1)

          Text($r('app.string.coach_apply'))
            .fontSize($r('app.float.font_caption'))
            .fontColor($r('app.color.accent'))
            .onClick(() => {
              // 只改输入框，不动 baseMinutes —— 连点两下得到的还是同一个数
              const applied: string = this.biasSuggested.toString();
              if (applied === this.estimatedText) {
                // 值没变就不会有 onChange 回调，别留下一个待消费的标记
                return;
              }
              this.appliedSuggestion = applied;
              this.estimatedText = applied;
            })
        }
        .width('100%')
        .margin({ top: $r('app.float.spacing_xsmall') })

        Text($r('app.string.coach_basis', this.biasSampleCount))
          .fontSize($r('app.float.font_small'))
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
          .margin({ top: $r('app.float.spacing_small') })
      } else {
        Text($r('app.string.coach_not_ready', this.biasSampleCount))
          .fontSize($r('app.float.font_small'))
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
      }
    }
    .width('100%')
    .padding($r('app.float.spacing_medium'))
    .backgroundColor($r('app.color.tag_background'))
    .borderRadius($r('app.float.radius_tag'))
    .alignItems(HorizontalAlign.Start)
    .margin({ top: $r('app.float.spacing_small') })
  }

  @Builder
  DeadlineRow() {
    Row() {
      Text(this.deadline > 0 ? formatDate(this.deadline) : $r('app.string.deadline_not_set'))
        .fontSize($r('app.float.font_body'))
        .fontColor(this.deadline > 0 ? $r('app.color.text_primary') : $r('app.color.text_tertiary'))
        .layoutWeight(1)
        .textAlign(TextAlign.Start)

      if (this.deadline > 0) {
        Text($r('app.string.action_clear'))
          .fontSize($r('app.float.font_caption'))
          .fontColor($r('app.color.text_secondary'))
          .padding({ left: $r('app.float.spacing_medium') })
          .onClick(() => {
            this.deadline = 0;
          })
      }
    }
    .width('100%')
    .height($r('app.float.height_input'))
    .padding({ left: $r('app.float.spacing_medium'), right: $r('app.float.spacing_medium') })
    .backgroundColor($r('app.color.tag_background'))
    .borderRadius($r('app.float.radius_tag'))
    .onClick(() => {
      this.pickDeadline();
    })
  }

  build() {
    NavDestination() {
      Scroll() {
        Column() {

          Column() {
            this.FieldLabel($r('app.string.label_task_title'))
            TextInput({ text: this.title, placeholder: $r('app.string.placeholder_task_title') })
              .maxLength(MAX_TITLE_LENGTH)
              .height($r('app.float.height_input'))
              .onChange((value: string) => {
                this.title = value;
              })
          }
          .width('100%')
          .margin({ bottom: $r('app.float.spacing_xlarge') })

          Column() {
            this.FieldLabel($r('app.string.label_estimated'))
            TextInput({ text: this.estimatedText, placeholder: $r('app.string.label_estimated_hint') })
              .type(InputType.Number)
              .maxLength(4)
              .height($r('app.float.height_input'))
              .onChange((value: string) => {
                if (value === this.appliedSuggestion) {
                  // 这次回调是上面那次程序化赋值回传的，不是用户手打，不能当作新基准
                  this.appliedSuggestion = '';
                  return;
                }
                this.estimatedText = value;
                // 手打的每一个数都是新的基准，建议随之重算
                this.baseMinutes = this.parseMinutes();
                this.refreshBias();
              })
            this.QuickMinutes()
            // ⚠️ 这个条件必须读 @State（parseMinutes 读的是 estimatedText），
            // **不能**写成 `if (this.baseMinutes > 0)`：baseMinutes 是普通成员，
            // 而 ArkUI 只对「条件里读到的 @State」做依赖追踪。条件读不到任何 @State 时
            // 这个 if 节点只在首帧求值一次 —— 首帧 baseMinutes 恒为 0，于是参考卡片
            // **永远不渲染**。实测症状：点「30分钟」后输入框变成 30、下面的换算文字
            // 也出现了，唯独参考卡片整块不见，编译器不报错。
            // 两者等价：baseMinutes 与 parseMinutes() 都由同一批事件写入（手输/快捷选项/载入）。
            if (this.parseMinutes() > 0) {
              // 把分钟数换算成「1小时30分钟」，用户不用自己心算
              Text(durationText(this.parseMinutes()))
                .fontSize($r('app.float.font_caption'))
                .fontColor($r('app.color.accent'))
                .width('100%')
                .margin({ top: $r('app.float.spacing_small') })

              // 有基准才谈得上参考。没填预估时不出卡片，表单保持干净
              this.BiasCard()
            }
          }
          .width('100%')
          .margin({ bottom: $r('app.float.spacing_xlarge') })

          Column() {
            this.FieldLabel($r('app.string.label_priority'))
            this.PriorityChips()
          }
          .width('100%')
          .margin({ bottom: $r('app.float.spacing_xlarge') })

          Column() {
            this.FieldLabel($r('app.string.label_category'))
            this.CategoryChips()
          }
          .width('100%')
          .margin({ bottom: $r('app.float.spacing_xlarge') })

          Column() {
            this.FieldLabel($r('app.string.label_deadline'))
            this.DeadlineRow()
          }
          .width('100%')
          .margin({ bottom: $r('app.float.spacing_xlarge') })

          Column() {
            this.FieldLabel($r('app.string.label_detail'))
            TextArea({ text: this.detail, placeholder: $r('app.string.placeholder_detail') })
              .height($r('app.float.height_textarea'))
              .onChange((value: string) => {
                this.detail = value;
              })
          }
          .width('100%')
          .margin({ bottom: $r('app.float.spacing_xlarge') })

          Button($r('app.string.action_save'))
            .width('100%')
            .height($r('app.float.height_button'))
            .onClick(() => {
              this.onSave();
            })
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
    .title(this.taskId > 0 ? $r('app.string.edit_title_edit') : $r('app.string.edit_title_new'))
  }
}
