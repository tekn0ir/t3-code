#!/usr/bin/env bash
# Create (or update) the self-contained cliproxyapi Argo CD Application on r415.
#
#   ./scripts/bootstrap-argocd.sh             # apply deploy/argocd/cliproxyapi-app.yaml
#   ./scripts/bootstrap-argocd.sh --dry-run   # server-side dry run, changes nothing
#   ./scripts/bootstrap-argocd.sh --delete    # remove the Application (resources are pruned)
#
# The gitops release guard denies hand-made writes to Applications unless the teknoir-system
# Namespace carries teknoir.org/release-guard=break-glass. This script opens break-glass, applies,
# and closes it again (also on failure). If break-glass was already open, it is left open.
#
# Environment: KUBE_CONTEXT (default r415).
set -euo pipefail

CTX="${KUBE_CONTEXT:-r415}"
NS=teknoir-system
ANNOTATION=teknoir.org/release-guard
APP_FILE="$(cd "$(dirname "$0")/.." && pwd)/deploy/argocd/cliproxyapi-app.yaml"
MODE=apply

case "${1:-}" in
  "") ;;
  --dry-run) MODE=dry-run ;;
  --delete) MODE=delete ;;
  -h|--help) sed -n '2,13{s/^# \{0,1\}//;p;}' "$0"; exit 0 ;;
  *) echo "unknown option: $1" >&2; exit 2 ;;
esac

k() { kubectl --context "$CTX" "$@"; }

k get namespace "$NS" >/dev/null || { echo "cannot reach ${NS} on context ${CTX}" >&2; exit 1; }

if [ "$MODE" = dry-run ]; then
  k apply --dry-run=server -f "$APP_FILE"
  exit 0
fi

was_open="$(k get namespace "$NS" -o jsonpath="{.metadata.annotations.teknoir\.org/release-guard}")"
close_glass() {
  if [ "$was_open" != break-glass ]; then
    echo "==> closing break-glass on ${NS}" >&2
    k annotate namespace "$NS" "${ANNOTATION}-" >/dev/null
  fi
}
if [ "$was_open" != break-glass ]; then
  echo "==> opening break-glass on ${NS}" >&2
  k annotate namespace "$NS" "${ANNOTATION}=break-glass" --overwrite >/dev/null
  trap close_glass EXIT
fi

if [ "$MODE" = delete ]; then
  k -n "$NS" delete application cliproxyapi --ignore-not-found
else
  k apply -f "$APP_FILE"
  echo "==> Application applied; watch it with:" >&2
  echo "    kubectl --context ${CTX} -n ${NS} get application cliproxyapi -w" >&2
fi
