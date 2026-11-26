# Agent Note: development 命名空间加入 Temporal

Status: implemented

## Problem

`development` 单元是开发者本地环境的共享依赖单元，已经有 [PostgreSQL](2026-11-14-add-development-postgresql.md) 与 [Valkey](2026-11-19-add-development-valkey.md)。本地跑业务应用还缺一个工作流引擎：应用要连接 Temporal 启动、查询工作流，而让每个开发者自己在宿主机安装、管理版本与端口既不可复现，也容易和应用配置脱节。用户参照 [temporalio/helm-charts 的 README](https://github.com/temporalio/helm-charts/blob/main/README.md) 要求在该命名空间启动一个 Temporal service，并为此在宿主机安装了 Helm。

期望与 PostgreSQL、Valkey 同构：服务在 `development` 内按稳定服务名可访问，数据在 Pod 重建后仍然保留，不进入生产发布，并且不影响 `apply.sh` 既有的 `managed-by=development` 回收边界。

## Decision

用 Helm 在 `development` 安装 release `temporal`（chart `temporal` 1.8.0，appVersion 1.32.2，来自 `https://go.temporal.io/helm-charts`），持久化复用同命名空间的 PostgreSQL。配置只固化在一份新文件 `namespaces/development/temporal-values.yaml`，**不新增 kustomize 清单，也不改 `kustomization.yaml` 与 `apply.sh`**：

- **持久化**：default 与 visibility 两个 datastore 都走 `sql` + `pluginName: postgres12`，`connectAddr` 为 `postgres.development.svc.cluster.local:5432`，用户 `faary`，库名 `temporal` / `temporal_visibility`。`createDatabase: true` 与 `manageSchema: true` 让 chart 的 `pre-install` schema Job 创建两个库并建表。
- **密码**：`existingSecret: secrets` + `secretKey: dbPassword`，复用集群侧已存在的同命名空间 Secret（与 PostgreSQL 用的是同一份密码，见 [PostgreSQL note](2026-11-14-add-development-postgresql.md)）。chart 只把 `secretKeyRef` 写进 Pod env（`TEMPORAL_DEFAULT_STORE_PASSWORD` / `TEMPORAL_VISIBILITY_STORE_PASSWORD`），ConfigMap 里的 `password` 是 `{{ env ... }}` 占位，明文不进 ConfigMap。
- **命名空间**：`server.config.namespaces.create: true`，post-install hook 注册名为 `default` 的 Temporal namespace（保留期 72h）；Temporal 内置的 `temporal-system` 由 server 自己创建。
- **组件**：`web` 与 `admintools` 保持开启。UI 由 `temporal-web:8080` 提供；`temporal` CLI 通过 `kubectl -n development exec deploy/temporal-admintools -- temporal ...` 使用，前端地址为 `temporal-frontend:7233`。
- **UI 镜像**：`web.image.tag: "2.58.1"`，覆盖 chart 1.8.0 默认的 `2.56.1`。2.56.1 返回的页面带 `script-src 'strict-dynamic' 'sha256-…'` 的 CSP meta，在 Chrome 158+ 会整页白屏；2.58.1 改为 `script-src 'self' 'sha256-…'`（[release note](https://github.com/temporalio/ui/releases/tag/v2.58.1)）。chart 升级后要确认新的默认 UI 已包含该修复，再删掉这个 pin。
- **CSRF Cookie**：`web.additionalEnv` 设置 `TEMPORAL_CSRF_COOKIE_INSECURE=true`（配置键 `cors.cookieInsecure`）。UI 通过明文 `http://` 访问，不加这个变量时服务端下发的 `_csrf` 带 `Secure`，浏览器会丢弃它，POST 报 `missing csrf token in request header`。该变量只让 `_csrf` 不再带 `Secure`，是本地开发的降级；前面接上 TLS 后必须删掉。
- **规模**：`server.replicaCount: 1`（frontend / history / matching / worker 各一个副本），server 容器 requests 100m/256Mi、内存上限 1Gi。Temporal 自身不建 PVC：状态全部落在 PostgreSQL。

这是本仓库“只用声明式 YAML、只用 kubectl 自带 Kustomize”约定的**有意例外**，README 与 PROJECT_STRUCTURE 已同步声明：Temporal 的对象不带 `managed-by` 标签，`apply.sh --prune -l managed-by=development` 列举不到它们（不会误删），`helm uninstall` 也不会碰 kustomize 管理的对象。选择 Helm 而不是入库的渲染清单，核心原因是 chart 用 Helm hook 保证建表先于 server 启动，见 [Alternatives considered](#alternatives-considered)。

`secrets` 仍是外部依赖：它不由本单元创建或回收，缺失时 schema Job 与 server Pod 都起不来。

## Verification

2026-11-24 在 orbstack 集群（kubectl v1.32.3，server v1.36.5，helm v4.3.0）验证：

- `helm -n development list` 显示 release `temporal` 为 `deployed`（REVISION 2），chart `temporal-1.8.0` / appVersion `1.32.2`；最终 release 由公开仓库 `https://go.temporal.io/helm-charts` 的 chart 1.8.0 安装。
- 用仓库里的 `temporal-values.yaml` 与公开仓库 chart 1.8.0 渲染（`helm template`），14 个非 hook 资源与 `helm get manifest` 逐字节一致——入库的配置就是线上 release 的配置。需注意 GitHub `main` 上同样自称 1.8.0 的 chart 会把 UI 镜像渲染成 `temporalio/ui:2.56.4`（发布版是 `2.56.1`）：本次先以 clone 的 chart 安装、发现差异后用发布版 upgrade 对齐，以公开仓库版本为准。
- `kubectl -n development get pods -l app.kubernetes.io/instance=temporal`：`temporal-admintools`、`temporal-frontend`、`temporal-history`、`temporal-matching`、`temporal-web`、`temporal-worker` 六个 Pod 全部 `1/1 Running`。
- `kubectl -n development exec deploy/temporal-admintools -- temporal operator cluster health` 返回 `SERVING`；`temporal operator namespace list` 显示内置 `temporal-system` 与新建的 `default`（`72h0m0s`）。
- `kubectl -n development exec postgres-0 -- psql -U faary -d postgres -tAc "select datname from pg_database"` 中出现 `temporal` 与 `temporal_visibility`，由 superuser `faary` 创建。
- 直接访问 `http://temporal-web.development.svc.cluster.local:8080`（本机可解析 `*.svc.cluster.local`，无需 port-forward）返回 200，`/api/v1/system-info` 的 `serverVersion` 为 `1.32.2`。
- 升级 UI 到 2.58.1 后，返回的 HTML 中 CSP meta 从 `script-src 'strict-dynamic' 'sha256-In64…'` 变成 `script-src 'self' 'sha256-vcq…'`；headless Chrome 156 下页面正常渲染出 Namespace/Workflow 列表，控制台没有 CSP 报错。Chrome 158+ 的白屏问题以官方 2.58.1 的修复说明为准（本机 headless Chrome 版本低于 158，无法在本机复现原故障）。
- 加 `TEMPORAL_CSRF_COOKIE_INSECURE=true` 前：`Set-Cookie: _csrf=…; …; Secure; SameSite=Strict`，curl 在 http 下拒绝保存该 Cookie，带 `X-CSRF-Token` 的 POST 返回 `400 {"message":"missing csrf token in request header"}`，与浏览器报错一致。加之后：Set-Cookie 不再带 `Secure`，Cookie 能保存与回传，POST 通过 CSRF 中间件（落到路由返回 405）；headless Chrome 里 `document.cookie` 含 `_csrf`，页面内 fetch 带 header 返回 405，控制台无错误。
- `kubectl diff -k namespaces/development -n development` 无输出：PostgreSQL 与 Valkey 的既有对象未被改动。
- `temporal-matching` 首次启动重启 1 次（就绪探针在 gRPC 端口开始监听前失败），随后稳定；属于启动期噪声，与配置无关。

## Alternatives considered

- **`helm template` 渲染成 YAML 提交进仓库，由 kustomize / `apply.sh` 应用**——最贴合仓库现有模型，但 chart 的 schema Job 是 `pre-install` hook、namespace Job 是 `post-install` hook。`kubectl apply` 不认 hook，多资源 apply 又按 Kind 排序（Deployment 先于 Job），server Pod 会在建表前启动并以 CrashLoopBackOff 反复重试，直到 schema Job 完成。要消除这个顺序问题，就得让脚本先单独 apply schema Job、再 apply 其余对象——等于自己实现一遍 hook 编排，`apply.sh` 从“一次 apply + prune”变成多阶段流程；落选。
- **手写精简清单（`temporalio/auto-setup` 单进程 + `temporalio/ui`）**——最贴近仓库风格，一个 Deployment 就能跑，schema 由 auto-setup 镜像在启动时自行处理，没有顺序问题；但拓扑与 chart（以及生产里的 Temporal 部署）不一致：所有 server 角色挤在一个进程里，也没有 admintools、按角色拆分的 Deployment、schema/namespace Job，后续想用 chart 的能力要整体重做；落选。若日后决定彻底不引入 Helm，这是首选替代。
- **`temporal server start-dev` 单容器**——用 SQLite、数据在容器内、与已有 PostgreSQL 无关，重建即丢，和“共享开发依赖 + 数据可保留”的目标冲突；落选。
- **values 只在命令行 `--set` 传，不入库**——下次升级没人知道当时怎么配的，与仓库“声明式、可复现”的定位冲突；落选。
- **装进 `faary`**——Temporal 只服务本地开发，混进业务命名空间会共享 `managed-by=faary` 的回收边界和生产发布范围；落选。
- **MySQL / Cassandra / Elasticsearch 做持久化**——本单元已有 PostgreSQL，再引入一套数据库会放大本地依赖；chart 也不带数据库 subchart；Cassandra 还不能做 visibility；落选。
- **给 Temporal 单独建命名空间**——多一个命名空间单元和一套 `apply.sh`/prune 边界，而它同样只是本地开发依赖，与 PostgreSQL、Valkey 的归属一致更简单；落选。

## Consequences

- `development` 单元从“纯 kustomize 清单”变成“kustomize 清单 + 一个 Helm release”的混合体：`apply.sh` 创建/回收 Namespace、PostgreSQL、Valkey；Temporal 的生命周期由 `helm upgrade` / `helm uninstall` 管理。集群重建后必须先 `apply.sh`（让 `secrets` 与 postgres 就绪）再 `helm install`，否则 schema Job 连不上数据库。
- Helm 创建的对象不在 `managed-by=development` 的回收边界内：删掉 `temporal-values.yaml` 不会让集群里的 Temporal 消失，必须 `helm uninstall temporal -n development`；反过来 `--prune` 也不会因为渲染结果里没有它们而误删。
- 升级用 `helm upgrade --install temporal temporal --repo https://go.temporal.io/helm-charts --version <新版本> -n development -f namespaces/development/temporal-values.yaml`；`numHistoryShards` 首装后不可修改。升级会滚动重启所有 server Pod。若数据库被删除，依赖 `pre-install`/`pre-upgrade` 的 schema Job，需要触发一次升级或手动重跑。
- 本地资源占用：6 个 Deployment（其中 web、admintools 各 1 副本）+ 6 个 Service，实测多占约 1~2Gi 内存；数据不占 PVC，落在已有 PostgreSQL 的 `temporal` / `temporal_visibility` 库里。
- `TEMPORAL_CSRF_COOKIE_INSECURE=true` 让 `_csrf` 在明文 HTTP 下可被同站脚本读取并发送，只适合本机开发；给 UI 接上 TLS/Ingress 后应删除这个 env，否则是无谓的降级。
- UI 被钉在 `temporalio/ui:2.58.1`：升级 chart 不会自动换成 chart 的新默认版本，每次 chart 升级都要复核这个 pin 能否删掉（见 Decision）。
- `secrets/dbPassword` 仍是外部依赖：Secret 缺失时 schema Job 与 server Pod 都起不来。轮换 Secret 不会改数据库里既有的密码；要真正轮换，需要同时改 PostgreSQL 里的密码并重启 Temporal Pod。
- 访问方式：`temporal-frontend:7233`（gRPC）、`temporal-web:8080`（UI）。本机（OrbStack）直接解析 `*.svc.cluster.local`，用 `http://temporal-web.development.svc.cluster.local:8080` 即可；不在集群网络内的机器用 `kubectl -n development port-forward svc/temporal-web 8080:8080`（或 frontend 7233）兜底。该单元仍只用于本地开发，任何自动化流程都不应把它纳入生产发布。
- `go.temporal.io` 的 chart 仓库在本机曾间歇连不上（curl TLS 报错，稍后恢复）；遇到时可以用 `git clone https://github.com/temporalio/helm-charts` 后以 `charts/temporal` 作为 chart 路径安装，但 clone 的 `main` 可能与已发布 chart 内容不同（UI 镜像 tag 就曾不一致），只能作兜底，并先 `helm template` 对比差异。
