#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

HA_OPENSTACK_IMAGE_CACHE_ENABLED="${HA_OPENSTACK_IMAGE_CACHE_ENABLED:-true}"
HA_OPENSTACK_IMAGE_CACHE_DIR="${HA_OPENSTACK_IMAGE_CACHE_DIR:-${ROOT}/.ha/openstack/image-cache}"
HA_OPENSTACK_IMAGE_CACHE_ENV="${HA_OPENSTACK_IMAGE_CACHE_ENV:-${HA_OPENSTACK_IMAGE_CACHE_DIR}/images.env}"
HA_OPENSTACK_IMAGE_CACHE_PREFIX="${HA_OPENSTACK_IMAGE_CACHE_PREFIX:-hybrid-ai-cache}"
HA_OPENSTACK_IMAGE_CACHE_DIRECT_MOUNT="${HA_OPENSTACK_IMAGE_CACHE_DIRECT_MOUNT:-true}"
HA_OPENSTACK_IMAGE_CACHE_LXD_DEVICE="${HA_OPENSTACK_IMAGE_CACHE_LXD_DEVICE:-hybrid-ai-image-cache}"
HA_OPENSTACK_IMAGE_CACHE_CONTAINER_DIR="${HA_OPENSTACK_IMAGE_CACHE_CONTAINER_DIR:-/mnt/hybrid-ai-image-cache}"
HA_OPENSTACK_IMAGE_CACHE_UUID_NAMESPACE="${HA_OPENSTACK_IMAGE_CACHE_UUID_NAMESPACE:-37c4d89e-b36c-5d9a-b96e-0a957ab39fd2}"
HA_OPENSTACK_IMAGE_CACHE_FLAVOR="${HA_OPENSTACK_IMAGE_CACHE_FLAVOR:-ha.m1.large}"
HA_OPENSTACK_IMAGE_CACHE_GITLAB_FLAVOR="${HA_OPENSTACK_IMAGE_CACHE_GITLAB_FLAVOR:-ha.m1.gitlab}"
HA_OPENSTACK_IMAGE_CACHE_HARBOR_FLAVOR="${HA_OPENSTACK_IMAGE_CACHE_HARBOR_FLAVOR:-ha.m1.harbor}"
HA_OPENSTACK_IMAGE_CACHE_NETWORK="${HA_OPENSTACK_IMAGE_CACHE_NETWORK:-private}"
HA_OPENSTACK_IMAGE_CACHE_FLOATING_POOL="${HA_OPENSTACK_IMAGE_CACHE_FLOATING_POOL:-public}"
HA_OPENSTACK_IMAGE_CACHE_KEYPAIR="${HA_OPENSTACK_IMAGE_CACHE_KEYPAIR:-hybrid-ai-image-cache-builder}"
HA_OPENSTACK_IMAGE_CACHE_SECURITY_GROUP="${HA_OPENSTACK_IMAGE_CACHE_SECURITY_GROUP:-}"
HA_OPENSTACK_IMAGE_CACHE_SECURITY_GROUP_NAME="${HA_OPENSTACK_IMAGE_CACHE_SECURITY_GROUP_NAME:-hybrid-ai-image-cache-sg}"
HA_OPENSTACK_IMAGE_CACHE_SSH_USER="${HA_OPENSTACK_IMAGE_CACHE_SSH_USER:-ubuntu}"
HA_OPENSTACK_IMAGE_CACHE_DNS_SERVERS="${HA_OPENSTACK_IMAGE_CACHE_DNS_SERVERS:-1.1.1.1 8.8.8.8}"
HA_OPENSTACK_GLANCE_UPLOAD_TIMEOUT="${HA_OPENSTACK_GLANCE_UPLOAD_TIMEOUT:-3600}"
HA_OPENSTACK_GLANCE_IMAGE_LIMIT_MB="${HA_OPENSTACK_GLANCE_IMAGE_LIMIT_MB:-200000}"
HA_OPENSTACK_GLANCE_IMAGE_COUNT_LIMIT="${HA_OPENSTACK_GLANCE_IMAGE_COUNT_LIMIT:-1000}"
HA_OPENSTACK_IMAGE_CACHE_WAIT_SECONDS="${HA_OPENSTACK_IMAGE_CACHE_WAIT_SECONDS:-5400}"
HA_OPENSTACK_IMAGE_CACHE_BOOT_WAIT_SECONDS="${HA_OPENSTACK_IMAGE_CACHE_BOOT_WAIT_SECONDS:-900}"
HA_OPENSTACK_IMAGE_CACHE_DRIVER_PACKAGE="${HA_OPENSTACK_IMAGE_CACHE_DRIVER_PACKAGE:-${TF_VAR_gpu_driver_package:-nvidia-driver-595-open}}"
HA_OPENSTACK_IMAGE_CACHE_CUDA_TOOLKIT_PACKAGE="${HA_OPENSTACK_IMAGE_CACHE_CUDA_TOOLKIT_PACKAGE:-${TF_VAR_gpu_cuda_toolkit_package:-cuda-toolkit-12-8}}"
HA_OPENSTACK_IMAGE_CACHE_CUDNN_PACKAGE="${HA_OPENSTACK_IMAGE_CACHE_CUDNN_PACKAGE:-${TF_VAR_gpu_cudnn_package:-cudnn9-cuda-12}}"
HA_OPENSTACK_IMAGE_CACHE_GITLAB_IMAGE="${HA_OPENSTACK_IMAGE_CACHE_GITLAB_IMAGE:-${TF_VAR_gitlab_container_image:-gitlab/gitlab-ce:18.11.4-ce.0}}"
HA_OPENSTACK_IMAGE_CACHE_CONTROL_PLANE_NFS="${HA_OPENSTACK_IMAGE_CACHE_CONTROL_PLANE_NFS:-true}"
HA_OPENSTACK_IMAGE_CACHE_TRAINING_PYTORCH_INDEX="${HA_OPENSTACK_IMAGE_CACHE_TRAINING_PYTORCH_INDEX:-${TF_VAR_gpu_training_pytorch_cuda_index_url:-https://download.pytorch.org/whl/cu128}}"
# Air-gap override: point these at the Bastion mirror so the GPU worker never
# reaches NVIDIA over the public internet. Defaults keep the upstream origin so
# non-air-gap dev installs are unchanged.
HA_OPENSTACK_IMAGE_CACHE_NVIDIA_TOOLKIT_BASE_URL="${HA_OPENSTACK_IMAGE_CACHE_NVIDIA_TOOLKIT_BASE_URL:-${TF_VAR_gpu_nvidia_toolkit_base_url:-https://nvidia.github.io/libnvidia-container}}"
HA_OPENSTACK_IMAGE_CACHE_CUDA_REPO_BASE_URL="${HA_OPENSTACK_IMAGE_CACHE_CUDA_REPO_BASE_URL:-${TF_VAR_gpu_cuda_repo_base_url:-https://developer.download.nvidia.com/compute/cuda/repos}}"
HA_OPENSTACK_IMAGE_CACHE_TRAINING_PACKAGES_JSON="${HA_OPENSTACK_IMAGE_CACHE_TRAINING_PACKAGES_JSON:-${TF_VAR_gpu_training_python_packages:-}}"
DEFAULT_OPENSTACK_IMAGE_CACHE_TRAINING_PACKAGES="torch==2.7.0+cu128
torchvision==0.22.0+cu128
torchaudio==2.7.0+cu128
numpy==1.26.4
pandas==2.2.2
scipy==1.11.4
scikit-learn==1.4.2
matplotlib==3.8.4
seaborn==0.13.2
notebook==7.2.2
ipykernel==6.29.5
minio==7.2.8"
HA_OPENSTACK_IMAGE_CACHE_TRAINING_PACKAGES="${HA_OPENSTACK_IMAGE_CACHE_TRAINING_PACKAGES:-}"

