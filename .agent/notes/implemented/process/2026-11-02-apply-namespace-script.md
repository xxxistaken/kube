# Agent Note: 每个命名空间单元自带的应用脚本

Status: implemented

## Problem

仓库的约定落成一条命令并不短：`kubectl apply -k namespaces/<ns> -n <ns> --prune -l managed-by=<ns> --prune-allowlist=...`（标签与回收边界见 [用 managed-by 标签划定 kubectl apply --prune 的回收范围](../architecture/2026-11-02-managed-by-label-and-prune.md)）。手工输入时每一处都可能出错，而且大多不会报错：

- 路径 `namespaces/<ns>` 由命名空间名推出，多一层或少一层目录都指向不存在的 Kustomization；
- `--prune` 必须与 `-l` 成对出现：单独给 `--prune` 会被 kubectl 拒绝，漏掉 `--prune` 则完全不回收；
- `-l` 的值必须是该目录的标签值。写错时 apply 照常成功，prune 却一个对象也匹配不到——静默空转让人以为清理已经做了；
- `-n` 决定单元里的工作负载落到哪个命名空间。漏掉时对象会落进 kubectl 的默认命名空间，标签与实际归属就此错位；
- `--prune-allowlist` 决定哪些类型会被回收。不传时 kubectl 会打废弃告警，并且按它自己的默认白名单走。

最后一条把问题从“怎么拼命令”变成“谁来决定回收范围”。这个范围是命名空间单元的属性：不同单元创建的资源类型不同，同一个单元的集合还会随清单演化。把它放在全仓库级别，等于让一个命名空间的需求去改动所有命名空间共用的文件。

## Decision

每个 `namespaces/<ns>/` 目录自带一份 `apply.sh`，它就是“应用本单元”的入口：

```bash
./namespaces/xxxistaken/apply.sh            # server dry-run 预演 → 确认 → apply --prune
./namespaces/xxxistaken/apply.sh --dry-run  # 只预演
./namespaces/xxxistaken/apply.sh --yes      # 跳过确认（脚本 / CI 用）
```

展开后执行的是：

```bash
kubectl apply -k namespaces/xxxistaken -n xxxistaken --prune -l managed-by=xxxistaken \
  --prune-allowlist=core/v1/Namespace   # 当前只有这一种，随清单增加
```

### 命名空间名来自脚本所在目录

`ns` 取脚本所在目录的 basename，路径、`-n`、选择器三处都由这一个事实推出，不存在“参数与目录不一致”的可能；脚本也不接受位置参数或 `-n` 覆盖。副作用是复制目录新增命名空间时脚本不需要任何改写——只有对象名与 `kustomization.yaml` 的 `managed-by` 值要改。

### allowlist 属于单元，且只增不减

`prune_allowlist` 数组写在每个单元自己的脚本里，声明“本单元会创建哪些类型”，并且只列**已经声明**的类型——本单元目前只有 `Namespace` 对象，所以列表只有 `core/v1/Namespace`。新增资源类型时补上对应的一行，只改对应的那个单元。

**列表只增不减。** 原因是发布与部署不同步：开发者 pull 到某个版本的脚本时，他本地（或其他人的）集群里可能还留着由更早清单创建的对象。如果某个版本顺手把“最近没用到的类型”从列表里删掉，这些旧对象就再也进不了 prune 的视野——它们带着 `managed-by` 标签留在集群里，而脚本的一切看起来都正常。因此删除某一行只有在“该类型在本单元里不会再出现，且所有人都已应用过最后一版包含它的清单”时才安全；默认做法是保留。

同样的道理适用于透传：`--` 之后额外给的 `--prune-allowlist` 是追加语义，只能临时扩大范围，不会替换脚本里的基线。

列表由清单驱动，因此漏加一项是安全方向的失败：该类型的对象不会被回收（残留在集群里），但不会因为多列了一个类型而误删任何东西。这允许脚本从最小集起步，而不是预先列出一堆本单元还没有的类型。

