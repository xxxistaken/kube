这是一个 Kubernetes 配置集中管理仓库 (微服务集群的声明式 YAML, 用 Kustomize 组合, 不含应用代码).

包含一个'PROJECT_STRUCTURE.md', 是持续更新的项目简要总结, 请直接读取此文件了解项目整体结构, 每次修改代码后如需要请更新.

`.agents/notes/` 维护本工作区的 agents notes (决策/提案记录), 规则见 `.agents/notes/README.md`. 每个非平凡变更必须在同一变更中新增或更新至少一份 note (行为/架构/跨包约定/流程工具/测试策略/存储协议配置格式变更均属非平凡).

## git commit 署名

agent 创建 commit 时, 必须以 co-author trailer 标注**自己的**身份; 多个 agent 参与同一次提交时, 每个 agent 各写一行:

```text
Co-authored-by: DeepSeek Harness <noreply@deepseek.com>
Co-authored-by: Claude Code <noreply@anthropic.com>
```

- 使用该 agent 自身的名称与 noreply 邮箱, 不要复用其它 agent 的标识, 也不要用 `agent` 这类泛化字面量——那样无法区分是哪个 agent 改的.
- 同一个 agent 在后续提交中复用同一个标识字符串, 便于按名称检索.
- 无论改动由谁发起, 只要 commit 由 agent 创建就带上 trailer; 人类 author 保持不变, 人类主导的 commit 不必补.
- agent 产出的 note 与代码/配置属于同一个变更, 放进同一个 commit, 不要拆成"先代码后补 note".