SSH_KEY="${HA_OPENSTACK_IMAGE_CACHE_SSH_KEY:-${HA_OPENSTACK_SSH_KEY:-${HA_OPENSTACK_IMAGE_CACHE_DIR}/cache-builder-ed25519}}"

COMMON_PACKAGES=(
  apt-transport-https
  bash-completion
  build-essential
  ca-certificates
  conntrack
  curl
  ethtool
  fio
  git
  gnupg
  hwloc
  iproute2
  ipset
  iptables
  jq
  kmod
  linux-tools-generic
  lshw
  lsb-release
  lvm2
  make
  multipath-tools
  net-tools
  nfs-common
  nftables
  numactl
  nvme-cli
  openssh-server
  open-iscsi
  pciutils
  python3
  python3-dev
  python3-pip
  python3-venv
  qemu-guest-agent
  socat
  software-properties-common
  sysstat
  tar
  unzip
  xfsprogs
  xz-utils
  zip
)

log() {
  printf '[image-cache] %s\n' "$*"
}

normalize_training_packages() {
  if [[ -n "${HA_OPENSTACK_IMAGE_CACHE_TRAINING_PACKAGES:-}" ]]; then
    printf '%s\n' "$HA_OPENSTACK_IMAGE_CACHE_TRAINING_PACKAGES"
    return 0
  fi

  if [[ -n "${HA_OPENSTACK_IMAGE_CACHE_TRAINING_PACKAGES_JSON:-}" ]]; then
    python3 - "$HA_OPENSTACK_IMAGE_CACHE_TRAINING_PACKAGES_JSON" <<'PY'
import json
import sys

raw = sys.argv[1]
try:
    value = json.loads(raw)
except json.JSONDecodeError as exc:
    raise SystemExit(f"GPU training package list must be JSON: {exc}") from exc

if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
    raise SystemExit("GPU training package list must be a JSON string array")

for item in value:
    print(item)
PY
    return 0
  fi

  printf '%s\n' "$DEFAULT_OPENSTACK_IMAGE_CACHE_TRAINING_PACKAGES"
}

HA_OPENSTACK_IMAGE_CACHE_TRAINING_PACKAGES="$(normalize_training_packages)"

os() {
  lxc exec ha-openstack -- sudo -u stack -H bash -lc \
    'cd /opt/stack/devstack && set +u && source openrc admin admin >/dev/null && set -u && "$@"' \
    _ "$@"
}

ensure_cache_dirs() {
  mkdir -p "$HA_OPENSTACK_IMAGE_CACHE_DIR" "$(dirname "$HA_OPENSTACK_IMAGE_CACHE_ENV")"
  : >"$HA_OPENSTACK_IMAGE_CACHE_ENV"
}

ensure_image_cache_mount() {
  [[ "$HA_OPENSTACK_IMAGE_CACHE_DIRECT_MOUNT" == "true" ]] || return 1

  local host_dir source path
  mkdir -p "$HA_OPENSTACK_IMAGE_CACHE_DIR"
  host_dir="$(cd "$HA_OPENSTACK_IMAGE_CACHE_DIR" && pwd -P)"
  source="$(lxc config device get ha-openstack "$HA_OPENSTACK_IMAGE_CACHE_LXD_DEVICE" source 2>/dev/null || true)"
  path="$(lxc config device get ha-openstack "$HA_OPENSTACK_IMAGE_CACHE_LXD_DEVICE" path 2>/dev/null || true)"

  if [[ -n "$source" || -n "$path" ]]; then
    if [[ "$source" != "$host_dir" || "$path" != "$HA_OPENSTACK_IMAGE_CACHE_CONTAINER_DIR" ]]; then
      lxc config device remove ha-openstack "$HA_OPENSTACK_IMAGE_CACHE_LXD_DEVICE" >/dev/null
      lxc config device add ha-openstack "$HA_OPENSTACK_IMAGE_CACHE_LXD_DEVICE" disk \
        source="$host_dir" \
        path="$HA_OPENSTACK_IMAGE_CACHE_CONTAINER_DIR" >/dev/null
    fi
  else
    lxc config device add ha-openstack "$HA_OPENSTACK_IMAGE_CACHE_LXD_DEVICE" disk \
      source="$host_dir" \
      path="$HA_OPENSTACK_IMAGE_CACHE_CONTAINER_DIR" >/dev/null
  fi

  lxc exec ha-openstack -- test -d "$HA_OPENSTACK_IMAGE_CACHE_CONTAINER_DIR"
}

ensure_ssh_key() {
  mkdir -p "$(dirname "$SSH_KEY")"
  if [[ ! -f "$SSH_KEY" ]]; then
    ssh-keygen -t ed25519 -N '' -f "$SSH_KEY" >/dev/null
  fi
  chmod 600 "$SSH_KEY"
}

