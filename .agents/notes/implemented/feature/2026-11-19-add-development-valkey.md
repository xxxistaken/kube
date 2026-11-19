# Agent Note: development 命名空间加入 Valkey

Status: implemented

## Problem

`development` 是开发者本地环境的共享依赖单元，已经有 PostgreSQL（见 [PostgreSQL note](2026-11-14-add-development-postgresql.md)）。本地运行 faary 应用时还缺一个 Redis 协议兼容的键值服务，用来放缓存、会话或临时数据；让每个开发者自己在宿主机安装 Redis/Valkey、管理端口和版本，既不可复现，也容易和应用配置脱节。

期望与 PostgreSQL 同构：一个声明式清单、独立的回收边界、稳定的服务名，并且数据在 Pod 重建后仍然保留；该单元只在开发者本机/本地集群应用，不进入生产。版本按用户指定使用浮动 tag `valkey/valkey:9-trixie`。

## Decision

在 `namespaces/development/` 新增三个清单，并在 `kustomization.yaml` 的 `resources` 中显式列出：

- `valkey-statefulset.yaml`：单副本 `StatefulSet valkey`，镜像 `valkey/valkey:9-trixie`；`args` 为 `valkey-server --dir /data --appendonly yes --appendfsync everysec`；数据卷由 `volumeClaimTemplates` 声明（1Gi、`ReadWriteOnce`、默认 StorageClass），挂载到 `/data`；就绪与存活探针都是 `valkey-cli ping`；容器内存上限 512Mi。
- `valkey-headless-service.yaml`：`clusterIP: None` 的 `valkey-headless`，作为 StatefulSet 的 governing Service，给 `valkey-0` 稳定网络标识。
- `valkey-service.yaml`：`ClusterIP` 的 `valkey:6379`，供本地运行的应用按服务名连接。

`apply.sh` 无需改动：它的 `prune_allowlist` 已包含 `core/v1/Service` 与 `apps/v1/StatefulSet`；PVC 由 StatefulSet 控制器创建、不带 `managed-by` 标签，故意不列入回收类型（与 PostgreSQL 的处理一致）。

关键取舍：

- **不设访问密码**：集群侧预先存在的 Secret `secrets` 只有 `dbPassword` 键，没有 Valkey 密码；本仓库也不存放密码。镜像在构建时已关闭 protected-mode，Valkey 只通过 ClusterIP 在集群内暴露，没有 NodePort、Ingress 或 LoadBalancer。本地开发集群接受这个边界，README 已声明该单元不进入生产。
- **AOF 持久化**：`--appendonly yes --appendfsync everysec` 让每次写入最多丢 1 秒；默认 RDB 快照点保留。这样 `kubectl delete pod` 或节点重启后缓存/会话仍然可用，更贴近“共享开发依赖”的定位。
- **单副本 StatefulSet**：本地开发没有高可用需求；用 StatefulSet 只是为了 `volumeClaimTemplates` 和稳定标识，不配置主从、Sentinel 或 Cluster 模式。
- **浮动 tag**：用户指定 `9-trixie`，跟随 9.x 的最新 trixie 构建；代价是重新拉取镜像时可能升级到新的 9.x 补丁版本（见 Consequences）。
- **不设 `maxmemory`**：把淘汰策略留给使用者；容器 512Mi 上限内 Valkey 可以自由使用内存，超过上限会被 OOMKill 而不是静默淘汰 key。
- **权限交给镜像 entrypoint**：镜像的 `ENTRYPOINT` 以 root 启动，把 `/data` 属主改为 `valkey` 后用 `setpriv` 降权，因此清单里不写 `runAsUser`/`fsGroup`，也不需要 initContainer。`args` 的第一个参数必须是 `valkey-server`，entrypoint 依赖它判断是否需要 chown 和降权。

## Verification

2026-11-19 在 orbstack 集群（kubectl v1.32.3，server v1.36.5）验证：

