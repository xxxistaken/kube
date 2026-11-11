# 项目结构

xxx.kube 是微服务的 Kubernetes 配置集中管理仓库：全部资源以声明式 YAML 维护，用 Kustomize 组合，不含应用代码。

| 路径 | 说明 |
| --- | --- |
| `namespaces/xxxistaken/` | 命名空间 `xxxistaken` 的基础配置：`namespace.yaml`（Namespace 对象）与 `kustomization.yaml`（显式列出 resources） |
| `namespaces/<ns>/apply.sh` | 应用该命名空间单元：预检 + server dry-run 预演 + `kubectl apply -k namespaces/<ns> -n <ns> --prune -l managed-by=<ns> --prune-allowlist=...`，回收类型清单 (`prune_allowlist`，当前仅 `core/v1/Namespace`) 随单元维护且只增不减；见 [note](.agents/notes/implemented/process/2026-11-02-apply-namespace-script.md) |
| `.agents/notes/` | Agent Notes，记录布局与流程决策；规则见 [`.agents/notes/README.md`](.agents/notes/README.md) |
| `AGENTS.md` | 面向 agent 的工作区说明入口 |
| `README.md` | 面向人的仓库用途与使用约定 |

每个 `namespaces/<ns>/kustomization.yaml` 都带 `labels` 转换器注入 `managed-by: <ns>`（值等于该目录的命名空间名），目录内所有资源自动获得该标签，供 `kubectl apply -k namespaces/<ns> -n <ns> --prune -l managed-by=<ns>`（即 `namespaces/<ns>/apply.sh`）回收。标签只在 Kustomization 中声明一次，不写进单个 YAML。

新增命名空间：复制 `namespaces/xxxistaken/` 目录，把目录名、对象名与 `kustomization.yaml` 的 `managed-by` 值一并改成新命名空间名。跨命名空间共享的对象（如 ClusterRole）尚无归属目录，需要时新增顶层目录并在 `.agents/notes/` 记录。