ensure_devstack_egress() {
  local public_cidr public_gateway prefix public_gateway_cidr dns_args=() dns_server

  public_cidr="$(os openstack subnet show public-subnet -f value -c cidr 2>/dev/null || true)"
  public_gateway="$(os openstack subnet show public-subnet -f value -c gateway_ip 2>/dev/null || true)"
  if os openstack subnet show private-subnet >/dev/null 2>&1; then
    for dns_server in $HA_OPENSTACK_IMAGE_CACHE_DNS_SERVERS; do
      dns_args+=(--dns-nameserver "$dns_server")
    done
    if (( ${#dns_args[@]} > 0 )); then
      os openstack subnet set --no-dns-nameservers "${dns_args[@]}" private-subnet >/dev/null
    fi
  fi
  [[ -n "$public_cidr" && -n "$public_gateway" && "$public_gateway" != "None" ]] || return 0
  prefix="${public_cidr#*/}"
  public_gateway_cidr="${public_gateway}/${prefix}"

  lxc exec ha-openstack -- bash -s -- "$public_cidr" "$public_gateway_cidr" <<'REMOTE'
set -euo pipefail
public_cidr="$1"
public_gateway_cidr="$2"
ip link set br-ex up
if ! ip -4 addr show br-ex | grep -Fqw "$public_gateway_cidr"; then
  ip addr add "$public_gateway_cidr" dev br-ex
fi
sysctl -w net.ipv4.ip_forward=1 >/dev/null
if ! iptables -t nat -C POSTROUTING -s "$public_cidr" ! -d "$public_cidr" -j MASQUERADE >/dev/null 2>&1; then
  iptables -t nat -A POSTROUTING -s "$public_cidr" ! -d "$public_cidr" -j MASQUERADE
fi
REMOTE
}

ensure_base_image() {
  local image_name="$1"
  local image_url=""
  local image_file=""
  local image_id=""

  [[ -n "$image_name" ]] || return 0
  if os openstack image show "$image_name" >/dev/null 2>&1; then
    return 0
  fi

  case "$image_name" in
    ubuntu-22.04)
      image_url="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
      image_file="/opt/stack/images/jammy-server-cloudimg-amd64.img"
      ;;
    ubuntu-24.04)
      image_url="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
      image_file="/opt/stack/images/noble-server-cloudimg-amd64.img"
      ;;
    *)
      printf 'unknown base image and no Glance image exists: %s\n' "$image_name" >&2
      return 1
      ;;
  esac

  image_id="$(base_image_id "$image_name" "$image_url")"
  remove_stale_glance_store_file "$image_id"

  lxc exec ha-openstack -- sudo -u stack -H bash -s -- "$image_name" "$image_url" "$image_file" "$image_id" <<'REMOTE'
set -euo pipefail
image_name="$1"
image_url="$2"
image_file="$3"
image_id="$4"
cd /opt/stack/devstack
set +u
source openrc admin admin >/dev/null
set -u
mkdir -p /opt/stack/images
if [[ ! -f "$image_file" ]]; then
  curl -fL --retry 3 --retry-delay 5 -o "$image_file" "$image_url"
fi
openstack image create "$image_name" --id "$image_id" --disk-format qcow2 --container-format bare --public --file "$image_file" >/dev/null
REMOTE
}

ensure_builder_keypair() {
  local public_key
  public_key="$(cat "${SSH_KEY}.pub")"
  lxc exec ha-openstack -- sudo -u stack -H bash -s -- "$HA_OPENSTACK_IMAGE_CACHE_KEYPAIR" "$public_key" <<'REMOTE'
set -euo pipefail
keypair="$1"
public_key="$2"
cd /opt/stack/devstack
set +u
source openrc admin admin >/dev/null
set -u
tmp_key="$(mktemp)"
printf '%s\n' "$public_key" >"$tmp_key"
if openstack keypair show "$keypair" >/dev/null 2>&1; then
  openstack keypair delete "$keypair" >/dev/null
fi
openstack keypair create --public-key "$tmp_key" "$keypair" >/dev/null
rm -f "$tmp_key"
REMOTE
}

builder_security_group_id() {
  if [[ -n "$HA_OPENSTACK_IMAGE_CACHE_SECURITY_GROUP" ]]; then
    printf '%s\n' "$HA_OPENSTACK_IMAGE_CACHE_SECURITY_GROUP"
    return
  fi
  local sg_name="$HA_OPENSTACK_IMAGE_CACHE_SECURITY_GROUP_NAME"
  os openstack security group list -f value -c ID -c Name \
    | awk -v n="$sg_name" '$2 == n {print $1; exit}'
}

ensure_builder_security_group() {
  local security_group_id
  local sg_name="$HA_OPENSTACK_IMAGE_CACHE_SECURITY_GROUP_NAME"

  security_group_id="$(builder_security_group_id)"
  if [[ -z "$security_group_id" ]]; then
    log "creating dedicated image cache security group: ${sg_name}"
    security_group_id="$(os openstack security group create "$sg_name" \
      --description "Hybrid AI image cache builder" -f value -c id)"
    if [[ -z "$security_group_id" ]]; then
      echo "failed to create image cache security group: ${sg_name}" >&2
      return 1
    fi
  fi

  os openstack security group rule create --proto tcp --dst-port 22 --ingress "$security_group_id" >/dev/null 2>&1 || true
  os openstack security group rule create --proto icmp --ingress "$security_group_id" >/dev/null 2>&1 || true

  export HA_OPENSTACK_IMAGE_CACHE_SECURITY_GROUP="$security_group_id"
}

ensure_glance_registered_limit() {
  local resource_name="$1"
  local default_limit="$2"
  local region="${OPENSTACK_REGION:-${OS_REGION_NAME:-RegionOne}}"
  local existing=""
  local id=""
  local current_limit=""

  existing="$(os openstack registered limit list -f value -c ID -c "Resource Name" -c "Default Limit" \
    | awk -v resource="$resource_name" '$2 == resource {print $1 " " $3; exit}')"
  id="${existing%% *}"
  current_limit="${existing#* }"

  if [[ -n "$id" && "$id" != "$current_limit" ]]; then
    if [[ "$current_limit" != "$default_limit" ]]; then
      log "setting Glance registered limit ${resource_name}=${default_limit}"
      os openstack registered limit set --default-limit "$default_limit" "$id" >/dev/null
    fi
    return 0
  fi

  log "creating Glance registered limit ${resource_name}=${default_limit}"
  os openstack registered limit create \
    --service glance \
    --region "$region" \
    --default-limit "$default_limit" \
    "$resource_name" >/dev/null
}

ensure_glance_registered_limits() {
  ensure_glance_registered_limit image_size_total "$HA_OPENSTACK_GLANCE_IMAGE_LIMIT_MB"
  ensure_glance_registered_limit image_stage_total "$HA_OPENSTACK_GLANCE_IMAGE_LIMIT_MB"
  ensure_glance_registered_limit image_count_total "$HA_OPENSTACK_GLANCE_IMAGE_COUNT_LIMIT"
  ensure_glance_registered_limit image_count_uploading "$HA_OPENSTACK_GLANCE_IMAGE_COUNT_LIMIT"
}

