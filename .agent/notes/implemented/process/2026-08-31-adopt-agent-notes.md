# Agent Note: 启用 agents notes

Status: implemented

## Problem

`PROJECT_STRUCTURE.md` 是持续更新的项目简要总结，记录"现状是什么"，但代码和文档无法承载的*为什么*以及*放弃了什么*散落在会话历史里，新会话无法可靠重建。参考仓库 `dev-reference/deepseek-harness-master/.agents/notes` 提供了一套维护完善、结构清晰的 agents notes 机制，本工作区需要同样机制来固化跨仓库决策。

## Decision

在 `.agent/notes/` 下启用 agents notes，沿袭 deepseek-harness `.agents/notes` 的组织逻辑：

- **路径编码**：`{lifecycle}/{class}/yyyy-mm-dd-topic-title.md`。生命周期为顶层文件夹（`proposed/` → `implemented/`，否决的转 `rejected/`，已落地且不再指导未来的 implemented 记录移入冻结的 `archived/`）；类别为嵌套文件夹，封闭集合为 `feature` / `bug-fix` / `simplification` / `architecture` / `process` / `testing`。文件名日期是主题首次提出时间，交叉引用用相对 Markdown 链接，不设集中式 `INDEX.md`。
- **文件格式**：头部块严格为 `# Agent Note: <title>` + 空行 + `Status: <status>`；正文以 `## Problem` 开头，按生命周期使用规范骨架（proposed: `## Proposal` / `## Acceptance criteria` / `## Risks`；implemented: `## Decision` / `## Consequences`，且禁止 `## Proposal` 等提案期标题；rejected: 冻结提案并只在状态行写原因）；每份 note 必含 `## Alternatives considered`。
- **写入义务**：每个非平凡变更（行为、架构、跨包约定、流程/工具、测试策略、存储/协议/配置格式）必须在同一变更中新增或更新至少一份 note；只允许机械/局部编辑豁免。更新已持有该决策的 note 即满足规则，不建重复记录。
- **维护纪律**：implemented note 与交付内容同步（路径/符号/默认值变更时同变更就地更新事实，不改写决策本身）；新 note 触发取代检查；归档/合并/删除按 [README.md](README.md) 规则执行。

相对参考的两处适配：

- **中文单语**：每份 note 只有一个 `.md` 文件，中文撰写；不维护 `.zh.md` 对侧与 `.i18n.yaml` 一致性记录（本工作区无 i18n 基建）。
- **无自动化门禁**：deepseek-harness 用 pnpm 脚本（`verify-agent-note-format`、`verify-translation-pairing` 等）机器校验；本工作区没有该基建，格式与配对靠 review 把关，[README.md](README.md) 即规范。

## Alternatives considered

- **不引入任何机制，继续依赖 `PROJECT_STRUCTURE.md` + 会话记忆**——`PROJECT_STRUCTURE.md` 按设计是"持续更新的项目简要总结"，只承载现状概览；会话记忆不可重建、不可检索。落选。
- **照搬 deepseek-harness 的完整基建（双语三元组 + 校验脚本）**——本工作区无 i18n 约定、无 pnpm 工作区脚本链，整套搬入徒增维护面；保留其组织逻辑、裁剪其基建是性价比更高的适配。落选。

## Consequences

- 跨仓库的"为什么/放弃了什么"从此有唯一归属地，新会话可先读 `PROJECT_STRUCTURE.md` 了解现状，再查 `.agent/notes/` 重建决策依据。
- 非平凡变更的变更面变大：同一变更里要新增或更新 note；作为回报，决策依据不再随会话丢失。
- 无机器校验，格式纪律依赖 review；notes 数量增长后归档纪律（`archived/` 冻结）防止目录树膨胀。
- 三个代码仓库仍以各自 git 历史为准，note 只作为决策记录，不替代代码、不替代 `PROJECT_STRUCTURE.md` 的现状描述。
