# 协作与分支规范

## 分支模型

```
main        ← 稳定可演示（只接受 develop 的 fast-forward）
 └─ develop ← 集成（功能自测后合入）
     ├─ feature/<名称>   新功能
     ├─ fix/<名称>       缺陷修复
     └─ docs/<名称>      纯文档
hotfix/<名称>  从 main 切出，修完同时回合 main 与 develop
```

- **`main`**：任何时刻都能 `assembleApp` 出可安装包、能演示。不直接在 `main` 上写功能代码。
- **`develop`**：日常集成分支。功能分支从它切出，完成后 `--no-ff` 合回。
- **`feature/*`、`fix/*`、`docs/*`**：命名用小写短横线，例 `feature/repeat-task`、`fix/timer-resume`。
- 已完成的历史切片保留为 `feature/*` **归档分支**（指向当时那次提交），仅供追溯，不再在其上开发。

## 提交信息

格式：`<范围>：<做了什么>`

- 一个提交 = 一个可验收的切片，不混入无关改动。
- 范围用模块或界面名：`统计页`、`编辑页`、`端侧推理`、`数据库`、`构建`。
- 写清「改了什么、为什么」，不写 `update`、`fix bug`、`修改一下` 这类无信息量的消息。
- 示例：
  - `统计页：并排展示采纳后与不采纳时的中位倍率`
  - `编辑页：预计耗时支持选完成时间点反推`
  - `数据库：给 task 表加 estimate_mode 列并升到 v3`

## 合并

| 场景 | 命令 |
|---|---|
| 功能 → develop | `git merge --no-ff feature/xxx` |
| develop → main | `git merge --ff-only develop`（保持主线线性） |
| 紧急修复 | `hotfix/*` 合回 `main` 与 `develop` |

- 合并前先 `git pull --rebase` 更新自己的分支并解决冲突，不把冲突带进 `develop`。
- 合并后删除已完成的短命分支（归档分支除外）。

## PR 检查清单

提 PR 前逐条确认：

- [ ] `assembleApp --mode project` 构建通过（只跑 `assembleHap` 不会打入 HSP）
- [ ] 构建日志中 `ArkTS:WARN` 与 `supported since SDK version` 版本警告均为 **0 条**
- [ ] 本地单测全过 —— **读 `entry/.test/default/intermediates/test/coverage_data/test_result.txt` 末行**，
      不看 `BUILD SUCCESSFUL`、不看退出码（它们都会骗人）
- [ ] 新增/修改逻辑有对应单测；关键断言做过变异检验（改坏实现，确认恰好那条用例变红）
- [ ] 改了 schema 就带迁移并升 `DB_VERSION`；只加 SELECT 的改动不动版本号
- [ ] 涉及 UI / 数据库的改动附设备验收记录：操作步骤 + 预期 + 实际
- [ ] 不提交构建产物、`local.properties`、`.accept_layout.json`、验收用数据库

## 工程约束（摘要）

完整约束见 [CLAUDE.md](CLAUDE.md)。新的贡献者最常踩的几条：

1. **API 15 锁定**：不得使用 API 16+ 接口，不得使用标 `@deprecated` 的接口。超版本接口编译**只警告不报错**，必须 grep 构建日志确认。
2. **UI 只用 ArkUI 原生组件**：页面用 `@Entry`，自定义组件用 `@Component`；路由用 `Navigation` + `NavPathStack` + `NavDestination`，不用 `router`。
3. **资源不硬编码**：字符串、颜色、尺寸、图片统一放 `entry/src/main/resources/`，用 `$r()` 引用。
4. **主线程不重算**：耗时计算放 Worker，跨线程对象必须 `@Sendable`；原生调用只从 `views/` 发起，不污染可单测的 `common/`。
5. **日志用 `hilog`**，所有可能失败的系统调用（数据库、文件、权限、路由、NAPI）都必须有 catch 与日志。
6. **`@Builder` 默认无参**：需要状态的 builder 直接读 `this.*`，传参会退化成按值传递、首帧定格。