- `./namespaces/development/apply.sh --dry-run` 显示 `service/valkey`、`service/valkey-headless`、`statefulset.apps/valkey` 为 created，PostgreSQL 的三个对象为 unchanged/configured；随后 `apply.sh --yes` 实际应用。
- `valkey-0` 变为 `1/1 Running`，PVC `data-valkey-0` 绑定 1Gi；事件里镜像 `valkey/valkey:9-trixie` 拉取成功，容器内 `valkey-server --version` 为 `9.1.4`。
- 在临时 Pod 中执行 `valkey-cli -h valkey ping` 返回 `PONG`，确认 ClusterIP Service 可以按服务名访问。
- 写入 `smoke:key=hello` 后删除 `valkey-0`，重建后 `get smoke:key` 仍返回 `hello`；`/data/appendonlydir` 下存在 AOF 文件，`INFO persistence` 的 `aof_enabled` 为 `1`。
- `kubectl diff -k namespaces/development -n development` 输出为空，PostgreSQL 未受影响。

## Alternatives considered

- **Deployment + 手写 PVC**——没有 `volumeClaimTemplates` 和稳定 Pod 标识，PVC 与 Pod 的绑定要自己维护；落选。
- **不持久化（`emptyDir` 或纯内存）**——更简单，但 Pod 重建即丢数据，作为共享开发依赖需要应用每次重建缓存；落选。
- **把 Valkey 放进 `faary` 命名空间**——Valkey 只在本地开发使用，混进业务命名空间会共享 `managed-by=faary` 的回收边界，删减本地依赖时可能影响业务对象；落选。
- **固定到 `9.1.4-trixie`**——可复现性更好，但用户明确要求 `9-trixie`；落选。
- **设置 `requirepass`**——需要新增 Secret 键或把密码写进仓库：前者要求集群侧先准备一个不存在的键，后者把密码入库；两者都超出本单元职责；落选。若日后需要认证，应新增外部 Secret 键并以 `secretKeyRef` 注入 `--requirepass`。
- **改用 Redis 官方镜像**——协议兼容且更常见，但该依赖已选定 Valkey，tag `9-trixie` 也由用户指定；落选。
- **主从 / Sentinel / Cluster**——本地开发没有故障转移和分片需求，三副本还会把内存与卷占用放大三倍；落选。
- **设置 `maxmemory` 与 `allkeys-lru`**——能避免 OOMKill，但会静默淘汰被应用当作持久数据使用的 key；不替使用者决定语义；落选。

## Consequences

- `development` 单元增加 1 个 StatefulSet、2 个 Service 和 1Gi 的 PVC；本地集群多占约 512Mi 内存上限和 1Gi 磁盘。
- 任何能访问 `development` 命名空间的 Pod 都可以无认证读写 Valkey。不要在任何生产环境应用该单元；不要把端口转发暴露到不可信网络。
- `9-trixie` 是浮动 tag：节点重新拉取镜像时可能拿到新的 9.x 版本。需要可复现或固定补丁版本时改成 `9.1.4-trixie` 这类具体 tag，并在 note 中记录。
- AOF 会持续增长，Valkey 会按 `auto-aof-rewrite-percentage` 自动重写；1Gi 卷对本地开发足够，但 `local-path` 的回收策略是 `Delete` 且不支持扩容，容量不足时要另建更大的卷。
- 未设置 `maxmemory`：写入量超过容器 512Mi 上限时 Valkey 会被 OOMKill，随后由 StatefulSet 重新拉起并重放 AOF；需要淘汰语义时应显式加 `--maxmemory` 与 `--maxmemory-policy`。
- 回收边界与 PostgreSQL 相同：从仓库删掉清单后 `apply.sh` 的 prune 只回收 Service/StatefulSet，PVC 保留；若整个目录或 Namespace 被回收，PVC 会随命名空间级联删除，数据丢失。