ensure_glance_upload_timeout() {
  lxc exec ha-openstack -- bash -s -- "$HA_OPENSTACK_GLANCE_UPLOAD_TIMEOUT" <<'REMOTE'
set -euo pipefail
timeout="$1"
uwsgi_conf="/etc/glance/glance-uwsgi.ini"
if [[ -f "$uwsgi_conf" ]]; then
  python3 - "$uwsgi_conf" "$timeout" <<'PY'
import configparser
import sys

path, timeout = sys.argv[1], sys.argv[2]
parser = configparser.ConfigParser()
parser.optionxform = str
parser.read(path)
if not parser.has_section("uwsgi"):
    parser.add_section("uwsgi")
parser.set("uwsgi", "socket-timeout", timeout)
with open(path, "w", encoding="utf-8") as handle:
    parser.write(handle, space_around_delimiters=True)
PY
fi
if [[ -d /etc/apache2/conf-available ]]; then
  cat >/etc/apache2/conf-available/hybrid-ai-glance-upload-timeout.conf <<EOF
Timeout ${timeout}
ProxyTimeout ${timeout}
RequestReadTimeout body=60,minrate=500
EOF
  a2enconf hybrid-ai-glance-upload-timeout >/dev/null 2>&1 || true
fi
systemctl restart devstack@g-api.service >/dev/null 2>&1 || true
systemctl reload apache2 >/dev/null 2>&1 || systemctl restart apache2 >/dev/null 2>&1 || true
REMOTE
}

role_env_name() {
  case "$1" in
    control-plane) printf 'TF_VAR_control_plane_image_name' ;;
    build-worker) printf 'TF_VAR_build_worker_image_name' ;;
    gpu-worker) printf 'TF_VAR_gpu_worker_image_name' ;;
    gitlab) printf 'TF_VAR_gitlab_image_name' ;;
    harbor) printf 'TF_VAR_harbor_image_name' ;;
    *) return 1 ;;
  esac
}

role_flavor() {
  case "$1" in
    gitlab) printf '%s' "$HA_OPENSTACK_IMAGE_CACHE_GITLAB_FLAVOR" ;;
    harbor) printf '%s' "$HA_OPENSTACK_IMAGE_CACHE_HARBOR_FLAVOR" ;;
    *) printf '%s' "$HA_OPENSTACK_IMAGE_CACHE_FLAVOR" ;;
  esac
}

role_manifest() {
  local role="$1"
  local base_image="$2"
  {
    printf 'cache_schema=5\n'
    printf 'role=%s\n' "$role"
    printf 'base_image=%s\n' "$base_image"
    printf 'common_packages=%s\n' "${COMMON_PACKAGES[*]}"
    case "$role" in
      control-plane)
        if [[ "$HA_OPENSTACK_IMAGE_CACHE_CONTROL_PLANE_NFS" == "true" ]]; then
          printf 'control_plane_packages=nfs-kernel-server\n'
        fi
        ;;
      gitlab)
        printf 'gitlab_image=%s\n' "$HA_OPENSTACK_IMAGE_CACHE_GITLAB_IMAGE"
        printf 'gitlab_packages=ca-certificates curl docker.io openssh-server python3 tzdata\n'
        ;;
      harbor)
        printf 'harbor_packages=ca-certificates curl docker.io openssh-server openssl python3 tzdata docker-compose\n'
        printf 'harbor_data_dir=/data/harbor\n'
        printf 'harbor_installer_dir=/opt/harbor\n'
        ;;
      gpu-worker)
        printf 'gpu_driver_package=%s\n' "$HA_OPENSTACK_IMAGE_CACHE_DRIVER_PACKAGE"
        printf 'nvidia_container_toolkit=stable\n'
        printf 'nvidia_toolkit_base_url=%s\n' "$HA_OPENSTACK_IMAGE_CACHE_NVIDIA_TOOLKIT_BASE_URL"
        printf 'cuda_repo_base_url=%s\n' "$HA_OPENSTACK_IMAGE_CACHE_CUDA_REPO_BASE_URL"
        printf 'cuda_toolkit_package=%s\n' "$HA_OPENSTACK_IMAGE_CACHE_CUDA_TOOLKIT_PACKAGE"
        printf 'cudnn_package=%s\n' "$HA_OPENSTACK_IMAGE_CACHE_CUDNN_PACKAGE"
        printf 'pytorch_index=%s\n' "$HA_OPENSTACK_IMAGE_CACHE_TRAINING_PYTORCH_INDEX"
        printf 'training_packages=%s\n' "$HA_OPENSTACK_IMAGE_CACHE_TRAINING_PACKAGES"
        ;;
    esac
  }
}

manifest_sha256() {
  sha256sum | awk '{print $1}'
}

deterministic_uuid() {
  local seed="$1"
  python3 - "$HA_OPENSTACK_IMAGE_CACHE_UUID_NAMESPACE" "$seed" <<'PY'
import sys
import uuid

namespace = uuid.UUID(sys.argv[1])
seed = sys.argv[2]
print(uuid.uuid5(namespace, seed))
PY
}

cache_image_name() {
  local role="$1"
  local base_image="$2"
  local hash
  hash="$(role_manifest "$role" "$base_image" | manifest_sha256 | awk '{print substr($1, 1, 16)}')"
  printf '%s-%s-%s' "$HA_OPENSTACK_IMAGE_CACHE_PREFIX" "$role" "$hash"
}

cache_image_id() {
  local image_name="$1"
  local manifest="$2"
  local manifest_hash

  manifest_hash="$(printf '%s\n' "$manifest" | manifest_sha256)"
  deterministic_uuid "cache:${image_name}:${manifest_hash}"
}

base_image_id() {
  local image_name="$1"
  local image_url="$2"

  deterministic_uuid "base:${image_name}:${image_url}"
}

remove_stale_glance_store_file() {
  local image_id="$1"

  [[ -n "$image_id" ]] || return 0
  lxc exec ha-openstack -- bash -s -- "$image_id" <<'REMOTE'
set -euo pipefail
image_id="$1"
store_dir="$(awk -F= '/^[[:space:]]*filesystem_store_datadir[[:space:]]*=/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}' /etc/glance/glance-api.conf 2>/dev/null || true)"
store_dir="${store_dir:-/opt/stack/data/glance/images}"
rm -f "${store_dir%/}/${image_id}"
REMOTE
}

