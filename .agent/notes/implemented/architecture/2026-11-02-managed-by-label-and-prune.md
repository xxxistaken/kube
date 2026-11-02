# Agent Note: 用 managed-by 标签划定 kubectl apply --prune 的回收范围

Status: implemented

## Problem

仓库会持续新增、重命名、删除资源。`kubectl apply -k namespaces/<ns>` 只创建与更新，不会删除已经从仓库移除的对象，于是集群里留下“仓库里已经没有、但仍在运行”的孤儿资源（旧 ConfigMap、改名前的 Deployment、被替换的 Service）。手工清理依赖人的记忆，且无法判断某个对象是不是由本仓库管理——集群里还跑着别人创建的、或 `kubectl run` 之类命令临时创建的对象，误删代价远高于漏删。

`kubectl apply --prune` 提供了按标签回收的机制：删除打了 last-applied 注解、匹配标签选择器、且不在本次渲染结果里的对象。要让它安全可用，前提是**本仓库管理的对象都带一个可预测的归属标签，而其它来源的对象不带**。这个前提必须在第一个资源落地的同时建立：等到资源多了再补，就是一次全量重新 apply，且补标签之前 prune 会漏掉它们。

仓库按命名空间分目录管理（见 [Kubernetes 配置仓库的布局与命名空间单元](2026-11-02-k8s-config-repo-layout.md)），所以“归属”天然按命名空间划分：一个 `namespaces/<ns>/` 目录对应一个命名空间，回收的边界也应当落在命名空间上。

## Decision

每个 `namespaces/<ns>/` 目录的 `kustomization.yaml` 注入标签 `managed-by: <ns>`，值就是该目录的命名空间名；prune 以它为回收边界：

```bash
kubectl apply -k namespaces/xxxistaken --prune -l managed-by=xxxistaken
```

多个目录各自应用，选择器的值取各自的目录名（README 给出按目录遍历的循环）。

### 值等于命名空间名

`namespaces/xxxistaken/` → `managed-by: xxxistaken`；将来新增 `namespaces/payments/` → `managed-by: payments`。理由有三条，其中第一条是决定性的：

- **命名空间对象本身是集群级的，选择器对它全局生效。** prune 对命名空间级资源只在本次 apply 涉及的命名空间里按选择器列举，但对 `Namespace`、`PersistentVolume` 这类非命名空间级资源是**全局**列举的：凡是匹配选择器、带 last-applied 注解、又不在本次渲染结果里的对象都会被删。若所有目录共用一个值，应用 `namespaces/payments/` 时选择器同样匹配 `Namespace/xxxistaken`——它不在本次结果里，于是被 prune 掉并级联清空整个命名空间。值带命名空间名后，`-l managed-by=payments` 只会命中 `Namespace/payments`。
- **边界与 apply 边界对齐。** 一次 `apply -k` 只作用于一个目录，`-l managed-by=<ns>` 也就只圈住这一个命名空间对应的对象，命令里的目录和选择器一一对应，没有跨目录的隐式耦合。
- **可读、可核对。** `kubectl get all -n payments -l managed-by=payments` 直接回答“payments 里哪些对象由本仓库管理”。共用一个值时，`-l` 只能回答“由本仓库管理”，无法回答“属于哪个单元”。

### 标签由 Kustomization 统一注入，不在单个 YAML 里手写

每个可独立 apply 的目录（当前是 `namespaces/<ns>/`，将来的顶层目录同样）的 `kustomization.yaml` 都带一个 `labels` 转换器：

```yaml
labels:
  - pairs:
      managed-by: xxxistaken   # 必须等于本目录的命名空间名
    includeSelectors: false
```

理由是可穷尽性。手工在每份 YAML 的 `metadata.labels` 里写标签，新增资源时漏写不会被任何检查拦住——而漏写的对象恰恰是 prune 看不见的对象，缺一个，就有一个孤儿不在 prune 的视野里。放在 Kustomization 层，转换器作用于该目录渲染出的**每一个**资源，包括以后新增的 YAML，无需任何提醒机制；`kubectl kustomize` 的输出即证明。

`includeSelectors: false` 是刻意的：这个标签表达的是“由哪个命名空间单元管理”，不是“选哪些 Pod”。注入到工作负载的 `spec.selector` 会改变不可变字段、并与 Pod 模板标签产生联动，而 prune 只读对象的 `metadata.labels`，用不上选择器。

### 值靠目录约定同步，不自动推导

kustomize 没有把目录名算进 label 值的机制，也不值得为此引入模板工具。实际做法是复制目录时改一行：目录名、`metadata.name`、`app.kubernetes.io/name`、`managed-by` 四处一起改，写进 README 的新增命名空间步骤。核对成本很低——`kubectl kustomize namespaces/<ns>` 的输出里标签值一眼可见。

### 单一来源，禁止覆盖

标签只在 `kustomization.yaml` 声明一次。单个 YAML 中不手写该标签，也不许写成别的值；需要额外标签时往 `labels` 转换器的 `pairs` 里加。当前只作用于 `metadata.labels`，不进入选择器与 Pod 模板（`includeTemplates` 保持默认 `false`）。

## Alternatives considered

