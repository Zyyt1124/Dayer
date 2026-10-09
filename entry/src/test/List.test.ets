import timeUtilTest from './TimeUtil.test';
import taskFlowTest from './TaskFlow.test';
import migrationTest from './Migration.test';
import estimateBiasTest from './EstimateBias.test';
import reminderPlanTest from './ReminderPlan.test';
import taskProgressTest from './TaskProgress.test';
import taskStatsTest from './TaskStats.test';
import reviewAdviceTest from './ReviewAdvice.test';

export default function testsuite() {
  timeUtilTest();
  taskFlowTest();
  migrationTest();
  estimateBiasTest();
  reminderPlanTest();
  taskProgressTest();
  taskStatsTest();
  reviewAdviceTest();
}
