# xxx.kube

微服务的 Kubernetes 配置集中管理仓库。

集群里的所有声明式资源——命名空间、工作负载、Service、Ingress、ConfigMap、RBAC——都以纯 YAML 维护在这里，按目录组织、用 [Kustomize](https://kustomize.io/) 组合渲染。仓库只承载配置，不含应用代码、镜像构建与流水线定义。

## 目录

```
namespaces/<namespace>/    # 一个命名空间及其基础配置，如 Namespace、ResourceQuota、LimitRange
```

每个目录自成一份 Kustomization，可独立渲染、diff 与 apply：

```bash
kubectl diff -k namespaces/xxxistaken
kubectl apply -k namespaces/xxxistaken
```

渲染出的每个资源都带 `managed-by: <ns>` 标签，值等于所在目录的命名空间名，因此可以按标签回收已从仓库删除的资源：

```bash
kubectl apply -k namespaces/xxxistaken --prune -l managed-by=xxxistaken
```

按目录批量同步时，选择器的值就是目录名：

```bash
for d in namespaces/*/; do
  ns=$(basename "$d")
  kubectl apply -k "$d" --prune -l "managed-by=$ns"
done
```

`--prune -l` 只删除**带该标签、由 `apply` 打过 last-applied 注解、且不在本次渲染结果里**的对象：手工 `kubectl create` 的资源、以及标签值不同的其它命名空间的对象都不受影响。

标签值带命名空间名不只是可读性：`Namespace` 这类集群级对象是按选择器**全局**列举的，把值写死成别的命名空间（或所有目录共用一个值），应用 A 目录时可能匹配到 B 命名空间的 Namespace 对象并把它删掉——连同其下全部资源。

`--prune` 仍是 alpha 功能，先用 `kubectl diff -k <dir>` 确认；其默认回收白名单只覆盖常用命名空间级资源与 `Namespace`、`PersistentVolume`，其余类型需显式 `--prune-allowlist=<group>/<version>/<Kind>`。

注意 `Namespace` 对象本身也在白名单里，并且同样带 `managed-by=<ns>`：删掉某个 `namespaces/<ns>/` 目录后再 prune，会连同 Namespace 对象一起删除，并级联清掉其中所有资源。只想回收命名空间内的对象时，用 `--prune-allowlist` 显式列出要回收的类型。

## 约定

- 只用声明式 YAML，`apiVersion` / `kind` 显式书写，缩进 2 空格。
- 目录名与其中对象的 `metadata.name` 一致，统一 kebab-case。
- 一个目录 = 一个可独立 apply 的单元，目录内用 `kustomization.yaml` 的 `resources` 显式列出资源，不依赖隐式加载。
- 命名空间级对象不写 `metadata.namespace`，由应用方（`-n`、overlay 或 CD 控制器）决定。
- 每个 `kustomization.yaml`——当前是 `namespaces/<ns>/`，将来的顶层目录同样——都带 `labels` 转换器注入 `managed-by: <ns>`（`includeSelectors: false`），值等于该目录的命名空间名；目录内**所有**资源，包括日后新增的 YAML，自动带上该标签。这是该标签的唯一来源：不要在单个 YAML 里重复手写，也不要写成别的值。
- 目录名、对象名、`managed-by` 值三者一致。值写错成别的命名空间，`--prune -l managed-by=<ns>` 就匹配不到这些对象，回收静默失效。
- 一个目录里的资源只属于该命名空间，不跨目录放置：标签表达的是“由哪个命名空间单元管理”，放错目录的对象带错标签，`--prune -l` 同样看不见它。
- 非命名空间目录（如将来的 `cluster/`，存放 ClusterRole 等）没有对应的命名空间名可用，取值需届时单独决定并写 note。
- 只依赖 `kubectl` 自带的 Kustomize（v1.27+），不引入额外渲染工具。

## 新增一个命名空间

复制 `namespaces/xxxistaken/`，把目录名、`namespace.yaml` 的 `metadata.name` 与 `app.kubernetes.io/name`、以及 `kustomization.yaml` 里的 `managed-by` 值，全部改成新命名空间名。四处漏改一处，prune 的回收边界就会落错位。

## 变更与决策

结构性决策、被否决的方案记录在 [`.agent/notes/`](.agent/notes/README.md)：实现前写 `proposed/`，落地后转 `implemented/`。改动行为、布局、流程或配置格式时，同一变更内必须附带对应 note。
