# Agent Note: Kubernetes 配置仓库的布局与命名空间单元

Status: implemented

## Problem

本仓库用于集中管理微服务的 Kubernetes 配置，直到本次变更前只有空的占位文件：资源放在哪里、以什么粒度组织、如何被渲染与应用，都还没有约定。第一个落地的资源（`xxxistaken` 命名空间）会为后续每个服务设定先例，而布局的迁移成本随资源数量增长，因此需要在其出现时就把规则定下来。

约束是：单个条目可独立 diff 与 apply；新增命名空间、工作负载时无需重新设计；不绑定具体交付工具——运营方可能用 `kubectl`、Argo CD 或 Flux。

## Decision

仓库按“资源单元”组织。`namespaces/<namespace>/` 存放该命名空间及其基础配置：`namespace.yaml` 声明 Namespace 对象，`kustomization.yaml` 用 `resources` 显式列出同目录资源。目录本身即是可由 `kubectl apply -k` 渲染与应用的整体，因此也天然是 GitOps 控制器的同步目标。

具体规则：

- 目录名与对象 `metadata.name` 一致，统一 kebab-case。
- 命名空间级对象不写 `metadata.namespace`，交由应用方（`-n`、overlay 或 CD 控制器）决定归属。
- 不设 `base/` + `overlay/` 分层：当前只有一个命名空间、一个目标环境，没有可提炼的差异。出现第二个环境或集群时再拆分，届时 `namespaces/` 本身可作为 base。
- 命名空间清单只含 Namespace 对象本身，不附带 ResourceQuota、LimitRange 或 PodSecurity 标签。这些是策略性资源，会决定工作负载能否调度，需要以实际资源请求与安全基线为依据。

## Alternatives considered

**平铺单文件（根目录 `xxxistaken-namespace.yaml` 等）。** 出现第二个命名空间和第一批工作负载后，根目录迅速失去可读性；也没有“一个单元一个目录”的边界，CD 无法以目录为单位同步。否决。

**顶层 `clusters/<cluster>/` 或 `environments/<env>/`。** 目前只有一个集群、一个环境，这一级会出现在每条路径上却不承载任何差异，属于为想象中的需求付费。等真实差异出现再引入 overlay 更便宜。否决。

**用 Helm chart 管理命名空间。** 单个 Namespace 对象没有模板参数，Helm 只带来 values 文件与额外的渲染步骤；Kustomize 由 `kubectl` 内置，零安装成本。否决。

**在命名空间清单中附带 ResourceQuota / LimitRange / PodSecurity 执行标签。** 目前没有工作负载，配额只能靠猜；猜小的配额会阻塞部署，而安全基线应当由集群策略统一决定。若需要，属于独立提案。推迟。

## Consequences

- 新增命名空间是机械操作：复制 `namespaces/xxxistaken/` 并改名，路径即文档。
- 应用与预览各一条命令：`kubectl apply -k namespaces/xxxistaken`、`kubectl diff -k namespaces/xxxistaken`。
- 代价：布局把“一个命名空间一个目录”固定下来，跨命名空间共享的对象（ClusterRole、StorageClass 等）暂无归属；需要时新增顶层目录（如 `cluster/`）并另写 note，而不是塞进某个命名空间目录。
- 代价：没有 overlay 分层，意味着出现环境差异时必须先补上 base/overlay 结构；在此之前各环境共享同一份清单。