manifest_sidecar_file() {
  local cache_file="$1"
  printf '%s.manifest' "$cache_file"
}

write_local_manifest() {
  local cache_file="$1"
  local manifest="$2"
  local sidecar

  sidecar="$(manifest_sidecar_file "$cache_file")"
  printf '%s\n' "$manifest" >"$sidecar"
}

local_cache_manifest_matches() {
  local cache_file="$1"
  local manifest="$2"
  local sidecar

  sidecar="$(manifest_sidecar_file "$cache_file")"
  [[ -s "$sidecar" ]] || return 2
  cmp -s "$sidecar" <(printf '%s\n' "$manifest")
}

set_glance_manifest_properties() {
  local image_name="$1"
  local role="$2"
  local base_image="$3"
  local manifest="$4"
  local manifest_hash

  manifest_hash="$(printf '%s\n' "$manifest" | manifest_sha256)"
  os openstack image set \
    --property hybrid_ai_cache=true \
    --property hybrid_ai_cache_role="$role" \
    --property hybrid_ai_cache_base="$base_image" \
    --property hybrid_ai_cache_schema=5 \
    --property hybrid_ai_cache_manifest_sha256="$manifest_hash" \
    "$image_name"
}

write_env_assignment() {
  local name="$1"
  local value="$2"
  printf '%s=%q\n' "$name" "$value" >>"$HA_OPENSTACK_IMAGE_CACHE_ENV"
}

download_glance_image_to_cache() {
  local image_name="$1"
  local cache_file="$2"
  local manifest="$3"
  local cache_tmp="${cache_file}.tmp"
  local inside_file="/tmp/${image_name}.qcow2"
  local container_tmp="${HA_OPENSTACK_IMAGE_CACHE_CONTAINER_DIR}/$(basename "$cache_tmp")"
  local cache_uid cache_gid

  mkdir -p "$(dirname "$cache_file")"
  rm -f "$cache_tmp"

  if ensure_image_cache_mount; then
    cache_uid="$(stat -c '%u' "$(dirname "$cache_file")")"
    cache_gid="$(stat -c '%g' "$(dirname "$cache_file")")"
    log "saving Glance image directly to local cache mount: ${cache_tmp}"
    lxc exec ha-openstack -- rm -f "$container_tmp" >/dev/null 2>&1 || true
    lxc exec ha-openstack -- bash -s -- "$image_name" "$container_tmp" "$cache_uid" "$cache_gid" <<'REMOTE'
set -Eeuo pipefail
image_name="$1"
output_file="$2"
cache_uid="$3"
cache_gid="$4"

cd /opt/stack/devstack
set +u
source openrc admin admin >/dev/null
set -u
openstack image save --file "$output_file" "$image_name"
chmod 0664 "$output_file"
chown "${cache_uid}:${cache_gid}" "$output_file" 2>/dev/null || true
REMOTE
  else
    lxc exec ha-openstack -- rm -f "$inside_file" >/dev/null 2>&1 || true
    os openstack image save --file "$inside_file" "$image_name"
    lxc file pull "ha-openstack${inside_file}" "$cache_tmp"
    lxc exec ha-openstack -- rm -f "$inside_file" >/dev/null 2>&1 || true
  fi

  mv "$cache_tmp" "$cache_file"
  write_local_manifest "$cache_file" "$manifest"
}

upload_cache_file_to_glance() {
  local image_name="$1"
  local cache_file="$2"
  local manifest="$3"
  local inside_file="/tmp/${image_name}.qcow2"
  local container_file="${HA_OPENSTACK_IMAGE_CACHE_CONTAINER_DIR}/$(basename "$cache_file")"
  local manifest_hash
  local image_id

  manifest_hash="$(printf '%s\n' "$manifest" | manifest_sha256)"
  image_id="$(cache_image_id "$image_name" "$manifest")"
  remove_stale_glance_store_file "$image_id"

  if ensure_image_cache_mount && lxc exec ha-openstack -- sudo -u stack -H test -r "$container_file"; then
    log "uploading local cache via direct cache mount: ${cache_file}"
    os openstack image create "$image_name" \
      --id "$image_id" \
      --disk-format qcow2 \
      --container-format bare \
      --public \
      --property hybrid_ai_cache=true \
      --property hybrid_ai_cache_schema=5 \
      --property hybrid_ai_cache_manifest_sha256="$manifest_hash" \
      --property hybrid_ai_cache_file="$(basename "$cache_file")" \
      --file "$container_file" >/dev/null
  else
    lxc file push "$cache_file" "ha-openstack${inside_file}"
    os openstack image create "$image_name" \
      --id "$image_id" \
      --disk-format qcow2 \
      --container-format bare \
      --public \
      --property hybrid_ai_cache=true \
      --property hybrid_ai_cache_schema=5 \
      --property hybrid_ai_cache_manifest_sha256="$manifest_hash" \
      --property hybrid_ai_cache_file="$(basename "$cache_file")" \
      --file "$inside_file" >/dev/null
    lxc exec ha-openstack -- rm -f "$inside_file" >/dev/null 2>&1 || true
  fi
  write_local_manifest "$cache_file" "$manifest"
}

wait_server_status() {
  local server="$1"
  local expected="$2"
  local deadline=$((SECONDS + HA_OPENSTACK_IMAGE_CACHE_WAIT_SECONDS))
  local status=""

  while (( SECONDS < deadline )); do
    status="$(os openstack server show "$server" -f value -c status 2>/dev/null || true)"
    if [[ "$status" == "$expected" ]]; then
      return 0
    fi
    if [[ "$status" == "ERROR" ]]; then
      os openstack server show "$server" || true
      return 1
    fi
    sleep 10
  done
  printf 'timed out waiting for server %s to reach %s; last status=%s\n' "$server" "$expected" "$status" >&2
  return 1
}

wait_image_active() {
  local image_name="$1"
  local deadline=$((SECONDS + HA_OPENSTACK_IMAGE_CACHE_WAIT_SECONDS))
  local status=""
  local missing_count=0

  while (( SECONDS < deadline )); do
    status="$(os openstack image show "$image_name" -f value -c status 2>/dev/null || true)"
    if [[ "$status" == "active" ]]; then
      return 0
    fi
    if [[ "$status" == "killed" || "$status" == "deleted" ]]; then
      return 1
    fi
    if [[ -z "$status" ]]; then
      missing_count=$((missing_count + 1))
      if (( missing_count >= 3 )); then
        printf 'image %s is missing while waiting for active status\n' "$image_name" >&2
        return 1
      fi
    else
      missing_count=0
    fi
    sleep 10
  done
  printf 'timed out waiting for image %s to become active; last status=%s\n' "$image_name" "$status" >&2
  return 1
}

