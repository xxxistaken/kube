# Agent Note: 新增 development 命名空间单元

Status: implemented

## Problem

仓库此前只有 `namespaces/xxxistaken/` 一个命名空间单元，开发/测试类负载没有独立的命名空间归属。按既有布局，一个目录 = 一个可独立 apply 的单元，`managed-by=<ns>` 标签同时决定该单元的 prune 回收边界；把开发资源混进 `xxxistaken` 会让两类负载共享同一个命名空间和回收边界，删减开发侧资源时无法按单元隔离。需要沿用既有布局新增一个 `development` 单元。

## Decision

新增 `namespaces/development/`，内容由 `namespaces/xxxistaken/` 复制并改名：

- `namespace.yaml`：`Namespace` 对象名为 `development`，标签 `app.kubernetes.io/name: development`；不写 `metadata.namespace`，归属由 `-n` 决定。
- `kustomization.yaml`：`resources` 显式列出 `namespace.yaml`；`labels` 转换器注入 `managed-by: development`（`includeSelectors: false`），仍是单元内该标签的唯一来源。
- `apply.sh`：与 `xxxistaken/` 的脚本逐字一致，未做重命名——命名空间名由脚本所在目录推出，帮助里的示例路径仅为示意。`prune_allowlist` 当前仍只有 `core/v1/Namespace`；该单元后续出现新资源类型时，往同一个数组里追加，列表只增不减。
- `PROJECT_STRUCTURE.md` 的目录表补充该单元。README 的“新增一个命名空间”流程无需改动，本单元正是按该流程产生。

两个单元相互独立：`./namespaces/development/apply.sh` 只应用并 prune `-l managed-by=development` 的对象，不会碰到 `xxxistaken` 单元的资源。

## Alternatives considered

- **复用 `xxxistaken` 命名空间**——省一个单元，但开发负载与既有负载共享命名空间和 prune 边界，无法独立回收，对象也混在一起；落选。
- **把 development 作为 `xxxistaken` 的 overlay 子目录**——overlay 会继承 base 的 `Namespace` 对象与 `managed-by` 值，命名空间对象仍需 patch 改名，单元与命名空间不再一一对应，还要另配 apply 路径与脚本；破坏既有“一个目录 = 一个命名空间单元”的布局；落选。
- **把 Namespace 对象集中放到顶层 `cluster/` 目录**——该目录目前不存在，而且 Namespace 对象本身就带单元标签、由各单元自己回收；集中放置会改变已有的回收模型；落选。
- **命名空间改叫 `dev`**——用户指定 `development`，且目录名、对象名、标签值三者必须一致；落选。

## Consequences

- 开发负载有了独立的命名空间与回收边界，可以单独执行 `kubectl diff/apply -k namespaces/development -n development`；README 里的批量同步循环会自动带上它。
- 多一个需要维护的单元：开发侧资源要放进该目录，新增资源类型时记得扩充它的 `prune_allowlist`（只增不减）。
- 沿用既有风险：`prune_allowlist` 含 `core/v1/Namespace`，删除该目录后 prune 会连 Namespace 一起删除，并级联清空其中的资源。
- 跨命名空间/集群级共享资源（如 ClusterRole）仍无归属目录，本变更不引入这类资源。