**在每份 YAML 的 `metadata.labels` 里手写 `managed-by`。** 最直观，也最容易漏：新增资源、从别处拷来的清单都可能漏写，而漏写的对象对 prune 不可见，且没有机器检查发现它。同时它把同一个事实复制到 N 个文件，改命名空间时逐文件改。否决。

**所有目录共用一个仓库级的值（例如全填 `xxxistaken`）。** 这是最初设想的形态，好处是任何目录都能用同一条 `-l`。但它把 `Namespace` 对象暴露给了跨目录 prune：非命名空间级资源按选择器全局列举，应用 `namespaces/payments/` 时 `Namespace/xxxistaken` 同样匹配、同样带 last-applied、又不在本次结果里，于是被删除并级联清空——一次日常 apply 就能毁掉另一个命名空间。即使不涉及 Namespace，共用一个值也让“标签 = 管理者标识”和“标签 = 回收范围”两件事挤在同一个键上，范围只能靠操作者记得“只 apply 一个目录”来保证。否决。

**用 `commonLabels`。** Kustomize 的旧字段，语义是“标签 + 选择器”一起注入，会改写工作负载的 `spec.selector`（不可变字段）；它在 Kustomize v5 中已标记废弃，渲染时会往 stderr 打废弃告警。否决。

**用 `app.kubernetes.io/managed-by` 这个 Kubernetes 推荐标签。** 语义上更标准，但它约定存放的是**工具名**（`helm`、`kustomize`、`argocd`），而这里要表达的是命名空间归属；同一集群若以后由 Argo CD 同步，该键会被工具自己占用。需求方明确指定了 `managed-by` 这个键，且它是自有的、不与工具约定冲突的键。记录于此以便日后复核。

**改用 `--prune --all`，或迁到 ApplySet。** `--all` 不按标签筛选，会把该命名空间里所有带 last-applied 注解、又不在本次清单中的对象一并删除——包括其它来源 apply 出来的对象，风险不可接受。ApplySet 用一组隐藏标签加一个父对象精确记录归属，边界比裸标签更细；但它目前由 cli-utils/declarative 等库提供，`kubectl apply` 并没有 `--applyset` 开关（v1.32 的 `--help` 里没有），引入它意味着更换同步工具与额外的父对象、标签，运维和排查成本都高于一个可读的 `-l`。当前仓库目录与命名空间一一对应，标签方案已足够；若将来出现集群级目录或需要跨目录统一回收，再评估。推迟。

**不引入标签，靠 `kubectl diff` + 人工清理。** `kubectl diff` 只能显示清单与集群的差异，无法告知“集群里有、但清单里已经没有”的对象；这正是孤儿资源的形态。否决。

## Consequences

- 日常应用入口是每个单元目录自带的 `namespaces/<ns>/apply.sh`：预检、server dry-run 预演、确认后再 apply，见 [每个命名空间单元自带的应用脚本](../process/2026-11-02-apply-namespace-script.md)。
- 新增资源零成本：在 `namespaces/<ns>/` 放 YAML、加进 `resources` 即可，标签自动到位，无需提醒。
- 删除资源成了一条命令：从 `resources` 移除并 `kubectl apply -k namespaces/<ns> --prune -l managed-by=<ns>`，回收范围停在该命名空间单元。
- 边界可核对：`kubectl get deploy,sts,ds,job,cronjob,svc,ing,cm,secret -n <ns> -l managed-by=<ns>` 列出的就是该单元管理的对象。
- 代价：标签值与目录名手工保持一致。漏改的后果是选择器匹配不到（漏回收），不会跨命名空间误删；但“值写成了别的命名空间名”会让那一刻的 prune 指向错误的目标，仍然需要 review 把关。
- 代价与安全边界：`Namespace` 落在默认回收白名单内，且 `managed-by=<ns>` 正好命中该命名空间的 Namespace 对象，因此删除整个 `namespaces/<ns>/` 目录后 prune 会删除 Namespace 并级联清空其中的资源。这在“下线一个命名空间”时正是想要的行为，但它意味着该目录的 prune 破坏半径覆盖整个命名空间；需要只回收命名空间内对象时，显式用 `--prune-allowlist` 列出类型。
- 代价：`--prune` 在 kubectl 中仍是 alpha，且标签选择器回收只覆盖默认白名单里的类型（常用命名空间级资源以及 `Namespace`、`PersistentVolume`），其他类型需要显式 `--prune-allowlist`。使用前应先 `kubectl diff -k <dir>`。
- 代价：prune 依据 last-applied 注解识别“由 apply 创建”，因此从未被 `apply` 过、仅被 `create` 的带标签对象不会被回收；反之，任何**手工**给对象打上该标签的人都在主动把它纳入回收范围。
- 代价：标签注入依赖 `kubectl` 内置 Kustomize 的 `labels` 字段。`labels` 与 `includeSelectors` 自 Kustomize v4.3 起可用，远早于仓库约定的 kubectl v1.27+（内置 v5），因此不构成实际的版本约束；不支持该字段的旧版本会渲染失败而不是静默漏标签——这是可接受的失败方式。
- 约定靠文档与 review 落地，仓库没有 CI 校验“每个目录的标签值等于目录名”；若以后加了渲染测试，应把“渲染结果中每个对象都带 `managed-by=<目录名>`”作为断言之一。