wait_ssh() {
  local ip="$1"
  local deadline=$((SECONDS + HA_OPENSTACK_IMAGE_CACHE_BOOT_WAIT_SECONDS))

  while (( SECONDS < deadline )); do
    if ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
      -o "ProxyCommand=lxc exec ha-openstack -- nc %h %p" \
      -i "$SSH_KEY" "${HA_OPENSTACK_IMAGE_CACHE_SSH_USER}@${ip}" true 2>/dev/null; then
      return 0
    fi
    sleep 10
  done
  printf 'timed out waiting for image cache builder SSH: %s\n' "$ip" >&2
  return 1
}

cleanup_builder_instance() {
  local server="$1"
  local fip="$2"
  local server_id=""
  local port_id=""
  local discovered_fip=""

  server_id="$(os openstack server show "$server" -f value -c id 2>/dev/null || true)"
  if [[ -z "$fip" && -n "$server_id" ]]; then
    while read -r port_id; do
      [[ -n "$port_id" ]] || continue
      while read -r discovered_fip; do
        [[ -n "$discovered_fip" ]] || continue
        os openstack server remove floating ip "$server" "$discovered_fip" >/dev/null 2>&1 || true
        os openstack floating ip delete "$discovered_fip" >/dev/null 2>&1 || true
      done < <(os openstack floating ip list -f value -c "Floating IP Address" -c Port | awk -v port="$port_id" '$2 == port {print $1}')
    done < <(os openstack port list --server "$server_id" -f value -c ID 2>/dev/null || true)
  fi
  if [[ -n "$fip" ]]; then
    os openstack server remove floating ip "$server" "$fip" >/dev/null 2>&1 || true
    os openstack floating ip delete "$fip" >/dev/null 2>&1 || true
  fi
  os openstack server delete "$server" >/dev/null 2>&1 || true
}

create_image_from_server_disk() {
  local server="$1"
  local image_name="$2"
  local cache_file="${3:-}"
  local manifest="${4:-}"
  local server_id=""
  local disk_path=""
  local tmp_image="/tmp/${image_name}.qcow2"
  local output_image="$tmp_image"
  local cache_tmp=""
  local container_cache_tmp=""
  local cache_uid=""
  local cache_gid=""
  local direct_cache=false
  local image_id=""

  server_id="$(os openstack server show "$server" -f value -c id)"
  disk_path="/opt/stack/data/nova/instances/${server_id}/disk"

  if [[ -n "$cache_file" ]] && ensure_image_cache_mount; then
    mkdir -p "$(dirname "$cache_file")"
    cache_tmp="${cache_file}.tmp"
    container_cache_tmp="${HA_OPENSTACK_IMAGE_CACHE_CONTAINER_DIR}/$(basename "$cache_tmp")"
    cache_uid="$(stat -c '%u' "$(dirname "$cache_file")")"
    cache_gid="$(stat -c '%g' "$(dirname "$cache_file")")"
    output_image="$container_cache_tmp"
    direct_cache=true
    rm -f "$cache_tmp"
    lxc exec ha-openstack -- rm -f "$container_cache_tmp" >/dev/null 2>&1 || true
    log "converting server disk directly to local cache mount: ${cache_tmp}"
  fi

  lxc exec ha-openstack -- bash -s -- "$disk_path" "$output_image" "$cache_uid" "$cache_gid" <<'REMOTE'
set -euo pipefail
disk_path="$1"
output_image="$2"
cache_uid="$3"
cache_gid="$4"
[[ -s "$disk_path" ]] || { printf 'server disk not found: %s\n' "$disk_path" >&2; exit 1; }
rm -f "$output_image"
qemu-img convert -p -O qcow2 "$disk_path" "$output_image"
chmod 0644 "$output_image"
if [[ -n "$cache_uid" && -n "$cache_gid" ]]; then
  chown "${cache_uid}:${cache_gid}" "$output_image" 2>/dev/null || true
fi
REMOTE

  if [[ -n "$manifest" ]]; then
    image_id="$(cache_image_id "$image_name" "$manifest")"
  else
    image_id="$(deterministic_uuid "image:${image_name}")"
  fi
  remove_stale_glance_store_file "$image_id"

  os openstack image create "$image_name" \
    --id "$image_id" \
    --disk-format qcow2 \
    --container-format bare \
    --public \
    --file "$output_image" >/dev/null
  if [[ "$direct_cache" == "true" ]]; then
    mv "$cache_tmp" "$cache_file"
    [[ -z "$manifest" ]] || write_local_manifest "$cache_file" "$manifest"
  else
    lxc exec ha-openstack -- rm -f "$tmp_image" >/dev/null 2>&1 || true
  fi
  wait_image_active "$image_name"
}

