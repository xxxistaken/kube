# Agent Note: development Valkey 增加密码校验

Status: implemented

## Problem

[Valkey note](2026-11-19-add-development-valkey.md) 初版让 Valkey 无密码运行，只靠 ClusterIP 和 `development` 命名空间隔离。任何能创建或进入该命名空间 Pod、或能 `kubectl port-forward` 的进程都可以读写全部 key，缓存和会话数据没有认证边界。用户要求给 Valkey 加密码校验，把密码作为 `vkPassword` 键直接写入集群里预先存在的 `development/secrets`，并且不要改动其中既有的 `dbPassword` 键。

## Decision

- 在集群侧 `development/secrets` 上以 `kubectl patch --type merge` 追加 `vkPassword`，保留 `dbPassword`；密码用 `openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-24` 生成 24 位字母数字（对用户建议的 base64 随机数过滤掉需要转义的字符）。密码值只存在于集群 Secret，不写进仓库、清单或本 note。
- `valkey-statefulset.yaml` 增加 `env VALKEY_PASSWORD`（`secretKeyRef` → `secrets/vkPassword`，必需，默认 `optional: false`），并在 `args` 末尾追加 `--requirepass $(VALKEY_PASSWORD)`；kubelet 在启动容器时把 `$(VALKEY_PASSWORD)` 展开成实际密码，仓库里的清单只保留引用。
- 就绪与存活探针改为 `sh -c 'test "$(valkey-cli --no-auth-warning -a "$VALKEY_PASSWORD" ping)" = "PONG"'`。不能只看 `valkey-cli` 的退出码：实测 Valkey 9.1.4 的 `valkey-cli` 在收到 `NOAUTH` 或 `WRONGPASS` 时仍以 0 退出，只看退出码的探针会在密码错误时保持 Ready。
- `apply.sh` 与 `kustomization.yaml` 无需改动；Secret 仍不由本单元创建或回收，Pod 启动依赖它已经存在。

## Verification

2026-11-19 在 orbstack 集群验证：

- `kubectl patch` 后 `secrets` 同时包含 `dbPassword` 与 `vkPassword`；`apply.sh --dry-run` 与 `--yes` 均通过，`valkey-0` 为 `1/1 Running`。
- 无密码 `valkey-cli ping` 返回 `NOAUTH Authentication required.`，错误密码返回 `WRONGPASS`；用 Secret 里的密码经 `valkey` Service 执行 `PING` 返回 `PONG`。
- 探针命令在密码正确时返回 0、密码错误时返回 1，Pod 保持 Ready。
- 带密码写入 `smoke:auth=ok` 后删除 `valkey-0`，重建后仍能读到该 key，AOF 持久化不受影响。
- `kubectl diff -k namespaces/development -n development` 无差异，PostgreSQL 未受影响。

## Alternatives considered

- **保持无密码**——初版方案，少一个 Secret 依赖、客户端无需配置；但用户明确要求认证，且任何能进入命名空间的进程都能读写数据；落选。
- **把密码写进清单或由仓库管理的 Secret 清单**——密码进入 git 历史；落选。
- **复用 `secrets/dbPassword`**——数据库与缓存共用密码，轮换互相牵连，语义也混乱；落选。
- **用 initContainer 生成 `valkey.conf` 或包装 entrypoint**——可以避免密码出现在进程参数里，但要多一个脚本、卷和一次 chown，且容易绕过镜像 entrypoint 的降权逻辑；落选。若要把进程参数里的密码也藏起来，应重新评估这个方向或改用 ACL 文件。
- **探针用 `REDISCLI_AUTH` 环境变量**——依赖 `valkey-cli` 兼容该变量，而且同样要多一个 env；直接用 `-a` 并比较输出更明确；落选。
- **Valkey ACL 多用户**——权限模型更细，但本地开发只需要一个共享密码，ACL 文件还要额外管理；落选。
- **把密码放到 ConfigMap**——ConfigMap 不是秘密存储，任何能读该命名空间 ConfigMap 的对象都能看到明文；落选。

## Consequences

- 连接 Valkey 必须带密码，取值：`kubectl -n development get secret secrets -o jsonpath='{.data.vkPassword}' | base64 -d`。无密码客户端会收到 `NOAUTH`。
- 密码轮换：更新 Secret 后需要 `kubectl -n development rollout restart statefulset/valkey`（或用新的模板重新 apply）；运行中的 Pod 不会自动读取新值。
- 展开后的密码出现在 `valkey-server` 的进程参数里，能 `kubectl exec` 进容器或读取 `/proc/<pid>/cmdline` 的人可以拿到。对本地开发可接受；生产化时应改为限制权限的配置文件或 ACL 文件。
- Secret 仍是外部依赖：集群重建必须先创建 `secrets` 且包含 `vkPassword`，否则 Pod 停在 `CreateContainerConfigError`。README 已记录该前提。
- 该单元仍然只在开发者本地环境使用，不改变“不部署生产”的定位。
