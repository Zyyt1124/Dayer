# 文档索引

## 需求与设计

| 文档 | 说明 |
|---|---|
| [设计思路.docx](设计思路.docx) | 需求文档：功能清单、交互设计与技术选型 |
| [plans/首页按日期回溯历史任务.md](plans/首页按日期回溯历史任务.md) | 历史回溯切片的实现计划 |
| [plans/历史日补记.md](plans/历史日补记.md) | 历史日补记切片的实现计划 |

## 验收截图

[`screenshots/`](screenshots/) 收录真机 / 模拟器验收时导出的界面截图，覆盖任务列表、编辑、详情、
统计与边界状态，按 `shot01`–`shot28` 编号，另有一张验收对照图。

## 开题答辩材料

| 文档 | 说明 |
|---|---|
| [Dayer开题答辩.pptx](Dayer开题答辩.pptx) | 开题答辩演示文稿 |
| [开题报告PPT制作思路.md](开题报告PPT制作思路.md) | PPT 的内容结构与讲述逻辑 |
| [开题答辩讲稿.md](开题答辩讲稿.md) | 答辩口播稿 |
| [开题答辩术语白话解释.md](开题答辩术语白话解释.md) | PPT 中术语的白话解释 |
| [引用核查报告.md](引用核查报告.md) | 开题引用逐条核查与出处 |
| [build_ppt.py](build_ppt.py) | 用 python-pptx 生成答辩 PPT 的脚本 |

> 若要重新生成 PPT，请用 Python 3.13 运行 `build_ppt.py`；手改过的版本不要被脚本覆盖。

## 相关链接

- 仓库主页与功能说明：[../README.md](../README.md)
- 协作与分支规范：[../CONTRIBUTING.md](../CONTRIBUTING.md)
- 工程约束（API 15、ArkTS 规范、线程与沙箱规则）：[../CLAUDE.md](../CLAUDE.md)
