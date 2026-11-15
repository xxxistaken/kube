# Agent Note: 以 faary 作为业务主命名空间并下线 xxxistaken 单元

Status: implemented

## Problem

仓库从初始化起用 `namespaces/xxxistaken/` 作为占位单元：目录名、Namespace 对象名与 `managed-by` 值都沿用了当时的临时代号，与品牌名无关。`faary` 是我们的品牌名，业务应用需要一个以品牌命名的正式命名空间；开发者在本地运行 faary 时使用的 PostgreSQL（`development` 单元，仅本地）也已按 `faary` 数据库/用户准备（见 [PostgreSQL note](2026-11-14-add-development-postgresql.md)）。占位名长期留着有两个代价：README 的“新增命名空间”流程以它当模板，占位名会被复制到后续每一个单元；业务资源与占位名绑定后再改名，要连带迁移所有对象、Secret 引用与 RBAC。

集群里的 `xxxistaken` 正好处于可以下线的状态：命名空间内只有集群自动生成的 `default` ServiceAccount 与 `kube-root-ca.crt`，没有任何工作负载、数据或手工创建的 Secret。

## Decision

- 把 `namespaces/xxxistaken/` 重命名为 `namespaces/faary/`（`git mv`，文件历史随重命名保留），并把标识逐处改成业务名：`namespace.yaml` 的 `metadata.name` 与 `app.kubernetes.io/name`、`kustomization.yaml` 的 `managed-by` 值、`apply.sh` 帮助里的示例路径。
- `namespaces/faary/` 与既有单元同构：`apply.sh` 的命名空间名由目录名推出，`prune_allowlist` 当前只有 `core/v1/Namespace`（单元里还没有其它资源类型）。
- 文档把 `faary`（品牌名）记为业务主命名空间：README 的目录说明、`kubectl diff/apply` 示例、prune 示例、`apply.sh` 示例与“新增一个命名空间”的复制模板全部指向 `namespaces/faary/`；`PROJECT_STRUCTURE.md` 目录表同步。`development/apply.sh` 帮助里残留的 `xxxistaken` 示例路径一并改掉。
- 集群侧：`./namespaces/faary/apply.sh --yes` 创建 `faary`（先 server dry-run，再 apply），确认对象带 `managed-by=faary`；随后 `kubectl delete namespace -l managed-by=xxxistaken` 删除旧命名空间。删除前已确认命名空间内只有集群自动生成的对象。
- README 更正了一处回收语义：单元目录被整体删除后，它自己的 `apply.sh` 也消失，`--prune` 不会再为该单元执行，下线单元必须按同一标签选择器显式删除命名空间，回收边界仍是 `managed-by=<ns>`。

验证：`kubectl kustomize namespaces/faary` 渲染出单个 `Namespace faary`（含 `managed-by: faary`）；`apply.sh --dry-run` 的 server dry-run 无报错，`apply.sh --yes` 后 `kubectl get ns faary -o yaml` 带上了 `managed-by: faary` 与 last-applied 注解；`kubectl delete namespace -l managed-by=xxxistaken` 删除了唯一匹配的 `xxxistaken` 命名空间，`kubectl get ns` 中不再出现该名字。

## Alternatives considered

- **保留 `xxxistaken` 作为新增单元的模板**——少改几处文档，但占位名会继续被复制进后续单元，业务命名空间也仍不明确；落选。
- **只新增 faary、暂时保留 xxxistaken**——两个命名空间都指向“业务主”会长期分叉，空置的占位命名空间还占着名字；用户已明确要下线它；落选。
- **原地给 Namespace 改名**——Kubernetes 不支持重命名 Namespace，对象必然删除重建，与“新建 faary + 删除 xxxistaken”等价，却要多走一次旧的 `apply`；落选。
- **把 faary 放进 development 或做成它的 overlay**——业务命名空间与本地开发依赖混在一起，破坏“一个目录 = 一个命名空间单元”的布局，overlay 还要额外 patch 掉继承的 Namespace 对象；落选。
- **用 `kubectl apply --prune` 回收 xxxistaken**——单元目录删除后其 `apply.sh` 一并消失，prune 没有入口；为了删一个空命名空间而保留死目录与死脚本不划算；落选。

## Consequences

- 业务主命名空间 `faary` 存在并由 `namespaces/faary/apply.sh` 独立管理；占位命名空间 `xxxistaken` 已同时从仓库与集群移除。
- 文档与模板都指向 faary，新单元不会再继承占位名；`development` note 中“不会碰到 xxxistaken 单元”的现在时表述已同步为 faary，历史性的“由 xxxistaken 复制”保留并链到本 note。
- `development` 的定位在文档里与 `faary` 明确分开：`faary` 是生产业务主命名空间（品牌名），`development` 只是开发者本地环境的便捷工程，不进入任何生产环境，两者不共享命名空间或发布流程。
- `faary` 单元目前只有 Namespace 对象：业务资源放进来时，必须把对应类型补进该单元的 `prune_allowlist`（只增不减），否则这些对象不会被回收。
- 删除单元不能靠自带的 prune：单元目录删除后脚本不存在，只能按 `managed-by=<ns>` 选择器显式 `kubectl delete` 命名空间；这一点已写进 README。
- 仓库目录名 `xxx.kube` 与远端 GitHub 组织 `xxxistaken` 仍带占位名，本次只处理命名空间对象，未改动仓库/组织名。
