# xxx.kube

微服务的 Kubernetes 配置集中管理仓库。

集群里的所有声明式资源——命名空间、工作负载、Service、Ingress、ConfigMap、RBAC——都以纯 YAML 维护在这里，按目录组织、用 [Kustomize](https://kustomize.io/) 组合渲染。仓库只承载配置，不含应用代码、镜像构建与流水线定义。

## 目录

```
namespaces/<namespace>/    # 一个命名空间及其基础配置，如 Namespace、ResourceQuota、LimitRange
```

每个目录自成一份 Kustomization，可独立渲染、diff 与 apply：

```bash
kubectl apply -k namespaces/xxxistaken
```

## 约定

- 只用声明式 YAML，`apiVersion` / `kind` 显式书写，缩进 2 空格。
- 目录名与其中对象的 `metadata.name` 一致，统一 kebab-case。
- 一个目录 = 一个可独立 apply 的单元，目录内用 `kustomization.yaml` 的 `resources` 显式列出资源，不依赖隐式加载。
- 命名空间级对象不写 `metadata.namespace`，由应用方（`-n`、overlay 或 CD 控制器）决定。
- 只依赖 `kubectl` 自带的 Kustomize（v1.27+），不引入额外渲染工具。

## 新增一个命名空间

复制 `namespaces/xxxistaken/`，改写 `namespace.yaml` 的 `metadata.name` 与标签，保持目录名同名即可。

## 变更与决策

结构性决策、被否决的方案记录在 [`.agent/notes/`](.agent/notes/README.md)：实现前写 `proposed/`，落地后转 `implemented/`。改动行为、布局、流程或配置格式时，同一变更内必须附带对应 note。
