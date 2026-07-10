#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PATH="${ROOT}/.ha/bin:${PATH}"

log() {
  printf '[private-cloud-ci] %s\n' "$*"
}

cd "$ROOT"

log "running ha test --terraform-init"
"${ROOT}/ha" test --terraform-init "$@"

if command -v actionlint >/dev/null 2>&1; then
  log "running actionlint"
  actionlint .github/workflows/*.yml
else
  log "actionlint not installed; skipping workflow lint"
fi

if command -v kubectl >/dev/null 2>&1; then
  log "rendering Kubernetes kustomize overlays"
  kubectl kustomize private/kubernetes >/dev/null
  kubectl kustomize private/storage >/dev/null
  kubectl kustomize private/gpu-worker >/dev/null
  kubectl kustomize private/kubernetes/model-build-workflows >/dev/null
else
  log "kubectl not installed; kustomize render already covered by ha test skip/fallback"
fi

log "complete"