### 预检、两段式预演与 `-n`

执行前校验本目录有 `kustomization.yaml`、其中的 `managed-by` 值等于目录名；不满足就退出，避免“标签值写错 → prune 静默空转”。随后先跑 `--dry-run=server`（apiserver 校验，并列出将被 prune 的对象），询问确认后才真正 apply；stdin 关闭（非交互）视为取消。apply 时显式带 `-n <ns>`，因为资源清单不写 `metadata.namespace`，归属由应用方决定。

## Alternatives considered

**根目录一个 `apply.sh <ns>`。** 这是最初的实现。两个问题：allowlist 只能有一份，要么取所有单元的并集（任何单元新增类型都要改共享文件，且改错会影响别的命名空间），要么漏掉某些单元的类型；位置参数又引入一处“参数与目录错配”的失败面。否决。

**根脚本 + 每单元一份 allowlist 数据文件（如 `namespaces/<ns>/prune-allowlist.txt`）。** 声明与执行分离，多一种文件格式、多一次解析，还要保证文件与脚本位置一致；单元内一个脚本已经能完整表达。否决。

**每个单元的脚本 `source` 一份共享库。** 会破坏“复制目录即新增命名空间”的自包含性：新目录要么跟着复制库、要么依赖相对路径。脚本约 90 行的重复是这一设计可接受的代价。否决。

**由清单自动推导 allowlist（渲染结果里的类型 + 集群现有类型）。** 两头都不对：渲染结果里没有的类型（历史上创建过、现在已从清单删除的对象）恰恰最需要 prune，自动推导会把它们排除；而推导结果在开发者本地与 CI 之间并不一致。否决。

**列表随清单收缩，删掉不再使用的类型。** 见 Decision 的 pull 场景：会让旧对象永久残留，而且失败是静默的。否决。

**去掉 `-n`，改由 `kustomization.yaml` 的 `namespace` 字段下发归属。** 实测绕不开那条废弃告警（kubectl 未显式给 `--namespace` 时把命名空间视作 `default`），同时把“归属由应用方决定”的约定从脚本挪进清单。否决。

**照抄 kubectl 的默认白名单（含 `core/v1 Endpoints`、`PersistentVolume`）。** `Endpoints` 在 1.33+ 已废弃、解析时还会再打一条告警，且由 Service 隐式维护；`PersistentVolume` 是集群级资源，本仓库不声明。列表按“本单元实际声明了什么”取。否决。

**一开始就把常见类型（工作负载、Service、Ingress、RBAC 等）全列上。** 这是最初的写法，被精简掉了：单元里还没有这些对象，多列的每一项只让每次 prune 多做一次列举；而列表本就随清单增长，真正要防的是“新增资源时忘了补类型”，这跟初始列多少无关。从最小集起步、由清单驱动，规则更少也好核对。否决。

## Consequences

- “本单元回收什么”写在单元自己的脚本里；改一个命名空间不会影响另一个。
- 复制目录新增命名空间时脚本零改动；只需改对象名与标签值，并按需补 `prune_allowlist`。
- 代价：脚本按单元复制，约 90 行重复。预演、确认、预检等公共逻辑改动要逐个单元同步；单元多了再考虑生成或共享库。
- 代价：`prune_allowlist` 的“只增不减”靠 review 把关，没有机器校验；脚本里用注释写明了原因。
- 代价：列表里任一类型在目标集群不存在时，apply 直接报 `no matches for kind`；显式失败优于静默漏回收。
- 代价：每次 prune 对列表里的每个类型各做一次列举（当前 1 次），随类型数量线性增加。
- 覆盖缺口：集群级或跨命名空间目录（将来的 `cluster/`）没有对应的命名空间名与选择器，需要自己的脚本与 note；脚本目前会因标签值不匹配而拒绝运行。
- 覆盖缺口：不提供回滚，也不校验集群上下文是否正确——只打印当前 context 供人确认。
