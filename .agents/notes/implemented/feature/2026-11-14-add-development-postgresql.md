# Agent Note: development 命名空间加入 PostgreSQL

Status: implemented

## Problem

`development` 单元原本只有命名空间对象，`faary` 应用没有数据库可用。所需数据库版本固定为 `postgres:18.7-trixie`，首次启动就要创建数据库 `faary` 与用户 `faary`，并让该用户对 `faary` 库拥有全部权限；密码已由集群侧准备好：Secret `secrets`（namespace `development`）的 `dbPassword` 键。仓库需要按“一个目录 = 一个可独立 apply 的命名空间单元”的约定声明这个有状态工作负载，同时保持 `apply.sh` 的回收边界正确、不把数据卷纳入 prune。

## Decision

在 `namespaces/development/` 新增三个清单，并在 `kustomization.yaml` 的 `resources` 中显式列出：

- `postgres-statefulset.yaml`：单副本 `StatefulSet postgres`，镜像 `postgres:18.7-trixie`；`POSTGRES_DB=faary`、`POSTGRES_USER=faary`、`POSTGRES_PASSWORD` 通过 `secretKeyRef` 读取 `secrets/dbPassword`。数据卷由 `volumeClaimTemplates` 声明（10Gi、`ReadWriteOnce`、默认 StorageClass），挂载到 `/var/lib/postgresql`。
- `postgres-headless-service.yaml`：`clusterIP: None` 的 `postgres-headless`，作为 StatefulSet 的 governing Service，给 `postgres-0` 稳定网络标识。
- `postgres-service.yaml`：`ClusterIP` 的 `postgres:5432`，供应用按服务名连接。

`apply.sh` 的 `prune_allowlist` 追加 `core/v1/Service` 与 `apps/v1/StatefulSet`（只增不减）；不加入 `core/v1/PersistentVolumeClaim`。

关键取舍：

- **挂载点**：PostgreSQL 18 起官方镜像把 `PGDATA` 改为版本化路径 `/var/lib/postgresql/18/docker`，并把 `VOLUME` 改为 `/var/lib/postgresql`；PVC 必须挂到后者，挂 `/var/lib/postgresql/data` 会让数据落在容器可写层、随 Pod 重建丢失（[18+ 镜像文档](https://github.com/docker-library/docs/blob/master/postgres/README.md)）。
- **“所有权限”**：官方镜像用 `POSTGRES_USER` 创建 superuser，并用 `POSTGRES_DB` 创建同名库、归该用户所有。`faary` 因此天然拥有 `faary` 库的全部权限（连接、建表、建 schema 等），不需要额外的 `GRANT` 或 init SQL；当前也只有一个密码键，没有第二个 superuser 密码可用。
- **Secret 不在本单元**：`secrets` 由集群侧预先创建，`kustomization.yaml` 不声明它、`apply.sh` 不管理它，prune 不会删除它。
- **PVC 不进 allowlist**：PVC 由 StatefulSet 控制器创建，不带 `managed-by` 标签，也不由 `kubectl apply` 管理；把它列入回收类型只会带来误删数据卷的风险。

验证：先在 orbstack 集群执行 `./namespaces/development/apply.sh --dry-run`，server dry-run 结果为 `namespace/development unchanged`、`service/postgres created`、`service/postgres-headless created`、`statefulset.apps/postgres created`，无报错；随后 `apply.sh --yes` 实际应用，`postgres-0` 变为 `1/1 Running`，PVC `data-postgres-0` 绑定 10Gi。进入 Pod 确认 `current_user=faary`、`role.faary.rolsuper=true`、`faary` 库的 owner 为 `faary`，`CONNECT`/`CREATE`/`TEMP` 权限均为 true；再用容器里的 `POSTGRES_PASSWORD` 从 `postgres:5432` 走 TCP 登录，返回 `faary|faary`。

## Alternatives considered

- **Deployment + 手写 PVC**——没有稳定 Pod 身份与 `volumeClaimTemplates`，重建时 PVC 与 Pod 的绑定需要自己维护；落选。
- **在 init ConfigMap 里执行 `GRANT ALL PRIVILEGES ON DATABASE faary TO faary`**——`faary` 已是 superuser 且为库 owner，授予自己权限是冗余；再加一个一次性脚本和 ConfigMap 只会增加失败面；落选。
- **用 `dbPassword` 同时充当 `postgres` 超级用户与 `faary` 应用用户的密码**——需要把 `POSTGRES_USER` 设成 `postgres` 再在 init 里建 `faary`，但只有一个密码键：两者要么共用密码（职责不分离），要么无法设置；落选。
- **PVC 挂 `/var/lib/postgresql/data`**——17 及以前的惯例路径，在 18 镜像里不是 `PGDATA`，会静默失去持久化；落选。
- **只建 headless Service**——少一个对象，但应用要连 `postgres-0.postgres-headless` 这类 Pod DNS，重启后解析目标变化；落选。
- **把 Secret 复制进仓库或用 kustomize 生成**——密码入库；用户已声明 Secret 存在，仓库只应引用；落选。

## Consequences

- `development` 单元从纯命名空间变成含 StatefulSet、两个 Service 的单元；`apply.sh` 的回收类型相应扩展，`kubectl apply -k namespaces/development -n development` 可独立部署。
- 部署前必须存在 `development/secrets` 且含 `dbPassword`，否则 Pod 无法启动；该 Secret 不随本单元创建或删除。
- `POSTGRES_DB` / `POSTGRES_USER` / `POSTGRES_PASSWORD` 只在首次初始化时生效；之后改 Secret 不会修改已有数据库的密码，需在库内执行 `ALTER USER faary WITH PASSWORD ...`。
- 默认 StorageClass `local-path` 的回收策略是 `Delete`、不支持扩容，10Gi 数据卷绑定节点；迁移节点或扩容要另作处理。
- 删除三个清单后 prune 只回收 Service/StatefulSet，PVC 保留；但若把整个目录删掉再 prune，Namespace 也在 allowlist 里，会连 Namespace 一起删除并级联删掉 PVC，local-path 的 PV 随之回收，数据仍会丢失——与 README 记录的 Namespace 级联风险一致。
