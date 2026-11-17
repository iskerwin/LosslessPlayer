# Lossless：自动化开发约定

适用于整个仓库。测试与发布流程见 [云端测试与发布](docs/ci-and-release.md)，界面规范见 [docs/ios-ui-spec.md](docs/ios-ui-spec.md)。

本仓库约定文档中的 MUST、MUST NOT、SHOULD、SHOULD NOT、MAY 按 RFC 2119 与 RFC 8174 解释，且仅在以全大写出现时具有该含义。

## 沟通与授权

- 说明用户能看到的变化 MUST 用白话中文。代码存在、CI 通过、可以安装、手机验收是四件不同的事，MUST 分开说明，MUST NOT 互相代替。
- 新功能或改变已有行为、交互：MUST 先说明以前/以后看到什么和做法，取得 Kerwin 确认。修 bug：MUST 先报告原因和打算的修法。已确认的范围 MAY 直接推进。
- 只做功能和实际问题修复；MUST NOT 做无明确需要的改名、格式整理或重构。

## 改动与测试

- 一件事 MUST 一个分支、一个 PR，MUST 只经 PR 合并进 main；MUST NOT 直接推 main。合并前 `Lossless CI / gate` MUST 通过。
- 本机 MUST NOT 编译 App、跑 Swift 测试或模拟器；本机只跑 `python3 tools/ship.py check` 和 Python 工具测试。指定测试 SHOULD 用 `ship.py test --only Target/Class[/method]`。
- 每个 bug 修复 MUST 配一个修复前会失败的回归测试，SHOULD 放在能覆盖它的最低一层：能在单元测试验证的 SHOULD NOT 放界面测试。
- 测试失败 MUST 修业务或测试的真实原因：MUST NOT 删测试、放宽断言、改时限，或靠反复重跑凑绿。测试尚未开始的环境故障 MAY 重跑。未跑、失败和中断 MUST 如实记录，MUST NOT 写成通过。已知失败 MUST 报告给 Kerwin，由他决定开发版是否继续。
- MUST NOT 用固定延时或「先等某个元素出现」的门掩盖时序问题；MUST 先用证据（`.xcresult`、截图、录屏）找到真实机制。
- 同一页切换内容（分段、面板、图表点选、按钮或提示的出现与消失等）时，切换前后高度和位置 MUST 保持不变，避免内容跳动。改到这类界面时 MUST 配一个比较切换前后高度或位置的 UI 测试，并 SHOULD 按常用字号、较大字号与窄屏各看一次。
- 用户可见改动 MUST 先发 `ship.py preview` 预览包，请 Kerwin 在手机上验收；通过后再跑相关测试，`Lossless CI / gate` 通过后再合并。草稿 PR 不跑 gate，转为可审查时运行。PR 检查与开发版共用选测和执行程序，实际范围与原因 MUST 写进任务摘要。
- 每周日 22:00（北京时间）对 main 跑全量，只验证不发布；失败 MUST 按业务、测试或环境的真实原因修复。
- 改动 `tools/select_tests.py` 的对应关系时 MUST 同步更新 `tools/test_select_tests.py`；新增被选测依赖的源码文件 MUST 补映射。未映射的 App 源码走整个单元测试目标，不因此拉起整套 UI 测试，实际范围和未映射文件 MUST 写进任务摘要。只有文档的改动只跑静态检查与工具测试；工具、工作流、测试和工程配置改动仍走全量。

## 更新记录（CHANGELOG）

- 助手 MUST 随每项改动维护 `CHANGELOG.md`，Kerwin 不必手写。功能或修复 MUST 在当前版本小节按「新增 / 修复 / 改进」写用户可见变化，保留累计条目；措辞 MUST 按事实，MUST NOT 把代码合入、CI 通过或可安装写成手机验收通过。
- 开发版、预览包发布说明和安装源 `apps.json`（Zeus 使用）的更新描述从 CHANGELOG 当前版本小节生成，保留测试范围说明；文件缺失或小节为空时使用原有样板。
- 开始新版本 MUST 只用 `python3 tools/ship.py version patch|minor|major|X.Y.Z` 提高版本号，新版本 MUST 严格高于当前版本；命令只改工作区，由使用者提交。CHANGELOG 顶部 MUST 以「## X.Y.Z（开发中）」起新小节，经 PR 合入。
- 开发期间持续累积当前小节。Kerwin 手机验收并确认转正后，MUST 把标题改为「## X.Y.Z（YYYY-MM-DD 发布）」（北京时间的发布日期），单独开一个 PR；下一版本重新起开发中小节。

## 发布

- 开发版 MUST 只对已在 main 上的源码发布：`python3 tools/ship.py dev`。失败时源码可以已在 main，但不发布安装包，结论 MUST 写「源码已在 main，未发布安装包」。
- 界面或交互改动 MUST 先发预览包（`ship.py preview`）请 Kerwin 在手机上确认，通过后再跑相关测试，gate 通过再合并。
- MUST NOT 删除 Release 和标签，MUST NOT 删除 main，MUST NOT 强推或重写 main 历史。PR 合并后 MUST 删除它的分支。
