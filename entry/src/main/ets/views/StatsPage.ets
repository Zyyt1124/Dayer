import { BusinessError } from '@kit.BasicServicesKit';
import { showToast } from '../common/Feedback';
import { Logger } from '../common/Logger';
import { DayRange } from '../common/TimeUtil';
import {
  CategoryStat,
  completedCount,
  computeStats,
  StatsResult,
  statsWindow,
  WINDOW_ALL,
  WINDOW_MONTH,
  WINDOW_TODAY,
  WINDOW_WEEK
} from '../common/TaskStats';
import { Advice, buildReview, ReviewResult } from '../common/ReviewAdvice';
import { adviceChipText, adviceSentence, categoryText, durationText, ratioText } from '../model/TaskConstants';
import { Task } from '../model/Task';
import { TaskDao } from '../data/TaskDao';

const TAG: string = 'StatsPage';

/**
 * 窗口 → 文案。写成 if/else 而不是查表：$r('app.string.xxx') 的 key 必须是字符串字面量，
 * 不能拼接（$r('app.string.' + name) 会被拒），理由与 TaskConstants 里那几个映射函数相同。
 */
function windowText(window: number): Resource {
  if (window === WINDOW_WEEK) {
    return $r('app.string.stats_window_week');
  }
  if (window === WINDOW_MONTH) {
    return $r('app.string.stats_window_month');
  }
  if (window === WINDOW_ALL) {
    return $r('app.string.stats_window_all');
  }
  return $r('app.string.stats_window_today');
}

/** 计数值 → 文案。Text 收的是 string|Resource，数字必须先转成字符串 */
function countText(value: number): string {
  return String(value);
}

/**
 * 统计页：把用户记下的「预估 vs 实际」还给他。
 *
 * 这是产品闭环的最后一环。在此之前，估时倍率只在**编辑页**当教练提示用 —— 那是**事前**的一面
 * （「你正在建这条任务，建议改一改」）。本页是**事后**的一面：「我这个人估时到底什么水平」。
 *
 * ⚠️ 所有 @Builder 都是**无参数**的，需要什么就在函数体里读 this.*。
 * 带参数的 @Builder 会退化成按值传递、状态变化不引起内部重绘 ——
 * 本项目在 TaskDetailPage.MetricColumn 上吃过一次亏：整块卡片永久停在首帧，
 * **编译器不报错、单测也测不出**，只能靠肉眼发现。
 * 窗口切换是这一页最容易踩这个坑的地方（症状：切了段，数字纹丝不动）。
 *
 * ⚠️ 间距一律用 .margin()/.padding()：Row/Column 的 space 参数类型是 string|number，收不了 $r()。
 */
@Component
export struct StatsPage {
  // 刻意**不**声明 pathStack：本页不往任何地方压栈（TaskDetailPage 持有它是因为要跳编辑页）。
  // 声明一个用不到的路由栈只会让人以为这一页也能跳转。

  /**
   * 本页的时间来源。**刻意不是 @State** —— 它只在 reload() 里用来算查询区间，
   * 渲染路径一个字都不读它（统计结果已经算好放在 stats 里）。
   * 把它标成 @State 反而会误导下一个人以为改它能刷新界面。
   */
  private now: number = 0;

  /** 时间窗口，取 WINDOW_* 之一 */
  @State window: number = WINDOW_TODAY;
  /** 算好的统计结果。整体替换才触发重绘（@State 只观测到对象被换掉这一层），与 tasks 同理 */
  @State stats: StatsResult = new StatsResult();
  /** 首次查询完成前什么都不渲染，否则会先闪一下「还没有已结算的任务」 */
  @State loaded: boolean = false;
  /** 竞态令牌：快速连点几个窗口会并发多次查询，后返回的未必是最新的 */
  private loadToken: number = 0;

  /**
   * 复盘建议。**依据是全部历史，与当前页签无关** —— 所以它有自己的查询、自己的令牌，
   * 且换页签时不重查（见 selectWindow）。
   */
  @State review: ReviewResult = new ReviewResult();
  /**
   * 复盘查询单独一个 loaded 标志，而不是复用 this.loaded：
   * 两个查询各自可能失败，失败的那一半不该拖累另一半渲染。
   */
  @State reviewLoaded: boolean = false;
  private reviewToken: number = 0;

