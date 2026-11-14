#!/usr/bin/env bash
# 应用本命名空间单元（本脚本所在目录），并按 managed-by=<ns> 回收已从仓库删除的对象：
#   kubectl apply -k <本目录> -n <ns> --prune -l managed-by=<ns> --prune-allowlist=...
#
# 默认先跑一次 server dry-run 预演（会列出将被 prune 的对象），确认后才真正执行。

set -euo pipefail

usage() {
  cat <<'EOF'
用法: ./namespaces/<ns>/apply.sh [选项] [-- <额外的 kubectl apply 参数>]

应用本目录的 Kustomization 到命名空间 <ns>（由脚本所在目录决定），
并按 managed-by=<ns> 回收已从仓库删除的对象。

选项:
  -y, --yes       不做确认，直接应用（脚本 / CI 用）
      --dry-run   只做 server dry-run 预演，不修改任何对象
  -h, --help      显示本帮助

示例:
  ./namespaces/xxxistaken/apply.sh
  ./namespaces/xxxistaken/apply.sh --dry-run
  ./namespaces/xxxistaken/apply.sh --yes -- --force-conflicts
EOF
}

die() {
  printf '%s: %s\n' "${0##*/}" "$*" >&2
  exit 1
}

assume_yes=false
preview_only=false
extra=()

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    -y|--yes)
      assume_yes=true
      shift
      ;;
    --dry-run)
      preview_only=true
      shift
      ;;
    --)
      shift
      extra=("$@")
      break
      ;;
    -*)
      printf '%s: 未知选项 %s\n' "${0##*/}" "$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      printf '%s: 不接受位置参数，命名空间由脚本所在目录决定: %s\n' "${0##*/}" "$1" >&2
      exit 2
      ;;
  esac
done

command -v kubectl >/dev/null 2>&1 || die "找不到 kubectl"

# 命名空间名 = 本脚本所在目录名，路径与 -n 都由此推出，不提供覆盖入口。
unit_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ns=$(basename -- "$unit_dir")

case "$ns" in
  *[!a-z0-9-]* | -* | *-) die "目录名不是合法的命名空间名: $ns" ;;
esac

[ -f "$unit_dir/kustomization.yaml" ] ||
  die "$ns 目录里没有 kustomization.yaml"

# 目录名、标签值必须一致，否则 -l managed-by=<ns> 匹配不到本目录的对象。
label_value=$(sed -n 's/^[[:space:]]*managed-by:[[:space:]]*\([^[:space:]#]*\).*$/\1/p' \
  "$unit_dir/kustomization.yaml" | head -n1)
[ -n "$label_value" ] ||
  die "$ns/kustomization.yaml 里没有 labels 转换器声明的 managed-by 标签"
[ "$label_value" = "$ns" ] ||
  die "managed-by 值是 $label_value，与目录名 $ns 不一致：prune 会匹配不到本目录的对象"

# --prune 的目标类型，只列本单元【实际声明】的类型。当前目录声明了 Namespace、
# Service 与 StatefulSet，所以下面列这三类。
#
# StatefulSet 的 PVC 由控制器按 volumeClaimTemplates 创建，不带 managed-by 标签，
# 也不由 apply 管理；故意不列入 allowlist，避免把数据卷当成本单元对象回收。
#
# 列表只增不减：
#   - 新增资源类型时，把对应 <group>/<version>/<Kind> 加进来，否则该类型的对象
#     即使带 managed-by 标签也不会被回收（漏回收，不会误删）；
#   - 只有在"该类型在本单元里再也不会出现"时才能删行，并且要先确认所有人都已
#     应用过最后一版包含它的清单——开发者 pull 到删行后的脚本时，本地集群里
#     由旧版清单创建的对象仍需被 prune，删行会让它们永远留在集群里。
prune_allowlist=(
  core/v1/Namespace
  core/v1/Service
  apps/v1/StatefulSet
)

context=$(kubectl config current-context 2>/dev/null || true)
printf '命名空间:   %s\n' "$ns"
printf '目录:       %s\n' "$unit_dir"
printf '集群上下文: %s\n' "${context:-<未设置，由 kubectl 默认规则决定>}"

selector="managed-by=$ns"
kubectl_args=(apply -k "$unit_dir" --namespace "$ns" --prune -l "$selector")
for resource in "${prune_allowlist[@]}"; do
  kubectl_args+=("--prune-allowlist=$resource")
done
if [ ${#extra[@]} -gt 0 ]; then
  kubectl_args+=("${extra[@]}")
fi

printf '\n== 预演 (server dry-run) ==\n'
printf 'kubectl apply -k %s -n %s --prune -l %s --prune-allowlist=<%d 种类型> --dry-run=server\n\n' \
  "$unit_dir" "$ns" "$selector" "${#prune_allowlist[@]}"
kubectl "${kubectl_args[@]}" --dry-run=server

if [ "$preview_only" = true ]; then
  printf '\n仅预演，未修改任何对象。\n'
  exit 0
fi

if [ "$assume_yes" != true ]; then
  printf '\n确认应用（上面标记为 pruned 的对象会被删除）? [y/N] '
  if ! read -r reply; then
    printf '\n已取消。\n'
    exit 1
  fi
  case "$reply" in
    y | Y | yes | YES) ;;
    *)
      printf '已取消。\n'
      exit 1
      ;;
  esac
fi

printf '\n== 应用 ==\n'
kubectl "${kubectl_args[@]}"
