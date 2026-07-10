#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALUES_FILE="${SCRIPT_DIR}/values.yaml"

NAMESPACE="${GITLAB_RUNNER_NAMESPACE:-model-build}"
RELEASE_NAME="${GITLAB_RUNNER_RELEASE:-gitlab-runner}"
CHART_VERSION="${GITLAB_RUNNER_CHART_VERSION:-0.89.1}"
RUNNER_SECRET_NAME="${GITLAB_RUNNER_SECRET_NAME:-gitlab-runner}"
RUNNER_SECRET_KEY="${GITLAB_RUNNER_SECRET_KEY:-runner-token}"
RUNNER_REGISTRATION_SECRET_KEY="${GITLAB_RUNNER_REGISTRATION_SECRET_KEY:-runner-registration-token}"
HARBOR_PULL_SECRET_NAME="${HARBOR_PULL_SECRET_NAME:-harbor-kaniko-push}"
CERT_SECRET_NAME="${GITLAB_RUNNER_CERT_SECRET_NAME:-gitlab-runner-certs}"
DEPLOYMENT_NAME="${GITLAB_RUNNER_DEPLOYMENT_NAME:-gitlab-runner}"
HELM_BIN="${HELM_BIN:-helm}"
ROLLOUT_TIMEOUT="${GITLAB_RUNNER_ROLLOUT_TIMEOUT:-300s}"
GITLAB_URL="${GITLAB_URL:-https://gitlab.intp.me}"
HOST_ALIAS_IP="${GITLAB_RUNNER_HOST_ALIAS_IP:-100.110.101.77}"
NODE_SELECTOR_HOSTNAME="${GITLAB_RUNNER_NODE_SELECTOR_HOSTNAME:-hybrid-ai-private-build-01}"
KUBECTL_SUDO="${KUBECTL_SUDO:-false}"
KUBECTL_KUBECONFIG="${KUBECTL_KUBECONFIG:-${KUBECONFIG:-}}"

require_tool() {
  local tool="$1"
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'gitlab-runner/install.sh: required command not found: %s\n' "$tool" >&2
    exit 1
  }
}

run_kubectl() {
  local -a cmd
  if [[ -n "$KUBECTL_KUBECONFIG" ]]; then
    cmd=(kubectl --kubeconfig "$KUBECTL_KUBECONFIG")
  else
    cmd=(kubectl)
  fi

  if [[ "$KUBECTL_SUDO" == "true" ]]; then
    sudo "${cmd[@]}" "$@"
  else
    "${cmd[@]}" "$@"
  fi
}

ensure_namespace() {
  if ! run_kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    run_kubectl create namespace "$NAMESPACE" >/dev/null
  fi
}

ensure_runner_secret() {
  if [[ -n "${GITLAB_RUNNER_AUTH_TOKEN:-}" ]]; then
    run_kubectl -n "$NAMESPACE" create secret generic "$RUNNER_SECRET_NAME" \
      --from-literal="${RUNNER_SECRET_KEY}=${GITLAB_RUNNER_AUTH_TOKEN}" \
      --from-literal="${RUNNER_REGISTRATION_SECRET_KEY}=" \
      --dry-run=client \
      -o yaml | run_kubectl apply -f - >/dev/null
    return
  fi

  if run_kubectl -n "$NAMESPACE" get secret "$RUNNER_SECRET_NAME" >/dev/null 2>&1; then
    return
  fi

  printf 'gitlab-runner/install.sh: missing runner token. Set GITLAB_RUNNER_AUTH_TOKEN or create secret %s in namespace %s.\n' \
    "$RUNNER_SECRET_NAME" "$NAMESPACE" >&2
  exit 1
}

require_secret() {
  local secret_name="$1"
  if ! run_kubectl -n "$NAMESPACE" get secret "$secret_name" >/dev/null 2>&1; then
    printf 'gitlab-runner/install.sh: required secret not found: %s/%s\n' "$NAMESPACE" "$secret_name" >&2
    exit 1
  fi
}

create_override_values() {
  local override_file="$1"
  cat >"$override_file" <<EOF
gitlabUrl: ${GITLAB_URL}
namespace: ${NAMESPACE}
hostAliases:
  - ip: ${HOST_ALIAS_IP}
    hostnames:
      - gitlab.intp.me
nodeSelector:
  kubernetes.io/hostname: ${NODE_SELECTOR_HOSTNAME}
runners:
  executor: kubernetes
  name: private-model-build-runner
  tags: "gpu-worker,private,ecr-sync,model-build"
  runUntagged: false
  locked: false
  config: |
    [[runners]]
      environment = [
        "HA_PRIVATE_CACHE_DIR=/opt/hybrid-ai/bastion-cache",
        "PIP_FIND_LINKS=/opt/hybrid-ai/bastion-cache/pip/wheelhouse"
      ]
      request_concurrency = 2

      [runners.kubernetes]
        namespace = "${NAMESPACE}"
        service_account = "model-build-runner"
        image = "harbor.intp.me/docker-hub/library/alpine:latest"
        helper_image = "harbor.intp.me/docker-hub/gitlab/gitlab-runner-helper:x86_64-v19.0.1"
        privileged = true
        memory_request = "2Gi"
        memory_limit = "10Gi"
        poll_timeout = 900
        image_pull_secrets = ["${HARBOR_PULL_SECRET_NAME}"]

        [runners.kubernetes.node_selector]
          "kubernetes.io/hostname" = "${NODE_SELECTOR_HOSTNAME}"

        [[runners.kubernetes.volumes.host_path]]
          name = "bastion-cache"
          mount_path = "/opt/hybrid-ai/bastion-cache"
          host_path = "/opt/hybrid-ai/bastion-cache"
          read_only = true
EOF
}

main() {
  require_tool kubectl
  require_tool "$HELM_BIN"

  [[ -f "$VALUES_FILE" ]] || {
    printf 'gitlab-runner/install.sh: values file not found: %s\n' "$VALUES_FILE" >&2
    exit 1
  }

  "$HELM_BIN" repo add gitlab https://charts.gitlab.io --force-update >/dev/null
  "$HELM_BIN" repo update >/dev/null

  ensure_namespace
  ensure_runner_secret
  require_secret "$HARBOR_PULL_SECRET_NAME"
  require_secret "$CERT_SECRET_NAME"

  local override_file
  override_file="$(mktemp)"
  trap 'rm -f "$override_file"' EXIT
  create_override_values "$override_file"

  # The official chart reads the runner authentication token from the Secret named
  # in .Values.secret. Keep runner-registration-token present but empty for chart compatibility.
  "$HELM_BIN" upgrade --install "$RELEASE_NAME" gitlab/gitlab-runner \
    --namespace "$NAMESPACE" \
    --version "$CHART_VERSION" \
    -f "$VALUES_FILE" \
    -f "$override_file"

  run_kubectl -n "$NAMESPACE" rollout status deployment/"$DEPLOYMENT_NAME" --timeout="$ROLLOUT_TIMEOUT"
}

main "$@"