  aboutToAppear(): void {
    this.now = Date.now();
    this.reload();
    this.reloadReview();
  }

  private reload(): void {
    const token: number = ++this.loadToken;
    const range: DayRange = statsWindow(this.now, this.window);
    TaskDao.queryByRange(range.start, range.end)
      .then((rows: Task[]) => {
        if (token !== this.loadToken) {
          return;
        }
        // 统计放在这里算一次、存进 @State，而不是在渲染里现算：
        // 渲染路径会被调用很多次（每个卡片、每一行都要读），而 computeStats 里
        // 每个分类都要跑一次 estimateBias（含排序），现算等于把同一份活干十几遍。
        this.stats = computeStats(rows);
        this.loaded = true;
      })
      .catch((err: BusinessError) => {
        if (token !== this.loadToken) {
          return;
        }
        this.loaded = true;
        Logger.error(TAG, `queryByRange failed: ${err.code} ${err.message}`);
        showToast(this.getUIContext(), $r('app.string.toast_load_failed'));
      });
  }

  /**
   * 取全部历史、算一次复盘建议。
   *
   * 区间直接用 statsWindow(now, WINDOW_ALL)，不手写 (0, startOfTomorrow(now)) ——
   * 这免费拿到一条强保证：复盘卡的数据源与【全部】页签**永远逐毫秒一致**，
   * 不会走岔成两套「全部」的定义。
   *
   * ⚠️ 刻意**不**带上「查过了就跳过」的去重：同一个库会被首页/详情页/编辑页改，
   * 每次进这一页都必须重查，否则用户改完任务回来看到的是旧建议。
   */
  private reloadReview(): void {
    const token: number = ++this.reviewToken;
    const range: DayRange = statsWindow(this.now, WINDOW_ALL);
    TaskDao.queryByRange(range.start, range.end)
      .then((rows: Task[]) => {
        if (token !== this.reviewToken) {
          return;
        }
        this.review = buildReview(rows);
        this.reviewLoaded = true;
      })
      .catch((err: BusinessError) => {
        if (token !== this.reviewToken) {
          return;
        }
        Logger.error(TAG, `review query failed: ${err.code} ${err.message}`);
        // ⚠️ 刻意**不**置 reviewLoaded。宁可不显示这张卡，也不要因为一次查询失败
        // 就对用户说「记录还太少，多做几条、记得点完成」—— 那是一句假话，
        // 而且他会照着去改自己的行为。与编辑页 BiasCard 的 catch 只记日志同一条理由。
      });
  }

  /**
   * 换窗口。必须重新查库，不能在内存里过滤那批 tasks ——
   * 「哪些任务落在这个窗口里」由 SQL 的 OR 谓词决定（创建于窗口 ∪ 结束于窗口），
   * 而换窗口会把它整个换掉，内存里那份是上一个窗口的结果。
   *
   * 顺带重读一次 Date.now()：页面开着跨过午夜时，四个窗口的边界都该跟着走。
   */
  private selectWindow(next: number): void {
    if (this.window === next) {
      return;
    }
    this.window = next;
    this.now = Date.now();
    this.reload();
  }

  private overallRatioText(): Resource {
    if (!this.stats.overallBias.ready) {
      return $r('app.string.stats_not_enough');
    }
    return ratioText(Math.round(this.stats.overallBias.medianRatio * 10));
  }

  private categoryRatioText(item: CategoryStat): Resource {
    if (!item.biasReady) {
      return $r('app.string.stats_not_enough');
    }
    return ratioText(Math.round(item.medianRatio * 10));
  }

  /** ForEach 的 key。必须由渲染字段派生，否则换窗口后旧行不会被重建 */
  private categoryKey(item: CategoryStat): string {
    return `${item.categoryId}:${item.actualMinutes}:${item.share}`;
  }

  /**
   * 复盘建议行的 key。**末尾带 index** —— 按 code 去重目前是靠 buildReview 里的
   * 两条限额保证的，将来某条规则若放进两条同类建议，key 就会撞、ForEach 会**静默丢行**。
   * 带上 index 零成本，而 key 仍由渲染字段派生（本页的规矩不破）。
   */
  private adviceKey(item: Advice, index: number): string {
    return `${item.code}:${item.categoryId}:${item.tenths}:${item.numerator}:${item.denominator}:${index}`;
  }

