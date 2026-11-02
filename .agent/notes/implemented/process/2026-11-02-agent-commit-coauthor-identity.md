# Agent Note: agent 提交的 co-author 身份

Status: implemented

## Problem

本仓库由人类与多个 agent 共同改动, 需要一条不依赖 reviewer 记忆的署名约定, 让 review 与历史能回答两件事：这次提交有没有 agent 参与, 以及是哪个 agent。

只回答第一件事是不够的。多个 agent 在同一工作区交替工作时, 若所有提交都写同一个泛化标识, 不同 agent 的产出在历史里完全同形：无法判断某条配置由谁引入、某次否决由谁提出, 也无法在接入新 agent 后单独审视其产出。而配置仓库的变更代价高（一次 apply 就作用于集群）, 追溯"谁改的、依据什么"是 review 的刚需。

## Decision

agent 创建 commit 时, 在 message 末尾以自己的身份添加 co-author trailer, 一个 agent 一行：

```text
Co-authored-by: DeepSeek Harness <noreply@deepseek.com>
Co-authored-by: Claude Code <noreply@anthropic.com>
```

- 名称与邮箱来自该 agent 自身的身份, 不复用其它 agent 的标识, 也不使用 `agent` 这类泛化字面量。
- 同一个 agent 保持稳定的标识字符串, 跨提交复用, 使 `git log --grep` 能按 agent 枚举。
- 多个 agent 参与同一次提交时各写一行；trailer 只在 commit **由 agent 创建**时添加, 人类自己提交的 commit 不必补。
- 身份由各 agent 自行声明, 仓库不维护集中名单；接入新 agent 不需要修改本仓库的任何文件。

## Alternatives considered

**所有 agent 统一写 `Co-authored-by: agent <agent@localhost>`。** 只编码"有 agent 参与", 无法回答"哪个 agent"；在多个 agent 共享工作区的场景下, 历史里每人产出同形, 正是本 note 要消除的缺口。否决。

**集中在本文件维护"agent 名称 → 标识"注册表。** 身份本应只有 agent 自己知道, 集中登记意味着每接入一个新 agent 都要改仓库、并让登记表与真实使用持续同步; 漂移后的名单比没有名单更误导。否决。

**把 agent 设为 commit 的 author。** author 字段是单值的, 设成 agent 就等于抹掉人类 owner, 而人类才是对仓库负责、能承担 review 的主体；且多数托管平台按 author 关联账号, 用不存在的邮箱会造成贡献统计与 blame 归属割裂。co-author 既保留人类为 author, 又记录参与方。否决。

**在 commit subject 加 `[agent]` 或 `[claude]` 前缀。** 前缀污染每条 subject, 破坏按 scope 的检索与 changelog 生成规则；且 subject 只有一个位置, 多个 agent 参与时无法列出全部。否决。

**只在正文写一句"由 agent 生成"。** 自由文本无法被工具提取, 也没有类型化的键可供 `git log --grep` 或托管平台解析成 co-author。否决。

**不设规则, 由 agent 自觉说明。** 行为会被遗忘, 而这条信息恰恰是历史记录需要的。否决。

## Consequences

- `git log --grep='Co-authored-by: DeepSeek Harness'` 之类按 agent 枚举提交, review 时能直接看到是谁参与。
- 人类 author 保持不变, blame 与账号归属不受影响；co-author 支持多方, 协作场景不会被压平成一个名字。
- 代价：标识字符串由各 agent 自己决定, 仓库不做规范化, 历史中可能出现相似但不一致的写法（如是否附带模型名）。缓解手段是要求同一 agent 复用同一字符串, 靠自律而非门禁。
- 代价：规则目前靠自律执行, 没有 commit-msg hook 强制; 若后续需要机器校验, 可加 hook 检查 trailer 是否匹配已使用过的标识集合, 届时另立 process note。