remote_build_script() {
  cat <<'REMOTE'
set -Eeuo pipefail

role="$1"
manifest="$2"
gitlab_image="$3"
driver_package="$4"
cuda_toolkit_package="$5"
cudnn_package="$6"
pytorch_index="$7"
training_packages="$8"
dns_servers="$9"
control_plane_nfs="${10}"
nvidia_toolkit_base_url="${11}"
cuda_repo_base_url="${12}"
shift 12
common_packages=("$@")
manifest="$(printf '%s' "$manifest" | base64 -d)"
training_packages="$(printf '%s' "$training_packages" | base64 -d)"
dns_servers="$(printf '%s' "$dns_servers" | base64 -d)"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
export UCF_FORCE_CONFFNEW=1

apt_get() {
  apt-get \
    -o Acquire::ForceIPv4=true \
    -o Acquire::Retries=5 \
    -o Dpkg::Lock::Timeout=900 \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confnew \
    "$@"
}

configure_network_resolution() {
  local host short dns_server

  host="$(hostname)"
  short="$(hostname -s)"
  if ! grep -Eq "(^|[[:space:]])${short}([[:space:]]|$)" /etc/hosts; then
    printf '127.0.1.1 %s %s\n' "$host" "$short" >>/etc/hosts
  fi

  systemctl disable --now systemd-resolved >/dev/null 2>&1 || true
  rm -f /etc/resolv.conf
  : >/etc/resolv.conf
  for dns_server in $dns_servers; do
    printf 'nameserver %s\n' "$dns_server" >>/etc/resolv.conf
  done
  printf 'options timeout:2 attempts:3 rotate\n' >>/etc/resolv.conf
  printf 'Acquire::ForceIPv4 "true";\nAcquire::Retries "5";\n' >/etc/apt/apt.conf.d/99hybrid-ai-network
  mkdir -p /etc/cryptsetup-initramfs
  printf 'CRYPTSETUP=n\n' >/etc/cryptsetup-initramfs/conf-hook
}

install_nvidia_container_toolkit() {
  if dpkg-query -W nvidia-container-toolkit >/dev/null 2>&1; then
    return 0
  fi
  local toolkit_base="${nvidia_toolkit_base_url:-https://nvidia.github.io/libnvidia-container}"
  local toolkit_channel="${nvidia_container_toolkit:-stable}"
  install -d -m 0755 /usr/share/keyrings
  curl -fsSL "${toolkit_base}/gpgkey" \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -s -L "${toolkit_base}/${toolkit_channel}/deb/nvidia-container-toolkit.list" \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt_get update
  apt_get install -y nvidia-container-toolkit
}

install_cuda_packages() {
  local cuda_distro=""
  local cuda_arch=""
  local keyring_deb="/tmp/cuda-keyring_1.1-1_all.deb"
  local packages=()

  [[ -n "$cuda_toolkit_package" || -n "$cudnn_package" ]] || return 0
  # shellcheck source=/etc/os-release disable=SC1091
  . /etc/os-release
  case "${ID:-}:${VERSION_ID:-}" in
    ubuntu:22.04) cuda_distro="ubuntu2204" ;;
    ubuntu:24.04) cuda_distro="ubuntu2404" ;;
    *) echo "unsupported CUDA apt distro: ${ID:-unknown} ${VERSION_ID:-unknown}" >&2; return 0 ;;
  esac
  case "$(dpkg --print-architecture)" in
    amd64) cuda_arch="x86_64" ;;
    arm64) cuda_arch="arm64" ;;
    *) echo "unsupported CUDA apt architecture: $(dpkg --print-architecture)" >&2; return 0 ;;
  esac
  if ! dpkg-query -W cuda-keyring >/dev/null 2>&1; then
    local cuda_base="${cuda_repo_base_url:-https://developer.download.nvidia.com/compute/cuda/repos}"
    curl -fsSL "${cuda_base}/${cuda_distro}/${cuda_arch}/cuda-keyring_1.1-1_all.deb" -o "$keyring_deb"
    dpkg -i "$keyring_deb"
  fi
  apt_get update
  [[ -z "$cuda_toolkit_package" ]] || packages+=("$cuda_toolkit_package")
  [[ -z "$cudnn_package" ]] || packages+=("$cudnn_package")
  if (( ${#packages[@]} > 0 )); then
    apt_get install -y "${packages[@]}"
  fi
}

install_training_packages() {
  local venv_path="/opt/hybrid-ai/training-venv"
  local requirements="/opt/hybrid-ai/training-requirements.txt"

  [[ -n "$training_packages" ]] || return 0
  install -d -m 0755 /opt/hybrid-ai
  printf '%s\n' "$training_packages" >"$requirements"
  python3 -m venv "$venv_path"
  "$venv_path/bin/python" -m pip install --upgrade pip setuptools wheel
  "$venv_path/bin/python" -m pip install --extra-index-url "$pytorch_index" -r "$requirements"
  ln -sfn "$venv_path/bin/python" /usr/local/bin/hybrid-ai-training-python
  ln -sfn "$venv_path/bin/pip" /usr/local/bin/hybrid-ai-training-pip
}

printf 'hybrid-ai image cache build start role=%s\n' "$role"
printf '%s\n' "$manifest" >/etc/hybrid-ai-image-cache.manifest

configure_network_resolution
apt_get update
apt_get install -y "${common_packages[@]}"

case "$role" in
  control-plane)
    if [[ "$control_plane_nfs" == "true" ]]; then
      apt_get install -y nfs-kernel-server
      systemctl enable nfs-server >/dev/null 2>&1 || systemctl enable nfs-kernel-server >/dev/null 2>&1 || true
    fi
    ;;
  gitlab)
    apt_get install -y ca-certificates curl docker.io openssh-server python3 tzdata
    systemctl enable --now docker
    docker pull "$gitlab_image"
    ;;
  harbor)
    apt_get install -y ca-certificates curl docker.io openssh-server openssl python3 tzdata
    if apt-cache show docker-compose-plugin >/dev/null 2>&1; then
      apt_get install -y docker-compose-plugin
    elif apt-cache show docker-compose-v2 >/dev/null 2>&1; then
      apt_get install -y docker-compose-v2
    elif apt-cache show docker-compose >/dev/null 2>&1; then
      apt_get install -y docker-compose
    fi
    systemctl enable --now docker
    install -d -m 0755 /opt/harbor /data/harbor /var/log/harbor
    ;;
  gpu-worker)
    apt_get install -y ubuntu-drivers-common pciutils
    install_nvidia_container_toolkit
    if [[ -n "$driver_package" ]]; then
      driver_suffix="${driver_package#nvidia-driver-}"
      module_package="linux-modules-nvidia-${driver_suffix}-generic"
      apt_get install -y "$driver_package" "$module_package" || apt_get install -y "$driver_package"
    fi
    install_cuda_packages
    install_training_packages
    ;;
esac

apt_get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
cloud-init clean --logs >/dev/null 2>&1 || true
truncate -s 0 /etc/machine-id >/dev/null 2>&1 || true
rm -f /var/lib/dbus/machine-id
sync
printf 'hybrid-ai image cache build complete role=%s\n' "$role"
nohup shutdown -h now >/dev/null 2>&1 &
REMOTE
}

