import { DeviationKind } from '../common/TimeUtil';
import { TaskStatus } from '../model/Task';
import { deviationColor, deviationLabelText, durationText, priorityColor, statusText } from '../model/TaskConstants';

/**
 * 今日列表的一行。
 *
 * 刻意只接收基本类型而不是 Task 实例：@Prop 对类实例做的是深拷贝，
 * 拷贝后方法（如 isCompletedLate）可能不可用，且每次刷新都要整对象复制。
 * 派生值（completedLate、deviationKind、diffMinutes）由父组件算好再传进来。
 *
 * 间距一律用 .margin() 而不是 Row/Column 的 space 参数 ——
 * space 的类型是 string | number，收不了 $r() 资源，只能硬编码尺寸。
 */
@Component
export struct TaskListItem {
  @Prop title: string = '';
  @Prop status: number = TaskStatus.NOT_STARTED;
  @Prop estimatedMinutes: number = 0;
  @Prop priority: number = 1;
  @Prop completedLate: boolean = false;
  @Prop deviationKind: number = DeviationKind.NO_TIMING_DATA;
  @Prop diffMinutes: number = 0;

  /** 已经结束（完成/未完成）才有必要展示偏差；进行中的任务显示「未记录计时」只是噪音 */
  private isSettled(): boolean {
    return this.status === TaskStatus.COMPLETED || this.status === TaskStatus.UNFINISHED;
  }

  /** 只有真正算出了耗时的三种结论才带数字 */
  private hasDeviationNumber(): boolean {
    return this.deviationKind === DeviationKind.ACCURATE
      || this.deviationKind === DeviationKind.OVER
      || this.deviationKind === DeviationKind.UNDER;
  }

  build() {
    Row() {
      // 优先级色条：不占文字空间，但一眼能分辨轻重缓急
      Column()
        .width($r('app.float.width_priority_bar'))
        .height($r('app.float.height_priority_bar'))
        .backgroundColor(priorityColor(this.priority))
        .borderRadius($r('app.float.radius_tag'))
        .margin({ right: $r('app.float.spacing_medium') })

      Column() {
        Text(this.title)
          .fontSize($r('app.float.font_body'))
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
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

          Text(durationText(this.estimatedMinutes))
            .fontSize($r('app.float.font_small'))
            .fontColor($r('app.color.text_secondary'))

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
              .margin({ left: $r('app.float.spacing_small') })
          }
        }
        .width('100%')
        .margin({ bottom: $r('app.float.spacing_small') })

        // 本应用的核心信息：这一次估得准不准。只在任务结束后出现。
        if (this.isSettled()) {
          Row() {
            Text(deviationLabelText(this.deviationKind))
              .fontSize($r('app.float.font_small'))
              .fontColor(deviationColor(this.deviationKind))

            if (this.hasDeviationNumber()) {
              Text(durationText(Math.abs(this.diffMinutes)))
                .fontSize($r('app.float.font_small'))
                .fontColor(deviationColor(this.deviationKind))
                .margin({ left: $r('app.float.spacing_small') })
            }
          }
          .width('100%')
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding($r('app.float.spacing_large'))
    .backgroundColor($r('app.color.card_background'))
    .borderRadius($r('app.float.radius_card'))
    .alignItems(VerticalAlign.Top)
  }
}
