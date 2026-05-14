#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir() {
  local source="${BASH_SOURCE[0]}"
  local dir

  while [[ -L "$source" ]]; do
    dir="$(cd -P "$(dirname "$source")" && pwd)"
    source="$(readlink "$source")"
    [[ "$source" != /* ]] && source="${dir}/${source}"
  done

  cd -P "$(dirname "$source")" && pwd
}

ROOT="$(cd "$(script_dir)/../../.." && pwd)"
OPENSTACK_DIR="${ROOT}/infra/private-cloud/openstack"
HANDOFF_DIR="${HA_HANDOFF_DIR:-${ROOT}/.ha/handoff}"
KUBECONFIG_PATH="${HA_OPENSTACK_KUBECONFIG:-${ROOT}/.ha/openstack/kubeconfig}"
K3S_TOKEN_FILE="${HA_K3S_TOKEN_FILE:-${ROOT}/.ha/openstack/k3s-token}"
SSH_USER="${HA_OPENSTACK_SSH_USER:-ubuntu}"
SSH_KEY="${HA_OPENSTACK_SSH_KEY:-${ROOT}/.ha/ssh/hybrid-ai-private-admin}"
SSH_TARGET="${HA_OPENSTACK_SSH_TARGET:-auto}"
SSH_PROXY_CONTAINER="${HA_OPENSTACK_SSH_PROXY_CONTAINER:-}"
K3S_CHANNEL="${HA_K3S_CHANNEL:-stable}"
K3S_DISABLE_COMPONENTS="${HA_K3S_DISABLE_COMPONENTS:-traefik}"
DRY_RUN=0

info() {
  printf '%s\n' "$*"
}

die() {
  printf 'bootstrap-k3s: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  bootstrap-k3s.sh [--dry-run]

Environment:
  HA_OPENSTACK_SSH_USER              SSH user for node images. Default: ubuntu
  HA_OPENSTACK_SSH_KEY               Private key path. Default: .ha/ssh/hybrid-ai-private-admin
  HA_OPENSTACK_SSH_TARGET            auto|floating_ip|private_ip. Default: auto
  HA_OPENSTACK_SSH_PROXY_CONTAINER   Optional LXD container used as SSH ProxyCommand
  HA_OPENSTACK_KUBECONFIG            Output kubeconfig path. Default: .ha/openstack/kubeconfig
  HA_K3S_TOKEN_FILE                  Token file path. Default: .ha/openstack/k3s-token
  HA_K3S_CHANNEL                     k3s install channel. Default: stable
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

require_tool() {
  local tool="$1"
  command -v "$tool" >/dev/null 2>&1 || die "required command not found: ${tool}"
}

ssh_options() {
  local known_hosts="${ROOT}/.ha/ssh/known_hosts"

  mkdir -p "$(dirname "$known_hosts")"
  printf '%s\n' \
    -o BatchMode=yes \
    -o ConnectTimeout=20 \
    -o StrictHostKeyChecking=no \
    -o CheckHostIP=no \
    -o "UserKnownHostsFile=${known_hosts}" \
    -i "$SSH_KEY"

  if [[ -n "$SSH_PROXY_CONTAINER" ]]; then
    printf '%s\n' -o "ProxyCommand=lxc exec ${SSH_PROXY_CONTAINER} -- nc %h %p"
  fi
}

forget_known_host() {
  local host="$1"
  local known_hosts="${ROOT}/.ha/ssh/known_hosts"

  if [[ -f "$known_hosts" ]] && command -v ssh-keygen >/dev/null 2>&1; then
    ssh-keygen -f "$known_hosts" -R "$host" >/dev/null 2>&1 || true
  fi
}

ssh_node() {
  local host="$1"
  shift

  ssh $(ssh_options) "${SSH_USER}@${host}" "$@"
}

ensure_k3s_token() {
  mkdir -p "$(dirname "$K3S_TOKEN_FILE")"
  if [[ ! -f "$K3S_TOKEN_FILE" ]]; then
    if command -v openssl >/dev/null 2>&1; then
      openssl rand -hex 32 >"$K3S_TOKEN_FILE"
    else
      date +%s%N | sha256sum | awk '{print $1}' >"$K3S_TOKEN_FILE"
    fi
    chmod 600 "$K3S_TOKEN_FILE"
  fi
}

terraform_inventory() {
  local output_file

  output_file="$(mktemp)"
  terraform -chdir="$OPENSTACK_DIR" output -json >"$output_file"
  python3 - "$SSH_TARGET" "$output_file" <<'PY'
import json
import sys

target_mode = sys.argv[1]
output_file = sys.argv[2]
with open(output_file, "r", encoding="utf-8") as handle:
    data = json.load(handle)

def nodes(name):
    return data.get(name, {}).get("value", []) or []

def target_ip(node):
    private_ip = node.get("private_ip") or ""
    floating_ip = node.get("floating_ip") or ""
    if target_mode == "private_ip":
        return private_ip
    if target_mode == "floating_ip":
        return floating_ip
    return floating_ip or private_ip

for output_name, role in (
    ("control_plane_nodes", "control-plane"),
    ("build_worker_nodes", "build-worker"),
    ("gpu_worker_nodes", "gpu-worker"),
):
    for node in nodes(output_name):
        ip = target_ip(node)
        if not ip:
            continue
        print(
            role,
            node.get("name", ""),
            node.get("private_ip", "") or "",
            node.get("floating_ip", "") or "",
            ip,
            sep="|",
        )
PY
  rm -f "$output_file"
}

NODE_ROLES=()
NODE_NAMES=()
NODE_PRIVATE_IPS=()
NODE_FLOATING_IPS=()
NODE_TARGET_IPS=()

load_inventory() {
  local role name private_ip floating_ip target_ip

  while IFS='|' read -r role name private_ip floating_ip target_ip; do
    [[ -n "$role" && -n "$name" && -n "$target_ip" ]] || continue
    NODE_ROLES+=("$role")
    NODE_NAMES+=("$name")
    NODE_PRIVATE_IPS+=("$private_ip")
    NODE_FLOATING_IPS+=("$floating_ip")
    NODE_TARGET_IPS+=("$target_ip")
  done < <(terraform_inventory)

  [[ "${#NODE_ROLES[@]}" -gt 0 ]] || die "no nodes found in Terraform output"
}

first_control_plane_index() {
  local index

  for index in "${!NODE_ROLES[@]}"; do
    if [[ "${NODE_ROLES[$index]}" == "control-plane" ]]; then
      printf '%s\n' "$index"
      return
    fi
  done

  die "no control-plane node found in Terraform output"
}

print_inventory() {
  local index

  info "OpenStack Kubernetes bootstrap inventory:"
  for index in "${!NODE_ROLES[@]}"; do
    printf '  %s\t%s\tprivate=%s\tfloating=%s\tssh=%s\n' \
      "${NODE_ROLES[$index]}" \
      "${NODE_NAMES[$index]}" \
      "${NODE_PRIVATE_IPS[$index]:-none}" \
      "${NODE_FLOATING_IPS[$index]:-none}" \
      "${NODE_TARGET_IPS[$index]}"
  done
}

wait_for_ssh() {
  local host="$1"
  local name="$2"
  local deadline=$((SECONDS + 300))

  forget_known_host "$host"
  while (( SECONDS < deadline )); do
    if ssh_node "$host" 'true' >/dev/null 2>&1; then
      return
    fi
    sleep 5
  done

  die "SSH did not become ready for ${name} (${host})"
}

k3s_server_ready() {
  local host="$1"

  ssh_node "$host" 'test -x /usr/local/bin/k3s && sudo k3s kubectl get --raw=/readyz >/dev/null 2>&1'
}

reset_incomplete_k3s() {
  local host="$1"
  local name="$2"

  if ssh_node "$host" 'test -x /usr/local/bin/k3s' && ! k3s_server_ready "$host"; then
    info "Resetting incomplete k3s install on ${name}"
    ssh_node "$host" 'sudo /usr/local/bin/k3s-uninstall.sh >/dev/null 2>&1 || true; sudo /usr/local/bin/k3s-agent-uninstall.sh >/dev/null 2>&1 || true'
  fi
}

install_k3s_control_plane_init() {
  local host="$1"
  local name="$2"
  local api_ip="$3"
  local token="$4"

  reset_incomplete_k3s "$host" "$name"
  if k3s_server_ready "$host"; then
    info "ok: k3s already installed on ${name}"
    return
  fi

  info "Installing k3s initial control-plane: ${name}"
  ssh_node "$host" "curl -sfL https://get.k3s.io | K3S_TOKEN='${token}' INSTALL_K3S_CHANNEL='${K3S_CHANNEL}' INSTALL_K3S_EXEC='server --cluster-init --write-kubeconfig-mode 644 --disable ${K3S_DISABLE_COMPONENTS} --tls-san ${api_ip} --node-label hybrid-ai.io/node-role=control-plane' sh -"
}

install_k3s_control_plane_join() {
  local host="$1"
  local name="$2"
  local server_ip="$3"
  local token="$4"

  reset_incomplete_k3s "$host" "$name"
  if k3s_server_ready "$host"; then
    info "ok: k3s already installed on ${name}"
    return
  fi

  info "Joining k3s control-plane: ${name}"
  ssh_node "$host" "curl -sfL https://get.k3s.io | K3S_URL='https://${server_ip}:6443' K3S_TOKEN='${token}' INSTALL_K3S_CHANNEL='${K3S_CHANNEL}' INSTALL_K3S_EXEC='server --disable ${K3S_DISABLE_COMPONENTS} --node-label hybrid-ai.io/node-role=control-plane' sh -"
}

install_k3s_agent() {
  local host="$1"
  local name="$2"
  local role="$3"
  local server_ip="$4"
  local token="$5"
  local labels

  labels="--node-label hybrid-ai.io/node-role=${role}"
  if [[ "$role" == "gpu-worker" ]]; then
    labels="${labels} --node-label hybrid-ai.io/accelerator=nvidia --node-taint nvidia.com/gpu=true:NoSchedule"
  fi

  if ssh_node "$host" 'test -x /usr/local/bin/k3s-agent'; then
    info "ok: k3s agent already installed on ${name}"
    return
  fi

  info "Joining k3s worker: ${name}"
  ssh_node "$host" "curl -sfL https://get.k3s.io | K3S_URL='https://${server_ip}:6443' K3S_TOKEN='${token}' INSTALL_K3S_CHANNEL='${K3S_CHANNEL}' INSTALL_K3S_EXEC='agent ${labels}' sh -"
}

label_nodes() {
  local host="$1"
  local index

  for index in "${!NODE_ROLES[@]}"; do
    case "${NODE_ROLES[$index]}" in
      control-plane)
        ssh_node "$host" "sudo k3s kubectl label node '${NODE_NAMES[$index]}' hybrid-ai.io/node-role=control-plane --overwrite >/dev/null"
        ;;
      build-worker)
        ssh_node "$host" "sudo k3s kubectl label node '${NODE_NAMES[$index]}' hybrid-ai.io/node-role=build-worker node-role.kubernetes.io/build-worker=true --overwrite >/dev/null"
        ;;
      gpu-worker)
        ssh_node "$host" "sudo k3s kubectl label node '${NODE_NAMES[$index]}' hybrid-ai.io/node-role=gpu-worker hybrid-ai.io/accelerator=nvidia node-role.kubernetes.io/gpu-worker=true --overwrite >/dev/null"
        ;;
    esac
  done
}

write_kubeconfig() {
  local host="$1"
  local endpoint="$2"
  local tmp

  mkdir -p "$(dirname "$KUBECONFIG_PATH")"
  tmp="$(mktemp)"
  ssh_node "$host" 'sudo cat /etc/rancher/k3s/k3s.yaml' >"$tmp"
  sed -i "s#https://127.0.0.1:6443#https://${endpoint}:6443#" "$tmp"
  mv "$tmp" "$KUBECONFIG_PATH"
  chmod 600 "$KUBECONFIG_PATH"
}

write_handoff() {
  local server_name="$1"
  local endpoint="$2"
  local info_file="${HANDOFF_DIR}/openstack-kubernetes.env"

  mkdir -p "$HANDOFF_DIR"
  {
    printf 'HA_PROVIDER=%q\n' "openstack"
    printf 'KUBECONFIG=%q\n' "$KUBECONFIG_PATH"
    printf 'KUBERNETES_API_ENDPOINT=%q\n' "https://${endpoint}:6443"
    printf 'K3S_INITIAL_CONTROL_PLANE=%q\n' "$server_name"
    printf 'HA_OPENSTACK_SSH_USER=%q\n' "$SSH_USER"
    printf 'HA_OPENSTACK_SSH_TARGET_IP=%q\n' "$endpoint"
    if [[ -n "$SSH_PROXY_CONTAINER" ]]; then
      printf 'HA_OPENSTACK_SSH_PROXY_CONTAINER=%q\n' "$SSH_PROXY_CONTAINER"
    fi
  } >"$info_file"
  chmod 600 "$info_file"
  info "Wrote OpenStack Kubernetes handoff: ${info_file#${ROOT}/}"
}

wait_for_kubernetes() {
  local host="$1"
  local deadline=$((SECONDS + 420))

  while (( SECONDS < deadline )); do
    if ssh_node "$host" 'sudo k3s kubectl get --raw=/readyz >/dev/null 2>&1'; then
      break
    fi
    sleep 5
  done

  ssh_node "$host" 'sudo k3s kubectl get --raw=/readyz >/dev/null'
  ssh_node "$host" 'sudo k3s kubectl wait --for=condition=Ready nodes --all --timeout=300s'
  ssh_node "$host" 'if sudo k3s kubectl get pods -n kube-system --no-headers 2>/dev/null | grep -q .; then sudo k3s kubectl wait --for=condition=Ready pods --all -n kube-system --timeout=300s; fi'
}

main() {
  local first_index
  local server_private_ip
  local server_target_ip
  local server_name
  local token
  local index

  require_tool terraform
  require_tool python3
  require_tool ssh
  [[ -f "$SSH_KEY" ]] || die "SSH private key not found: ${SSH_KEY}"

  load_inventory
  print_inventory

  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "Dry run only; no SSH changes applied."
    return
  fi

  ensure_k3s_token
  token="$(<"$K3S_TOKEN_FILE")"

  first_index="$(first_control_plane_index)"
  server_private_ip="${NODE_PRIVATE_IPS[$first_index]}"
  server_target_ip="${NODE_TARGET_IPS[$first_index]}"
  server_name="${NODE_NAMES[$first_index]}"

  wait_for_ssh "$server_target_ip" "$server_name"
  install_k3s_control_plane_init "$server_target_ip" "$server_name" "$server_target_ip" "$token"

  for index in "${!NODE_ROLES[@]}"; do
    [[ "$index" != "$first_index" ]] || continue
    wait_for_ssh "${NODE_TARGET_IPS[$index]}" "${NODE_NAMES[$index]}"
    case "${NODE_ROLES[$index]}" in
      control-plane)
        install_k3s_control_plane_join "${NODE_TARGET_IPS[$index]}" "${NODE_NAMES[$index]}" "$server_private_ip" "$token"
        ;;
      build-worker|gpu-worker)
        install_k3s_agent "${NODE_TARGET_IPS[$index]}" "${NODE_NAMES[$index]}" "${NODE_ROLES[$index]}" "$server_private_ip" "$token"
        ;;
    esac
  done

  wait_for_kubernetes "$server_target_ip"
  label_nodes "$server_target_ip"
  write_kubeconfig "$server_target_ip" "$server_target_ip"
  write_handoff "$server_name" "$server_target_ip"
  info "ok: OpenStack Kubernetes bootstrap complete"
}

main "$@"
