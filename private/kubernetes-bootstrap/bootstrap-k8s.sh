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

ROOT="$(cd "$(script_dir)/../.." && pwd)"
OPENSTACK_DIR="${ROOT}/private/openstack"
OPENSTACK_TFSTATE="${HA_OPENSTACK_TFSTATE:-}"
if [[ -n "$OPENSTACK_TFSTATE" && "$OPENSTACK_TFSTATE" != /* ]]; then
  OPENSTACK_TFSTATE="${ROOT}/${OPENSTACK_TFSTATE}"
fi
OPENSTACK_TF_OUTPUT_JSON="${HA_OPENSTACK_TF_OUTPUT_JSON:-}"
if [[ -n "$OPENSTACK_TF_OUTPUT_JSON" && "$OPENSTACK_TF_OUTPUT_JSON" != /* ]]; then
  OPENSTACK_TF_OUTPUT_JSON="${ROOT}/${OPENSTACK_TF_OUTPUT_JSON}"
fi
HANDOFF_DIR="${HA_HANDOFF_DIR:-${ROOT}/.ha/handoff}"
KUBECONFIG_PATH="${HA_OPENSTACK_KUBECONFIG:-${ROOT}/.ha/openstack/kubeconfig}"
SSH_USER="${HA_OPENSTACK_SSH_USER:-ubuntu}"
SSH_KEY="${HA_OPENSTACK_SSH_KEY:-${ROOT}/.ha/ssh/hybrid-ai-private-admin}"
SSH_TARGET="${HA_OPENSTACK_SSH_TARGET:-auto}"
SSH_PROXY_CONTAINER="${HA_OPENSTACK_SSH_PROXY_CONTAINER:-}"
SSH_PROXY_NETNS_NC="${HA_OPENSTACK_SSH_PROXY_NETNS_NC:-}"
K8S_VERSION_MINOR="${HA_K8S_VERSION_MINOR:-v1.36}"
K8S_POD_CIDR="${HA_K8S_POD_CIDR:-192.168.0.0/16}"
K8S_CNI_MANIFEST="${HA_K8S_CNI_MANIFEST:-https://raw.githubusercontent.com/projectcalico/calico/v3.32.0/manifests/calico.yaml}"
K8S_API_ENDPOINT="${HA_K8S_API_ENDPOINT:-}"
KUBEADM_IGNORE_PREFLIGHT="${HA_K8S_KUBEADM_IGNORE_PREFLIGHT:-NumCPU}"
DRY_RUN=0

info() {
  printf '%s\n' "$*"
}

die() {
  printf 'bootstrap-k8s: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  bootstrap-k8s.sh [--dry-run]

Environment:
  HA_OPENSTACK_SSH_USER              SSH user for node images. Default: ubuntu
  HA_OPENSTACK_SSH_KEY               Private key path. Default: .ha/ssh/hybrid-ai-private-admin
  HA_OPENSTACK_SSH_TARGET            auto|floating_ip|private_ip. Default: auto
  HA_OPENSTACK_SSH_PROXY_CONTAINER   Optional LXD container used as SSH ProxyCommand
  HA_OPENSTACK_KUBECONFIG            Output kubeconfig path. Default: .ha/openstack/kubeconfig
  HA_OPENSTACK_TFSTATE               Optional local Terraform state path for node inventory
  HA_OPENSTACK_TF_OUTPUT_JSON        Optional Terraform output JSON artifact path
  HA_K8S_VERSION_MINOR               Kubernetes apt repository minor. Default: v1.36
  HA_K8S_POD_CIDR                    Pod CIDR used by kubeadm and CNI. Default: 192.168.0.0/16
  HA_K8S_CNI_MANIFEST                CNI manifest URL/path. Default: Calico
  HA_K8S_API_ENDPOINT                Public kubeconfig endpoint host[:port]. Default: first control-plane SSH target
  HA_K8S_KUBEADM_IGNORE_PREFLIGHT    Comma-separated kubeadm preflight checks to ignore. Default: NumCPU
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

  if [[ -n "$SSH_PROXY_NETNS_NC" ]]; then
    # Kolla: qdhcp netns nc 래퍼 경유 (좁은 NOPASSWD sudoers)
    printf '%s\n' -o "ProxyCommand=sudo ${SSH_PROXY_NETNS_NC} %h %p"
  elif [[ -n "$SSH_PROXY_CONTAINER" ]]; then
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
  local -a options
  shift

  mapfile -t options < <(ssh_options)
  # shellcheck disable=SC2029
  ssh "${options[@]}" "${SSH_USER}@${host}" "$@"
}

terraform_inventory() {
  local output_file

  output_file="$(mktemp)"
  if [[ -n "$OPENSTACK_TF_OUTPUT_JSON" ]]; then
    [[ -f "$OPENSTACK_TF_OUTPUT_JSON" ]] || die "Terraform output JSON not found: ${OPENSTACK_TF_OUTPUT_JSON}"
    cp "$OPENSTACK_TF_OUTPUT_JSON" "$output_file"
  elif [[ -n "$OPENSTACK_TFSTATE" ]]; then
    terraform -chdir="$OPENSTACK_DIR" output -state="$OPENSTACK_TFSTATE" -json >"$output_file"
  else
    terraform -chdir="$OPENSTACK_DIR" output -json >"$output_file"
  fi

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
    ("harbor_nodes", "harbor"),
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

kubernetes_server_ready() {
  local host="$1"

  ssh_node "$host" 'test -f /etc/kubernetes/admin.conf && sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get --raw=/readyz >/dev/null 2>&1'
}

kubernetes_worker_active() {
  local host="$1"

  ssh_node "$host" 'test -f /etc/kubernetes/kubelet.conf && systemctl is-active --quiet kubelet'
}

reboot_node_if_required() {
  local host="$1"
  local name="$2"

  if ! ssh_node "$host" 'test -f /var/run/reboot-required'; then
    return
  fi

  info "Rebooting ${name} to load provisioned kernel before Kubernetes join"
  ssh_node "$host" 'sudo nohup sh -c "sleep 2; reboot" >/dev/null 2>&1 &' || true
  sleep 10
  wait_for_ssh "$host" "$name"
  ssh_node "$host" 'cloud-init status --wait >/dev/null 2>&1 || true'
}

prepare_kubernetes_node() {
  local host="$1"
  local name="$2"

  info "Preparing Kubernetes node dependencies: ${name}"
  ssh_node "$host" sudo bash -s -- "$K8S_VERSION_MINOR" <<'REMOTE'
set -euo pipefail
version_minor="$1"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

wait_for_cloud_init() {
  command -v cloud-init >/dev/null 2>&1 || return 0

  local deadline=$((SECONDS + 1800))
  local status
  while true; do
    status="$(cloud-init status 2>/dev/null || true)"
    if ! grep -q '^status: running$' <<<"$status"; then
      cloud-init status --long || true
      return 0
    fi
    if (( SECONDS >= deadline )); then
      echo "Timed out waiting for cloud-init to finish; continuing with apt lock wait" >&2
      cloud-init status --long || true
      return 0
    fi
    sleep 10
  done
}

wait_for_apt_locks() {
  local deadline=$((SECONDS + 900))
  local locks=(
    /var/lib/dpkg/lock
    /var/lib/dpkg/lock-frontend
    /var/lib/apt/lists/lock
    /var/cache/apt/archives/lock
  )

  while true; do
    local busy=0
    if command -v fuser >/dev/null 2>&1; then
      for lock in "${locks[@]}"; do
        if fuser "$lock" >/dev/null 2>&1; then
          busy=1
          break
        fi
      done
    elif pgrep -x apt >/dev/null 2>&1 || pgrep -x apt-get >/dev/null 2>&1 || pgrep -x dpkg >/dev/null 2>&1 || pgrep -x unattended-upgrade >/dev/null 2>&1; then
      busy=1
    fi

    [[ "$busy" -eq 0 ]] && return 0
    if (( SECONDS >= deadline )); then
      echo "Timed out waiting for apt/dpkg locks" >&2
      return 1
    fi
    sleep 5
  done
}

apt_get() {
  local attempt
  local apt_opts=(
    -o Acquire::ForceIPv4=true
    -o Acquire::Retries=5
    -o Acquire::http::Timeout=30
    -o Acquire::https::Timeout=30
    -o Dpkg::Lock::Timeout=900
  )
  for attempt in {1..12}; do
    # Best-effort lock wait; do not abort under set -e if it times out, because
    # apt-get itself waits up to Dpkg::Lock::Timeout for the lock.
    wait_for_apt_locks || true
    if apt-get "${apt_opts[@]}" "$@"; then
      return 0
    fi
    if (( attempt == 12 )); then
      return 1
    fi
    echo "apt-get $* failed; retrying after apt/dpkg lock check (${attempt}/12)" >&2
    sleep 10
  done
}

wait_for_cloud_init

# Ubuntu's apt-daily / apt-daily-upgrade / unattended-upgrades grab the dpkg lock
# right after first boot. On a freshly created VM they can hold it for 15+ minutes,
# which blocks the kubeadm package installs below. Stop them up front so the lock
# clears quickly (apt_get still tolerates a transient lock via Dpkg::Lock::Timeout).
systemctl disable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true
systemctl stop apt-daily.service apt-daily-upgrade.service unattended-upgrades.service >/dev/null 2>&1 || true

cat >/etc/apt/apt.conf.d/99hybrid-ai-force-ipv4 <<'EOF'
Acquire::ForceIPv4 "true";
Acquire::Retries "5";
Acquire::http::Timeout "30";
Acquire::https::Timeout "30";
Dpkg::Lock::Timeout "900";
EOF

swapoff -a || true
sed -ri '/\sswap\s/s/^/#/' /etc/fstab || true

cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay || true
modprobe br_netfilter || true

cat >/etc/sysctl.d/99-k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
sysctl --system >/dev/null || true

apt_get update -qq
apt_get install -y -qq apt-transport-https ca-certificates curl gpg containerd

mkdir -p /etc/containerd
containerd config default >/etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml || true
if command -v nvidia-container-runtime >/dev/null 2>&1; then
  mkdir -p /etc/containerd/conf.d
  if grep -q 'io.containerd.cri.v1.runtime' /etc/containerd/config.toml; then
    cat >/etc/containerd/conf.d/99-nvidia.toml <<'EOF'
version = 3

[plugins."io.containerd.cri.v1.runtime".containerd.runtimes.nvidia]
  runtime_type = "io.containerd.runc.v2"
  privileged_without_host_devices = false

  [plugins."io.containerd.cri.v1.runtime".containerd.runtimes.nvidia.options]
    BinaryName = "/usr/bin/nvidia-container-runtime"
    SystemdCgroup = true
EOF
  else
    cat >/etc/containerd/conf.d/99-nvidia.toml <<'EOF'
version = 2

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia]
  runtime_type = "io.containerd.runc.v2"
  privileged_without_host_devices = false

  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia.options]
    BinaryName = "/usr/bin/nvidia-container-runtime"
    SystemdCgroup = true
EOF
  fi
fi
systemctl enable --now containerd
systemctl restart containerd

mkdir -p -m 755 /etc/apt/keyrings
rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
curl -4 -fsSL --connect-timeout 10 --max-time 60 --retry 5 --retry-delay 5 "https://pkgs.k8s.io/core:/stable:/${version_minor}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg
cat >/etc/apt/sources.list.d/kubernetes.list <<EOF
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${version_minor}/deb/ /
EOF
apt_get update -qq
apt_get install -y -qq kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl >/dev/null
systemctl enable kubelet
REMOTE
}

ignore_preflight_arg() {
  if [[ -n "$KUBEADM_IGNORE_PREFLIGHT" ]]; then
    printf '%s\n' "--ignore-preflight-errors=${KUBEADM_IGNORE_PREFLIGHT}"
  fi
}

endpoint_host_for_san() {
  local endpoint="$1"

  endpoint="${endpoint#http://}"
  endpoint="${endpoint#https://}"
  endpoint="${endpoint%%/*}"
  if [[ "$endpoint" == \[*\]* ]]; then
    endpoint="${endpoint#\[}"
    endpoint="${endpoint%%\]*}"
  elif [[ "$endpoint" == *:* ]]; then
    endpoint="${endpoint%%:*}"
  fi
  printf '%s\n' "$endpoint"
}

install_k8s_control_plane_init() {
  local host="$1"
  local name="$2"
  local advertise_ip="$3"
  local api_endpoint="$4"
  local api_san

  if kubernetes_server_ready "$host"; then
    info "ok: Kubernetes already installed on ${name}"
    return
  fi

  prepare_kubernetes_node "$host" "$name"
  reboot_node_if_required "$host" "$name"
  if kubernetes_server_ready "$host"; then
    info "ok: Kubernetes already installed on ${name}"
    return
  fi

  api_san="$(endpoint_host_for_san "$api_endpoint")"
  info "Installing Kubernetes initial control-plane: ${name}"
  ssh_node "$host" bash -s -- "$name" "$advertise_ip" "$api_san" "$K8S_POD_CIDR" "$(ignore_preflight_arg)" "$K8S_CNI_MANIFEST" <<'REMOTE'
set -euo pipefail
node_name="$1"
advertise_ip="$2"
api_san="$3"
pod_cidr="$4"
ignore_preflight="$5"
cni_manifest="$6"

if [[ -f /etc/kubernetes/kubelet.conf || -f /etc/kubernetes/admin.conf ]]; then
  sudo kubeadm reset -f || true
fi

args=(
  kubeadm init
  "--pod-network-cidr=${pod_cidr}"
  "--node-name=${node_name}"
  "--apiserver-advertise-address=${advertise_ip}"
  --upload-certs
)
if [[ -n "$api_san" ]]; then
  args+=("--apiserver-cert-extra-sans=${api_san}")
fi
if [[ -n "$advertise_ip" && "$advertise_ip" != "$api_san" ]]; then
  args+=("--apiserver-cert-extra-sans=${advertise_ip}")
fi
if [[ -n "$ignore_preflight" ]]; then
  args+=("$ignore_preflight")
fi

sudo "${args[@]}"
sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f "$cni_manifest"
sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf taint nodes --all node-role.kubernetes.io/control-plane- >/dev/null 2>&1 || true
sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf taint nodes --all node-role.kubernetes.io/master- >/dev/null 2>&1 || true
REMOTE
}

create_worker_join_command() {
  local host="$1"

  create_join_command_with_retry "$host" worker
}

create_control_plane_join_command() {
  local host="$1"

  create_join_command_with_retry "$host" control-plane
}

extract_kubeadm_join_command() {
  awk '/^kubeadm[[:space:]]+join[[:space:]]/ { line=$0 } END { print line }'
}

redact_join_output() {
  sed -E \
    -e 's/(--token )[[:alnum:]._-]+/\1<redacted>/g' \
    -e 's/(--certificate-key )[[:xdigit:]]+/\1<redacted>/g' \
    -e 's/(sha256:)[[:xdigit:]]+/\1<redacted>/g'
}

base64_one_line() {
  printf '%s' "$1" | base64 | tr -d '\n'
}

is_valid_worker_join_command() {
  local join_command="$1"

  [[ "$join_command" == kubeadm\ join\ * ]] || return 1
  [[ "$join_command" == *" --token "* ]] || return 1
  [[ "$join_command" == *" --discovery-token-ca-cert-hash "* ]] || return 1
}

is_valid_control_plane_join_command() {
  local join_command="$1"

  is_valid_worker_join_command "$join_command" || return 1
  [[ "$join_command" == *" --control-plane"* ]] || return 1
  [[ "$join_command" == *" --certificate-key "* ]] || return 1
}

request_join_command() {
  local host="$1"
  local role="$2"

  case "$role" in
    worker)
      ssh_node "$host" 'sudo kubeadm token create --ttl 2h --print-join-command'
      ;;
    control-plane)
      # shellcheck disable=SC2016
      ssh_node "$host" 'certificate_key="$(sudo kubeadm init phase upload-certs --upload-certs | awk '"'"'NF { line=$0 } END { print line }'"'"')"; test -n "$certificate_key"; sudo kubeadm token create --ttl 2h --print-join-command --certificate-key "$certificate_key"'
      ;;
    *)
      die "unknown Kubernetes join command role: ${role}"
      ;;
  esac
}

create_join_command_with_retry() {
  local host="$1"
  local role="$2"
  local attempt
  local output
  local join_command
  local attempts="${HA_K8S_JOIN_COMMAND_ATTEMPTS:-12}"
  local retry_seconds="${HA_K8S_JOIN_COMMAND_RETRY_SECONDS:-10}"

  if ! [[ "$attempts" =~ ^[0-9]+$ ]] || [[ "$attempts" -lt 1 ]]; then
    attempts=12
  fi
  if ! [[ "$retry_seconds" =~ ^[0-9]+$ ]] || [[ "$retry_seconds" -lt 1 ]]; then
    retry_seconds=10
  fi

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    output="$(request_join_command "$host" "$role" 2>&1 || true)"
    join_command="$(printf '%s\n' "$output" | extract_kubeadm_join_command)"

    case "$role" in
      worker)
        if is_valid_worker_join_command "$join_command"; then
          printf '%s\n' "$join_command"
          return 0
        fi
        ;;
      control-plane)
        if is_valid_control_plane_join_command "$join_command"; then
          printf '%s\n' "$join_command"
          return 0
        fi
        ;;
    esac

    printf 'Waiting for valid Kubernetes %s join command from %s (%s/%s)\n' "$role" "$host" "$attempt" "$attempts" >&2
    if [[ -n "$output" ]]; then
      printf '%s\n' "$output" | redact_join_output | sed 's/^/  /' >&2
    fi
    sleep "$retry_seconds"
  done

  ssh_node "$host" 'sudo kubeadm token list || true; sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes -o wide || true' >&2 || true
  die "failed to create a valid Kubernetes ${role} join command from ${host}"
}

forget_kubernetes_node() {
  local host="$1"
  local name="$2"

  ssh_node "$host" bash -s -- "$name" <<'REMOTE'
set -euo pipefail
node_name="$1"
sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf delete node "$node_name" --ignore-not-found --wait=false >/dev/null
REMOTE
}

install_k8s_control_plane_join() {
  local host="$1"
  local name="$2"
  local advertise_ip="$3"
  local join_command="$4"
  local join_command_b64

  is_valid_control_plane_join_command "$join_command" || die "invalid Kubernetes control-plane join command for ${name}"
  join_command_b64="$(base64_one_line "$join_command")"
  if kubernetes_server_ready "$host"; then
    info "ok: Kubernetes already installed on ${name}"
    return
  fi

  prepare_kubernetes_node "$host" "$name"
  reboot_node_if_required "$host" "$name"
  if kubernetes_server_ready "$host"; then
    info "ok: Kubernetes already installed on ${name}"
    return
  fi

  info "Joining Kubernetes control-plane: ${name}"
  ssh_node "$host" bash -s -- "$name" "$advertise_ip" "$join_command_b64" "$(ignore_preflight_arg)" <<'REMOTE'
set -euo pipefail
node_name="$1"
advertise_ip="$2"
join_command="$(printf '%s' "$3" | base64 -d)"
ignore_preflight="$4"
read -r -a join_args <<<"$join_command"

if [[ "${#join_args[@]}" -lt 2 || "${join_args[0]}" != "kubeadm" || "${join_args[1]}" != "join" ]]; then
  echo "invalid Kubernetes control-plane join command for ${node_name}" >&2
  exit 1
fi

if [[ -f /etc/kubernetes/kubelet.conf || -f /etc/kubernetes/admin.conf ]]; then
  sudo kubeadm reset -f || true
fi

join_args+=(--node-name "$node_name" --apiserver-advertise-address "$advertise_ip")
if [[ -n "$ignore_preflight" ]]; then
  join_args+=("$ignore_preflight")
fi
sudo "${join_args[@]}"
REMOTE
}

install_k8s_worker() {
  local host="$1"
  local name="$2"
  local role="$3"
  local join_command="$4"
  local join_command_b64

  is_valid_worker_join_command "$join_command" || die "invalid Kubernetes worker join command for ${name}"
  join_command_b64="$(base64_one_line "$join_command")"
  if kubernetes_worker_active "$host"; then
    info "ok: Kubernetes worker already joined on ${name}"
    return
  fi

  prepare_kubernetes_node "$host" "$name"
  reboot_node_if_required "$host" "$name"
  if kubernetes_worker_active "$host"; then
    info "ok: Kubernetes worker already joined on ${name}"
    return
  fi

  info "Joining Kubernetes worker: ${name}"
  ssh_node "$host" bash -s -- "$name" "$role" "$join_command_b64" "$(ignore_preflight_arg)" <<'REMOTE'
set -euo pipefail
node_name="$1"
role="$2"
join_command="$(printf '%s' "$3" | base64 -d)"
ignore_preflight="$4"
read -r -a join_args <<<"$join_command"

if [[ "${#join_args[@]}" -lt 2 || "${join_args[0]}" != "kubeadm" || "${join_args[1]}" != "join" ]]; then
  echo "invalid Kubernetes worker join command for ${node_name}" >&2
  exit 1
fi

if [[ -f /etc/kubernetes/kubelet.conf ]]; then
  sudo kubeadm reset -f || true
fi

join_args+=(--node-name "$node_name")
if [[ -n "$ignore_preflight" ]]; then
  join_args+=("$ignore_preflight")
fi
sudo "${join_args[@]}"
REMOTE
}

join_k8s_worker_index() {
  local index="$1"
  local server_target_ip="$2"
  local worker_join_command="$3"

  wait_for_ssh "${NODE_TARGET_IPS[$index]}" "${NODE_NAMES[$index]}"
  if ! kubernetes_worker_active "${NODE_TARGET_IPS[$index]}"; then
    forget_kubernetes_node "$server_target_ip" "${NODE_NAMES[$index]}"
  fi
  install_k8s_worker "${NODE_TARGET_IPS[$index]}" "${NODE_NAMES[$index]}" "${NODE_ROLES[$index]}" "$worker_join_command"
}

label_nodes() {
  local host="$1"
  local index

  for index in "${!NODE_ROLES[@]}"; do
    ssh_node "$host" "sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf label node '${NODE_NAMES[$index]}' hybrid-ai.io/provider=openstack --overwrite >/dev/null"
    case "${NODE_ROLES[$index]}" in
      control-plane)
        ssh_node "$host" "sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf label node '${NODE_NAMES[$index]}' hybrid-ai.io/node-role=control-plane --overwrite >/dev/null"
        ;;
      build-worker)
        ssh_node "$host" "sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf label node '${NODE_NAMES[$index]}' hybrid-ai.io/node-role=build-worker node-role.kubernetes.io/build-worker=true --overwrite >/dev/null"
        ;;
      gpu-worker)
        ssh_node "$host" "sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf label node '${NODE_NAMES[$index]}' hybrid-ai.io/node-role=gpu-worker hybrid-ai.io/accelerator=nvidia node-role.kubernetes.io/gpu-worker=true --overwrite >/dev/null"
        ssh_node "$host" "sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf taint node '${NODE_NAMES[$index]}' nvidia.com/gpu=true:NoSchedule --overwrite >/dev/null"
        ;;
      harbor)
        ssh_node "$host" "sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf label node '${NODE_NAMES[$index]}' hybrid-ai.io/node-role=harbor node-role.kubernetes.io/harbor=true --overwrite >/dev/null"
        ;;
    esac
  done
}

api_server_url() {
  local endpoint="$1"

  if [[ "$endpoint" == http://* || "$endpoint" == https://* ]]; then
    printf '%s\n' "$endpoint"
  elif [[ "$endpoint" == *:* ]]; then
    printf 'https://%s\n' "$endpoint"
  else
    printf 'https://%s:6443\n' "$endpoint"
  fi
}

write_kubeconfig() {
  local host="$1"
  local endpoint="$2"
  local tmp
  local server_url

  mkdir -p "$(dirname "$KUBECONFIG_PATH")"
  tmp="$(mktemp)"
  ssh_node "$host" 'sudo cat /etc/kubernetes/admin.conf' >"$tmp"
  server_url="$(api_server_url "$endpoint")"
  sed -i "s#server: https://.*#server: ${server_url}#" "$tmp"
  mv "$tmp" "$KUBECONFIG_PATH"
  chmod 600 "$KUBECONFIG_PATH"
}

write_handoff() {
  local server_name="$1"
  local endpoint="$2"
  local ssh_target="$3"
  local info_file="${HANDOFF_DIR}/openstack-kubernetes.env"

  mkdir -p "$HANDOFF_DIR"
  {
    printf 'HA_PROVIDER=%q\n' "openstack"
    printf 'KUBECONFIG=%q\n' "$KUBECONFIG_PATH"
    printf 'HA_K8S_API_ENDPOINT=%q\n' "$endpoint"
    printf 'KUBERNETES_API_ENDPOINT=%q\n' "$(api_server_url "$endpoint")"
    printf 'K8S_INITIAL_CONTROL_PLANE=%q\n' "$server_name"
    printf 'HA_OPENSTACK_SSH_USER=%q\n' "$SSH_USER"
    printf 'HA_OPENSTACK_SSH_TARGET_IP=%q\n' "$ssh_target"
    if [[ -n "$SSH_PROXY_CONTAINER" ]]; then
      printf 'HA_OPENSTACK_SSH_PROXY_CONTAINER=%q\n' "$SSH_PROXY_CONTAINER"
    fi
  } >"$info_file"
  chmod 600 "$info_file"
  info "Wrote OpenStack Kubernetes handoff: ${info_file#"${ROOT}"/}"
}

wait_for_kubernetes() {
  local host="$1"

  wait_for_kubernetes_api "$host"
  ssh_node "$host" 'sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf wait --for=condition=Ready nodes --all --timeout=300s'
  ssh_node "$host" 'running_pods="$(sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get pods -n kube-system --field-selector=status.phase=Running -o name 2>/dev/null || true)"; if [[ -n "$running_pods" ]]; then sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf wait --for=condition=Ready -n kube-system --timeout=300s $running_pods; fi'
}

wait_for_kubernetes_api() {
  local host="$1"
  local deadline=$((SECONDS + 420))

  while (( SECONDS < deadline )); do
    if ssh_node "$host" 'sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get --raw=/readyz >/dev/null 2>&1'; then
      break
    fi
    sleep 5
  done

  ssh_node "$host" 'sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get --raw=/readyz >/dev/null'
}

#feature/hybrid# ==============================================================================
#   GitLab Runner 주입 엔진 (수동 성공 수순과 100% 동일하게 일치화 완료)
# ==============================================================================
install_gitlab_runner_automation() {
  local master_host="$1"
  local install_script="${ROOT}/private/gitlab-runner/install.sh"
  local values_file="${ROOT}/private/gitlab-runner/values.yaml"
  local install_script_b64
  local values_file_b64

  info "--------------------------------------------------------"
  info "Fox: GitLab Runner 무인 배포 및 사설 인프라 연동 자동화를 가동합니다."
  info "--------------------------------------------------------"
  local target_gitlab_url="${GITLAB_URL:-https://gitlab.intp.me}"
  local target_gitlab_token="${GITLAB_RUNNER_AUTH_TOKEN:-}"

  info "  Target 사설 GitLab 엔드포인트: ${target_gitlab_url}"

  [[ -f "$install_script" ]] || die "GitLab Runner install script not found: ${install_script}"
  [[ -f "$values_file" ]] || die "GitLab Runner values file not found: ${values_file}"

  install_script_b64="$(base64 -w0 < "$install_script")"
  values_file_b64="$(base64 -w0 < "$values_file")"

  local gitlab_domain
  gitlab_domain="${target_gitlab_url#*://}" # "gitlab.intp.me" 추출
  gitlab_domain="${gitlab_domain%%/*}"      # 포트나 슬래시 제거

  # 마스터 노드 관점에서 gitlab.intp.me의 실제 사설 IP를 동적으로 추출
  local gitlab_ip
  gitlab_ip=$(ssh_node "$master_host" "getent hosts ${gitlab_domain} | awk '{print \$1}'" | tr -d '\r\n' || true)
  
  if [[ -z "${gitlab_ip}" ]]; then
    # getent로 해석 안 될 경우를 대비해 핑 테스트 결과로부터 추출하는 방어적 백업 설계
    gitlab_ip=$(ssh_node "$master_host" "ping -c 1 ${gitlab_domain} | head -n 1 | awk -F'[()]' '{print \$2}'" | tr -d '\r\n' || true)
  fi
  
  info "  Detected GitLab VM Private IP: ${gitlab_ip}"

  # 마스터 노드 원격 진입 후 Runner install 자산을 임시 디렉터리에 주입해 실행
  ssh_node "$master_host" bash -s -- \
    "$target_gitlab_url" \
    "$target_gitlab_token" \
    "$gitlab_ip" \
    "$install_script_b64" \
    "$values_file_b64" <<'REMOTE'
set -euo pipefail
gl_url="$1"
runner_auth_token="$2"
gl_ip="$3"
install_script_b64="$4"
values_file_b64="$5"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

# 1. 마스터 노드 내부에 Helm v3 패키지 관리자 다운로드 및 기동
if ! command -v helm >/dev/null 2>&1; then
  echo "Installing Helm v3 on master node..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# 2. 설치 스크립트와 values 파일을 master에 임시 배치
printf '%s' "$install_script_b64" | base64 -d > "${workdir}/install.sh"
printf '%s' "$values_file_b64" | base64 -d > "${workdir}/values.yaml"
chmod 700 "${workdir}/install.sh"

# 3. 팀 아키텍처 규칙에 따른 모델 빌드 격리 방(Namespace) 선행 생성
sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf create namespace model-build --dry-run=client -o yaml | sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f -

# 4. 사설 인증서 가로채서 K8s Secret으로 자동 구워내기 (수동 성공 수순과 100% 동일하게 일치화)
openssl s_client -showcerts -connect gitlab.intp.me:443 </dev/null 2>/dev/null | openssl x509 -outform PEM > gitlab.intp.me.crt
sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf -n model-build create secret generic gitlab-runner-certs \
  --from-file=gitlab.intp.me.crt=gitlab.intp.me.crt \
  --dry-run=client -o yaml | sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f -
rm -f gitlab.intp.me.crt

# 5. 분리된 install.sh를 kubeconfig 기반으로 실행
echo "Deploying GitLab Runner with dedicated provisioning assets..."
if [[ -n "$runner_auth_token" ]]; then
  export GITLAB_RUNNER_AUTH_TOKEN="$runner_auth_token"
fi
export GITLAB_URL="$gl_url"
export GITLAB_RUNNER_HOST_ALIAS_IP="${gl_ip:-100.110.101.77}"
export GITLAB_RUNNER_NAMESPACE="model-build"
export GITLAB_RUNNER_RELEASE="gitlab-runner"
export GITLAB_RUNNER_CHART_VERSION="0.89.1"
export GITLAB_RUNNER_CERT_SECRET_NAME="gitlab-runner-certs"
export HARBOR_PULL_SECRET_NAME="harbor-kaniko-push"
export KUBECTL_SUDO="true"
export KUBECTL_KUBECONFIG="/etc/kubernetes/admin.conf"
"${workdir}/install.sh"

echo "🎉 GitLab Runner 제한망 배포 신호 탄막 전송 완료!"
REMOTE
}
main() {
  local first_index
  local server_private_ip
  local server_target_ip
  local server_name
  local api_endpoint
  local control_plane_join_command
  local worker_join_command
  local index
  local needs_control_plane_join=0
  local needs_worker_join=0

  if [[ -z "$OPENSTACK_TF_OUTPUT_JSON" ]]; then
    require_tool terraform
  fi
  require_tool python3
  require_tool ssh
  [[ -f "$SSH_KEY" ]] || die "SSH private key not found: ${SSH_KEY}"

  load_inventory
  print_inventory

  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "Dry run only; no SSH changes applied."
    return
  fi

  first_index="$(first_control_plane_index)"
  server_private_ip="${NODE_PRIVATE_IPS[$first_index]}"
  server_target_ip="${NODE_TARGET_IPS[$first_index]}"
  server_name="${NODE_NAMES[$first_index]}"
  [[ -n "$server_private_ip" ]] || server_private_ip="$server_target_ip"
  api_endpoint="${K8S_API_ENDPOINT:-$server_target_ip}"

  wait_for_ssh "$server_target_ip" "$server_name"
  install_k8s_control_plane_init "$server_target_ip" "$server_name" "$server_private_ip" "$api_endpoint"
  wait_for_kubernetes_api "$server_target_ip"

  for index in "${!NODE_ROLES[@]}"; do
    [[ "$index" != "$first_index" ]] || continue
    case "${NODE_ROLES[$index]}" in
      control-plane)
        needs_control_plane_join=1
        ;;
      build-worker|gpu-worker|harbor)
        needs_worker_join=1
        ;;
    esac
  done

  if [[ "$needs_control_plane_join" -eq 1 ]]; then
    control_plane_join_command="$(create_control_plane_join_command "$server_target_ip")"
  fi
  if [[ "$needs_worker_join" -eq 1 ]]; then
    worker_join_command="$(create_worker_join_command "$server_target_ip")"
  fi

  for index in "${!NODE_ROLES[@]}"; do
    [[ "$index" != "$first_index" ]] || continue
    [[ "${NODE_ROLES[$index]}" == "control-plane" ]] || continue
    wait_for_ssh "${NODE_TARGET_IPS[$index]}" "${NODE_NAMES[$index]}"
    if ! kubernetes_server_ready "${NODE_TARGET_IPS[$index]}"; then
      forget_kubernetes_node "$server_target_ip" "${NODE_NAMES[$index]}"
    fi
    install_k8s_control_plane_join "${NODE_TARGET_IPS[$index]}" "${NODE_NAMES[$index]}" "${NODE_PRIVATE_IPS[$index]:-${NODE_TARGET_IPS[$index]}}" "$control_plane_join_command"
  done

  local worker_pids=()
  local worker_pid
  local worker_rc=0
  for index in "${!NODE_ROLES[@]}"; do
    [[ "$index" != "$first_index" ]] || continue
    case "${NODE_ROLES[$index]}" in
      build-worker|gpu-worker|harbor)
        ( join_k8s_worker_index "$index" "$server_target_ip" "$worker_join_command" ) &
        worker_pids+=("$!")
        ;;
    esac
  done
  for worker_pid in "${worker_pids[@]}"; do
    wait "$worker_pid" || worker_rc=1
  done
  [[ "$worker_rc" -eq 0 ]] || die "one or more Kubernetes worker joins failed"

  wait_for_kubernetes "$server_target_ip"
  label_nodes "$server_target_ip"
  write_kubeconfig "$server_target_ip" "$api_endpoint"
  write_handoff "$server_name" "$api_endpoint" "$server_target_ip"
  info "ok: OpenStack Kubernetes bootstrap complete"
}

main "$@"
