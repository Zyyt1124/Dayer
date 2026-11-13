# Dayer

**基于参考类预测的个人任务估时纠偏系统** · HarmonyOS NEXT 端侧实现

> 别人在「展示」你的预估偏差，我们让系统在偏差发生前「介入」。

Dayer 是一款 HarmonyOS NEXT 原生应用。它不只记录「这件事花了多久」，而是用你自己过去做同类任务的历史分布，在动手之前告诉你「这次大概率要花多久」，做完后用实际耗时复盘并校准下一次预估。所有数据保存在设备本地，不联网、不上传。

**课程项目**：移动应用开发 · 朱一言、严一凡

---

## 功能

> 当前仓库为 12 周计划中**第 6 周「最小闭环」**的代码快照，已实现预估 → 执行 → 复盘的主链路。

### 任务与执行
- 新建 / 编辑 / 删除任务：标题、备注、分类、优先级、截止时间
- 预计耗时录入：按分钟填写，配常用时长快捷芯片
- 四个状态（待开始 / 进行中 / 已完成 / 未完成）与手动流转
- 开始 / 完成计时，实时显示「已用 / 还剩 / 已超出」
- 任务结束后记录实际耗时、计算与预估的偏差；忘记计时可补记实际用时
- 记录偏差原因（突发琐事、效率不足、提前完成等），作为后续复盘样本

### 回看与补记
- 首页按日期前后翻看，回溯历史上的任意一天
- 翻到历史日可直接补记任务，任务归档到那一天，而不是今天

### 统计与复盘
- 统计页支持今日 / 本周 / 本月 / 全部四个时间窗口
- 完成情况：已完成、延期、未完成的占比
- 估时表现：整体预估与实际的中位倍率，以及各分类的偏差方向
- 分类耗时：工作 / 学习 / 生活 / 娱乐 / 健身各类别的时间占比
- 智能复盘建议：根据数据生成 7 类建议，每屏最多展示 3 条

### 同类任务参考
- 编辑页按分类取历史「实际 ÷ 预估」的中位倍率，给出建议预留时长
- 样本少于 3 条时明确提示「样本不足」，不拿两条记录编一个倍率
- 建议实时跟随分类与预估输入变化，不写死首帧

### 应用内提醒
- 任务接近或超过预估时，在首页进行中卡片上给出进度与超时提示
- 提醒只在应用内呈现：未签名构建下系统代理提醒配额为 0，因此不依赖系统通知

---

## 技术架构

```
Dayer
├── AppScope/                  应用级配置与资源
├── entry/                     主 HAP：界面与业务
│   ├── src/main/ets/
│   │   ├── pages/             首页（Navigation + NavPathStack）
│   │   ├── views/             编辑 / 详情 / 统计 / 列表项
│   │   ├── common/            纯逻辑模块（可本地单测）
│   │   ├── data/              RDB 建表、DAO、版本迁移
│   │   └── model/             数据模型与路由常量
│   └── src/test/              本地单元测试（hypium）
├── docs/                      需求、计划、验收截图与答辩材料
└── CLAUDE.md                  工程约束（API 15、ArkTS 规范、线程与沙箱规则）
```

**分层边界（刻意保持）**

1. `common/` 是纯逻辑层：不 import `@kit.*`、不使用 `$r()`，因此能被本地单测直接加载。
   偏差计算、统计口径、复盘规则、提醒计划都放在这里，界面只做展示。
2. 页面不直接拼 SQL：数据访问统一走 `data/TaskDao`，建表与版本迁移集中管理。
3. 路由统一走 `Navigation` + `NavPathStack` + `NavDestination`，参数传类实例而非对象字面量。

**技术栈**

| 层 | 选型 |
|---|---|
| 界面 | HarmonyOS NEXT Stage 模型 + ArkTS / ArkUI 原生组件 |
| 数据 | 本地关系型数据库（RDB），版本迁移，数据不出设备 |
| 构建 | hvigor + ohpm，API 15（5.0.3） |

---

## 构建与测试

需要 DevEco Studio 5.0.3 及以上、HarmonyOS SDK API 15。工程没有附带 `hvigorw` 包装脚本，使用 DevEco 自带的 hvigor：

```bash
export DEVECO_SDK_HOME="D:\DevEco Studio\sdk"
export PATH="/d/DevEco Studio/jbr/bin:$PATH"

"/d/DevEco Studio/tools/node/node.exe" \
  "/d/DevEco Studio/tools/hvigor/bin/hvigorw.js" \
  assembleApp --mode project -p product=default -p buildMode=debug --no-daemon
```

本地单测（hypium，不需要设备）：

```bash
"/d/DevEco Studio/tools/node/node.exe" \
  "/d/DevEco Studio/tools/hvigor/bin/hvigorw.js" \
  test --mode module -p module=entry@default -p product=default -p buildMode=test --no-daemon
```

> `BUILD SUCCESSFUL` 与退出码 0 **不代表用例通过**。逐条结果只认
> `entry/.test/default/intermediates/test/coverage_data/test_result.txt` 的末行。

设备端测试位于 `entry/src/ohosTest/`，需在模拟器或真机上运行。

---

## 代码进度

按 12 周计划推进，每个切片都有单测与设备验收记录。完整提交历史见
[Commits](https://github.com/Zyyt1124/Dayer/commits/main)。

| 阶段 | 内容 | 对应需求 | 提交 |
|---|---|---|---|
| 一 | 任务录入、状态流转、计时、实际耗时与偏差原因 | 一.1 / 一.2 / 二.1 | `841b430` |
| 二 | 首页按日期回溯、历史日补记 | 四.3 | `7b69c87` |
| 三 | 统计页：完成情况 / 估时表现 / 分类耗时 | 四.1 | `581e3d0` |
| 四 | 智能复盘建议、同类任务参考；统计标签修复 | 四.2 | `5a6dc33` |
| — | 仓库整理、文档归档、PPT 简约化、历史日停表修复 | — | `2226ef4` `e670ea5` `2792807` |

> 需求编号对应 [docs/设计思路.docx](docs/设计思路.docx)。

---

## 分支模型

| 分支 | 用途 |
|---|---|
| `main` | 稳定、可运行、可演示的主线；只接受 `develop` 的 fast-forward 合并 |
| `develop` | 集成分支；各功能完成自测后先合到这里 |
| `feature/<名称>` | 功能分支，从 `develop` 切出 |
| `fix/<名称>` / `hotfix/<名称>` | 缺陷修复；紧急问题从 `main` 切 `hotfix/` |
| `docs/<名称>` | 纯文档改动 |

已完成的历史切片保留了 `feature/*` 归档分支（指向当时的提交），只用于追溯，不再在其上开发。协作细则、提交信息格式、PR 检查清单见 [CONTRIBUTING.md](CONTRIBUTING.md)。

---

## 已知边界

- **系统通知受限**：未签名构建下代理提醒配额为 0，因此纠偏与超时提示改为应用内主动干预。
- **后台执行**：应用切后台会被系统冻结，长任务需要 `BackgroundTaskManager` 与分片 / 中断保存；当前版本以任务计时为主。
- **当前范围**：本仓库是第 6 周最小闭环的完整快照；第 7 周及之后的功能按 12 周计划继续推进，暂不在本仓库中。
- **数据**：全部落在应用私有沙箱的本地数据库中，不申请网络权限。

---

## 文档

需求文档、实现计划、验收截图与答辩材料都在 [docs/](docs/README.md)。