build_cache_image() {
  local role="$1"
  local base_image="$2"
  local image_name="$3"
  local manifest="$4"
  local cache_file="${5:-}"
  local flavor
  local server_name
  local security_group_id
  local fip=""
  local manifest_b64=""
  local training_packages_b64=""
  local dns_servers_b64=""

  flavor="$(role_flavor "$role")"
  server_name="${image_name}-builder"
  manifest_b64="$(printf '%s' "$manifest" | base64 -w0)"
  training_packages_b64="$(printf '%s' "$HA_OPENSTACK_IMAGE_CACHE_TRAINING_PACKAGES" | base64 -w0)"
  dns_servers_b64="$(printf '%s' "$HA_OPENSTACK_IMAGE_CACHE_DNS_SERVERS" | base64 -w0)"
  security_group_id="$(builder_security_group_id)"
  if [[ -z "$security_group_id" ]]; then
    echo "unable to resolve image cache builder security group" >&2
    return 1
  fi

  log "building ${image_name} from ${base_image} using ${flavor}"
  cleanup_builder_instance "$server_name" ""
  for _ in {1..60}; do
    if ! os openstack server show "$server_name" >/dev/null 2>&1; then
      break
    fi
    sleep 5
  done

  if ! {
    os openstack server create \
      --flavor "$flavor" \
      --image "$base_image" \
      --network "$HA_OPENSTACK_IMAGE_CACHE_NETWORK" \
      --key-name "$HA_OPENSTACK_IMAGE_CACHE_KEYPAIR" \
      --security-group "$security_group_id" \
      "$server_name" >/dev/null
    wait_server_status "$server_name" ACTIVE

    fip="$(os openstack floating ip create "$HA_OPENSTACK_IMAGE_CACHE_FLOATING_POOL" -f value -c floating_ip_address)"
    os openstack server add floating ip "$server_name" "$fip"
    wait_ssh "$fip"

    ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
      -o "ProxyCommand=lxc exec ha-openstack -- nc %h %p" \
      -i "$SSH_KEY" "${HA_OPENSTACK_IMAGE_CACHE_SSH_USER}@${fip}" \
      "cloud-init status --wait >/dev/null 2>&1 || true"

    remote_build_script | ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
      -o "ServerAliveInterval=30" -o "ServerAliveCountMax=20" \
      -o "ProxyCommand=lxc exec ha-openstack -- nc %h %p" \
      -i "$SSH_KEY" "${HA_OPENSTACK_IMAGE_CACHE_SSH_USER}@${fip}" \
      sudo bash -s -- \
        "$role" \
        "$manifest_b64" \
        "$HA_OPENSTACK_IMAGE_CACHE_GITLAB_IMAGE" \
        "$HA_OPENSTACK_IMAGE_CACHE_DRIVER_PACKAGE" \
        "$HA_OPENSTACK_IMAGE_CACHE_CUDA_TOOLKIT_PACKAGE" \
        "$HA_OPENSTACK_IMAGE_CACHE_CUDNN_PACKAGE" \
        "$HA_OPENSTACK_IMAGE_CACHE_TRAINING_PYTORCH_INDEX" \
        "$training_packages_b64" \
        "$dns_servers_b64" \
        "$HA_OPENSTACK_IMAGE_CACHE_CONTROL_PLANE_NFS" \
        "$HA_OPENSTACK_IMAGE_CACHE_NVIDIA_TOOLKIT_BASE_URL" \
        "$HA_OPENSTACK_IMAGE_CACHE_CUDA_REPO_BASE_URL" \
        "${COMMON_PACKAGES[@]}"

    wait_server_status "$server_name" SHUTOFF
    create_image_from_server_disk "$server_name" "$image_name" "$cache_file" "$manifest"
    set_glance_manifest_properties "$image_name" "$role" "$base_image" "$manifest"
  }; then
    cleanup_builder_instance "$server_name" "$fip"
    return 1
  fi

  cleanup_builder_instance "$server_name" "$fip"
  fip=""
}

prepare_role() {
  local role="$1"
  local base_image="$2"
  local env_name image_name cache_file manifest

  [[ -n "$base_image" ]] || return 0
  env_name="$(role_env_name "$role")"
  manifest="$(role_manifest "$role" "$base_image")"
  image_name="$(cache_image_name "$role" "$base_image")"
  cache_file="${HA_OPENSTACK_IMAGE_CACHE_DIR}/${image_name}.qcow2"

  ensure_base_image "$base_image"

  if os openstack image show "$image_name" >/dev/null 2>&1; then
    log "Glance cache hit: ${image_name}"
    set_glance_manifest_properties "$image_name" "$role" "$base_image" "$manifest"
    if [[ ! -s "$cache_file" ]]; then
      log "saving Glance image to local cache: ${cache_file}"
      download_glance_image_to_cache "$image_name" "$cache_file" "$manifest"
    elif ! local_cache_manifest_matches "$cache_file" "$manifest"; then
      log "refreshing local cache manifest: $(manifest_sidecar_file "$cache_file")"
      write_local_manifest "$cache_file" "$manifest"
    fi
    write_env_assignment "$env_name" "$image_name"
    return 0
  fi

  if [[ -s "$cache_file" ]]; then
    if local_cache_manifest_matches "$cache_file" "$manifest"; then
      log "local cache hit; uploading to Glance: ${cache_file}"
      upload_cache_file_to_glance "$image_name" "$cache_file" "$manifest"
      set_glance_manifest_properties "$image_name" "$role" "$base_image" "$manifest"
      write_env_assignment "$env_name" "$image_name"
      return 0
    fi
    log "local cache file exists but manifest differs; rebuilding: ${cache_file}"
    rm -f "$cache_file" "$(manifest_sidecar_file "$cache_file")"
  fi

  build_cache_image "$role" "$base_image" "$image_name" "$manifest" "$cache_file"
  if [[ ! -s "$cache_file" ]]; then
    download_glance_image_to_cache "$image_name" "$cache_file" "$manifest"
  elif ! local_cache_manifest_matches "$cache_file" "$manifest"; then
    write_local_manifest "$cache_file" "$manifest"
  fi
  write_env_assignment "$env_name" "$image_name"
}

main() {
  local item role base_image

  ensure_cache_dirs
  if [[ "$HA_OPENSTACK_IMAGE_CACHE_ENABLED" != "true" ]]; then
    for item in "$@"; do
      role="${item%%=*}"
      base_image="${item#*=}"
      write_env_assignment "$(role_env_name "$role")" "$base_image"
    done
    exit 0
  fi

  if ! lxc info ha-openstack >/dev/null 2>&1; then
    printf 'ha-openstack LXC container is required for local image caching\n' >&2
    exit 1
  fi

  ensure_ssh_key
  ensure_devstack_egress
  ensure_glance_registered_limits
  ensure_glance_upload_timeout
  ensure_builder_keypair
  ensure_builder_security_group

  for item in "$@"; do
    role="${item%%=*}"
    base_image="${item#*=}"
    case "$role" in
      control-plane|build-worker|gpu-worker|gitlab|harbor)
        prepare_role "$role" "$base_image"
        ;;
      *)
        printf 'unknown image cache role: %s\n' "$role" >&2
        exit 1
        ;;
    esac
  done
  log "wrote Terraform image overrides: ${HA_OPENSTACK_IMAGE_CACHE_ENV}"
}

main "$@"