  /**
   * 时间窗口切换。四个 Text 平铺而不写 ForEach：ForEach 只重建 key 变了的项，
   * 而这里的 key（窗口 id）恰恰是不变的那个，选中态很可能不跟着刷新 ——
   * 这正是本页最该避免的一类静默失效，宁可多写三行。
   */
  @Builder
  WindowSwitcher() {
    Row() {
      Text(windowText(WINDOW_TODAY))
        .fontSize($r('app.float.font_caption'))
        .fontColor(this.window === WINDOW_TODAY ? $r('app.color.accent') : $r('app.color.text_secondary'))
        .backgroundColor(this.window === WINDOW_TODAY ? $r('app.color.tag_background') : $r('app.color.card_background'))
        .borderRadius($r('app.float.radius_tag'))
        .padding({
          top: $r('app.float.spacing_small'),
          bottom: $r('app.float.spacing_small')
        })
        .layoutWeight(1)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.selectWindow(WINDOW_TODAY);
        })

      Text(windowText(WINDOW_WEEK))
        .fontSize($r('app.float.font_caption'))
        .fontColor(this.window === WINDOW_WEEK ? $r('app.color.accent') : $r('app.color.text_secondary'))
        .backgroundColor(this.window === WINDOW_WEEK ? $r('app.color.tag_background') : $r('app.color.card_background'))
        .borderRadius($r('app.float.radius_tag'))
        .padding({
          top: $r('app.float.spacing_small'),
          bottom: $r('app.float.spacing_small')
        })
        .layoutWeight(1)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.selectWindow(WINDOW_WEEK);
        })

      Text(windowText(WINDOW_MONTH))
        .fontSize($r('app.float.font_caption'))
        .fontColor(this.window === WINDOW_MONTH ? $r('app.color.accent') : $r('app.color.text_secondary'))
        .backgroundColor(this.window === WINDOW_MONTH ? $r('app.color.tag_background') : $r('app.color.card_background'))
        .borderRadius($r('app.float.radius_tag'))
        .padding({
          top: $r('app.float.spacing_small'),
          bottom: $r('app.float.spacing_small')
        })
        .layoutWeight(1)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.selectWindow(WINDOW_MONTH);
        })

      Text(windowText(WINDOW_ALL))
        .fontSize($r('app.float.font_caption'))
        .fontColor(this.window === WINDOW_ALL ? $r('app.color.accent') : $r('app.color.text_secondary'))
        .backgroundColor(this.window === WINDOW_ALL ? $r('app.color.tag_background') : $r('app.color.card_background'))
        .borderRadius($r('app.float.radius_tag'))
        .padding({
          top: $r('app.float.spacing_small'),
          bottom: $r('app.float.spacing_small')
        })
        .layoutWeight(1)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.selectWindow(WINDOW_ALL);
        })
    }
    .width('100%')
    .padding($r('app.float.spacing_xsmall'))
    .backgroundColor($r('app.color.card_background'))
    .borderRadius($r('app.float.radius_card'))
    .margin({ bottom: $r('app.float.spacing_large') })
  }

  /**
   * 完成情况。三桶是需求文档要求的展示形式（已完成 / 延期 / 未完成），
   * 但条形与那个分数只分「做完没做完」—— 延期不算失败，它是完成了只是晚了。
   *
   * 显示成「15 / 20」而不是百分数：分母必须看得见，否则用户不知道这个比例
   * 是建立在 2 条还是 200 条记录上（本页刻意不显示 % 号，见 TaskStats 的口径说明）。
   */
  @Builder
  OverviewCard() {
    Column() {
      Text($r('app.string.stats_overview'))
        .fontSize($r('app.float.font_caption'))
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .margin({ bottom: $r('app.float.spacing_small') })

      Text($r('app.string.stats_fraction',
        completedCount(this.stats), this.stats.settledCount))
        .fontSize($r('app.float.font_title'))
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .margin({ bottom: $r('app.float.spacing_small') })

      Progress({
        value: completedCount(this.stats),
        // 分母为 0 时 Progress 的 total 不能是 0；这个分支其实走不到（空窗口整页是空态），
        // 但渲染路径不接受「理论上不会发生」这种保证
        total: this.stats.settledCount > 0 ? this.stats.settledCount : 1,
        type: ProgressType.Linear
      })
        .color($r('app.color.accent'))
        .backgroundColor($r('app.color.tag_background'))
        .width('100%')
        .margin({ bottom: $r('app.float.spacing_large') })

      Row() {
        Column() {
          Text($r('app.string.stats_done_on_time'))
            .fontSize($r('app.float.font_small'))
            .fontColor($r('app.color.text_tertiary'))
          Text(countText(this.stats.doneOnTimeCount))
            .fontSize($r('app.float.font_subtitle'))
            .fontColor($r('app.color.deviation_under'))
            .margin({ top: $r('app.float.spacing_xsmall') })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Center)

        Column() {
          Text($r('app.string.stats_done_late'))
            .fontSize($r('app.float.font_small'))
            .fontColor($r('app.color.text_tertiary'))
          Text(countText(this.stats.doneLateCount))
            .fontSize($r('app.float.font_subtitle'))
            .fontColor($r('app.color.deviation_over'))
            .margin({ top: $r('app.float.spacing_xsmall') })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Center)

        Column() {
          Text($r('app.string.stats_unfinished'))
            .fontSize($r('app.float.font_small'))
            .fontColor($r('app.color.text_tertiary'))
          Text(countText(this.stats.unfinishedCount))
            .fontSize($r('app.float.font_subtitle'))
            .fontColor($r('app.color.deviation_neutral'))
            .margin({ top: $r('app.float.spacing_xsmall') })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Center)
      }
      .width('100%')
      .margin({ bottom: $r('app.float.spacing_medium') })

      Text($r('app.string.stats_settled', this.stats.settledCount))
        .fontSize($r('app.float.font_small'))
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .textAlign(TextAlign.Start)
    }
    .width('100%')
    .padding($r('app.float.spacing_large'))
    .backgroundColor($r('app.color.card_background'))
    .borderRadius($r('app.float.radius_card'))
    .margin({ bottom: $r('app.float.spacing_large') })
  }

  /**
   * 估时表现。分母是「可比条数」而不是「已结算条数」—— 一个没做完的任务
   * 同样可能记了实际耗时，它的估时照样能拿来判断准不准。
   */
  @Builder
  EstimationCard() {
    Column() {
      Text($r('app.string.stats_estimation'))
        .fontSize($r('app.float.font_caption'))
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .margin({ bottom: $r('app.float.spacing_small') })

      if (this.stats.timedCount > 0) {
        Row() {
          Text($r('app.string.stats_fraction',
            this.stats.accurateCount, this.stats.timedCount))
            .fontSize($r('app.float.font_title'))
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
            .textAlign(TextAlign.Start)

          Column() {
            Text($r('app.string.stats_median_ratio'))
              .fontSize($r('app.float.font_small'))
              .fontColor($r('app.color.text_tertiary'))
            Text(this.overallRatioText())
              .fontSize($r('app.float.font_caption'))
              .fontColor($r('app.color.text_primary'))
              .margin({ top: $r('app.float.spacing_xsmall') })
          }
          .alignItems(HorizontalAlign.End)
        }
        .width('100%')
        .margin({ bottom: $r('app.float.spacing_small') })

        Progress({
          value: this.stats.accurateCount,
          total: this.stats.timedCount,
          type: ProgressType.Linear
        })
          .color($r('app.color.deviation_accurate'))
          .backgroundColor($r('app.color.tag_background'))
          .width('100%')
          .margin({ bottom: $r('app.float.spacing_large') })

        Row() {
          Column() {
            Text($r('app.string.stats_accurate'))
              .fontSize($r('app.float.font_small'))
              .fontColor($r('app.color.text_tertiary'))
            Text(countText(this.stats.accurateCount))
              .fontSize($r('app.float.font_subtitle'))
              .fontColor($r('app.color.deviation_accurate'))
              .margin({ top: $r('app.float.spacing_xsmall') })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Center)

          Column() {
            Text($r('app.string.stats_over'))
              .fontSize($r('app.float.font_small'))
              .fontColor($r('app.color.text_tertiary'))
            Text(countText(this.stats.overCount))
              .fontSize($r('app.float.font_subtitle'))
              .fontColor($r('app.color.deviation_over'))
              .margin({ top: $r('app.float.spacing_xsmall') })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Center)

          Column() {
            Text($r('app.string.stats_under'))
              .fontSize($r('app.float.font_small'))
              .fontColor($r('app.color.text_tertiary'))
            Text(countText(this.stats.underCount))
              .fontSize($r('app.float.font_subtitle'))
              .fontColor($r('app.color.deviation_under'))
              .margin({ top: $r('app.float.spacing_xsmall') })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Center)
        }
        .width('100%')
      } else {
        // 有已结算的任务、却一条可比的计时都没有 —— 用户可能压根不点「开始」。
        // 这里直说没数据，而不是把 0/0 摆出来。
        Text($r('app.string.stats_no_timing'))
          .fontSize($r('app.float.font_caption'))
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
          .textAlign(TextAlign.Start)
      }
    }
    .width('100%')
    .padding($r('app.float.spacing_large'))
    .backgroundColor($r('app.color.card_background'))
    .borderRadius($r('app.float.radius_card'))
    .margin({ bottom: $r('app.float.spacing_large') })
  }

  /**
   * 分类耗时占比：每类一行，条长就是占比。
   *
   * 刻意用每行一条 Progress，而不是 ArkUI 那个专门做占比的 DataPanel 分段条：
   * 分段条要求 N 个互不相同的颜色，而本工程配色是收敛过的、deviation_over 等语义色
   * 已有固定含义（超时/节省），拿它们去区分「工作/学习」会造出「红 = 工作类」这种冲突。
   * 每行一条还能多带一个「该类中位倍率」—— 分段条给不了这个信息，
   * 而它恰恰回答了「哪类事我最容易估错」，是本页最有价值的一栏。
   */
  @Builder
  CategoryCard() {
    Column() {
      Row() {
        Text($r('app.string.stats_category'))
          .fontSize($r('app.float.font_caption'))
          .fontColor($r('app.color.text_secondary'))
          .layoutWeight(1)
          .textAlign(TextAlign.Start)
        Text($r('app.string.stats_median_ratio'))
          .fontSize($r('app.float.font_small'))
          .fontColor($r('app.color.text_tertiary'))
      }
      .width('100%')
      .margin({ bottom: $r('app.float.spacing_medium') })

      ForEach(this.stats.categories, (item: CategoryStat) => {
        Column() {
          Row() {
            Text(categoryText(item.categoryId))
              .fontSize($r('app.float.font_caption'))
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)
              .textAlign(TextAlign.Start)
            Text(this.categoryRatioText(item))
              .fontSize($r('app.float.font_small'))
              .fontColor($r('app.color.text_tertiary'))
              .margin({ right: $r('app.float.spacing_medium') })
            Text(durationText(item.actualMinutes))
              .fontSize($r('app.float.font_caption'))
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .margin({ bottom: $r('app.float.spacing_xsmall') })

          Progress({
            value: item.actualMinutes,
            total: this.stats.totalActualMinutes > 0 ? this.stats.totalActualMinutes : 1,
            type: ProgressType.Linear
          })
            .color($r('app.color.accent'))
            .backgroundColor($r('app.color.tag_background'))
            .width('100%')
        }
        .width('100%')
        .margin({ bottom: $r('app.float.spacing_large') })
      }, (item: CategoryStat) => this.categoryKey(item))
    }
    .width('100%')
    .padding($r('app.float.spacing_large'))
    .backgroundColor($r('app.color.card_background'))
    .borderRadius($r('app.float.radius_card'))
    .margin({ bottom: $r('app.float.spacing_large') })
  }

  /**
   * 复盘建议（需求文档 四.2）：把上面几张卡的统计量翻译成**可行动的句子**。
   *
   * 依据是**全部历史**，不随页签变 —— 建议是对「这个人」说的，不是对「今天」说的，
   * 用今日窗口只会得到「今天只记了 1 条」这种没法行动的话。
   * 所以副标题必须写清依据量，而且 N 只能读 this.review.basisCount：
   * this.stats.settledCount 是**当前窗口**的，换页签的一瞬间会显示
   * 「基于全部 3 条」配着一份按 200 条算出来的建议。
   */
  @Builder
  ReviewCard() {
    Column() {
      Row() {
        Text($r('app.string.advice_title'))
          .fontSize($r('app.float.font_caption'))
          .fontColor($r('app.color.text_secondary'))
          .layoutWeight(1)
          .textAlign(TextAlign.Start)
      }
      .width('100%')
      .margin({ bottom: $r('app.float.spacing_small') })

      Text($r('app.string.advice_basis', this.review.basisCount))
        .fontSize($r('app.float.font_small'))
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .textAlign(TextAlign.Start)
        .margin({ bottom: $r('app.float.spacing_medium') })

      if (this.review.advices.length > 0) {
        // 行内容内联在 lambda 里而不是抽成带参 @Builder —— 与 CategoryCard 同一个理由：
        // 带参 @Builder 会退化成按值传递，状态变了不刷新（TaskDetailPage.MetricColumn 的旧坑）
        ForEach(this.review.advices, (item: Advice, index: number) => {
          Row() {
            Text(adviceChipText(item))
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

            Text(adviceSentence(item))
              .fontSize($r('app.float.font_caption'))
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)
              .textAlign(TextAlign.Start)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
          .margin({ bottom: $r('app.float.spacing_medium') })
        }, (item: Advice, index: number) => this.adviceKey(item, index))
      } else if (this.review.hasEnoughData) {
        // 数据够但没触发任何规则 —— 这是一件好事，文案要说成好事。
        // 刻意不写「没有估时偏差」：不触发也可能是在完成度那一侧，
        // 只提估时会让用户以为这一栏只管估时。
        Text($r('app.string.advice_none'))
          .fontSize($r('app.float.font_caption'))
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .textAlign(TextAlign.Start)
      } else {
        Text($r('app.string.advice_not_enough'))
          .fontSize($r('app.float.font_caption'))
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
          .textAlign(TextAlign.Start)
      }
    }
    .width('100%')
    .padding($r('app.float.spacing_large'))
    .backgroundColor($r('app.color.card_background'))
    .borderRadius($r('app.float.radius_card'))
    .margin({ bottom: $r('app.float.spacing_large') })
  }

  @Builder
  EmptyState() {
    Column() {
      Text($r('app.string.stats_empty'))
        .fontSize($r('app.float.font_body'))
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .padding($r('app.float.spacing_xlarge'))
  }

  build() {
    NavDestination() {
      Scroll() {
        Column() {
          this.WindowSwitcher()

          // 首次查询回来之前什么都不画（与首页同理），否则会先闪一下「还没有已结算的任务」
          //
          // 空态要同时满足「没有已结算的任务」与「没有可比的计时」：按今天的产品逻辑
          // 后者蕴含前者（补记只在已结算的任务上开放），但那是**详情页的 UI 门禁**推出来的，
          // 不是 Task 的类型保证。多写一个条件，日后若放开「进行中也能补记实际用时」，
          // 这一页不会跟着变成一块什么都看不到的空屏。
          if (this.loaded && this.stats.settledCount === 0 && this.stats.timedCount === 0) {
            this.EmptyState()
          } else if (this.loaded) {
            this.OverviewCard()
            this.EstimationCard()
            // 一条可比计时都没有时 categories 是空的，整块不画 ——
            // 上面那张卡已经说过「没有可比的实际计时」了，不必再说一遍
            if (this.stats.timedCount > 0) {
              this.CategoryCard()
            }
          }

          // ⚠️ 复盘卡刻意放在上面那个 if/else **之外**：它的依据是全部历史，与页签无关。
          // 放进 else 分支里的话，「今天没任务、但历史上有 200 条」的用户一个字都看不到 ——
          // 而那恰恰是最该看到这些建议的人。
          if (this.reviewLoaded) {
            this.ReviewCard()
          }
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
    .title($r('app.string.stats_title'))
    .onWillShow(() => {
      // onWillShow 是 Callback<void>（@since 12）。刻意不用 onShown：它的回调参数类型
      // VisibilityChangeReason 的枚举成员是 @since 21，超出本工程的 API 15。
      this.now = Date.now();
      this.reload();
      this.reloadReview();
    })
  }
}
