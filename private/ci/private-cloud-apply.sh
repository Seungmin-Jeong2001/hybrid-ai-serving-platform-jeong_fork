#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODE="${HA_PRIVATE_CLOUD_RUN_MODE:-apply}"
VALIDATE_GPU="${HA_PRIVATE_CLOUD_VALIDATE_GPU:-false}"
REQUIRE_BACKEND_CONFIG=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    apply|reinstall)
      MODE="$1"
      shift
      ;;
    --run-mode)
      [[ $# -ge 2 ]] || { printf 'missing value for --run-mode\n' >&2; exit 64; }
      MODE="$2"
      shift 2
      ;;
    --validate-gpu)
      VALIDATE_GPU=true
      shift
      ;;
    --require-backend-config)
      REQUIRE_BACKEND_CONFIG=true
      shift
      ;;
    -h|--help)
      printf 'usage: ha apply [--run-mode apply|reinstall] [--validate-gpu] [--require-backend-config]\n'
      exit 0
      ;;
    *)
      printf 'unknown option: %s\n' "$1" >&2
      exit 64
      ;;
  esac
done

case "$MODE" in
  apply|reinstall) ;;
  *)
    printf 'run mode must be apply or reinstall\n' >&2
    exit 64
    ;;
esac

RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-${MODE}}"
LOG_DIR="${ROOT}/.ha/ci/runs/${RUN_ID}"
TIMINGS="${LOG_DIR}/timings.tsv"
mkdir -p "${LOG_DIR}" "${ROOT}/.ha/openstack" "${ROOT}/.ha/ssh"
PATH="${ROOT}/.ha/bin:${PATH}"
export TF_IN_AUTOMATION="${TF_IN_AUTOMATION:-true}"
export TF_INPUT="${TF_INPUT:-false}"

HA_DEVSTACK_PASSWORD="${HA_DEVSTACK_PASSWORD:-hybrid-ai-devstack}"
PRIVATE_CLOUD_BASE_DOMAIN="${PRIVATE_CLOUD_BASE_DOMAIN:-intp.me}"
OS_PASSWORD_INPUT_PROVIDED=false
[[ -n "${OS_PASSWORD+x}" ]] && OS_PASSWORD_INPUT_PROVIDED=true
OS_USERNAME="${OS_USERNAME:-admin}"
OS_PROJECT_NAME="${OS_PROJECT_NAME:-admin}"
OS_USER_DOMAIN_NAME="${OS_USER_DOMAIN_NAME:-Default}"
OS_PROJECT_DOMAIN_NAME="${OS_PROJECT_DOMAIN_NAME:-Default}"
OS_REGION_NAME="${OS_REGION_NAME:-RegionOne}"
OS_PASSWORD="${OS_PASSWORD:-${HA_DEVSTACK_PASSWORD}}"
HA_OPENSTACK_LOGIN_USERNAME="${HA_OPENSTACK_LOGIN_USERNAME:-${OS_USERNAME}}"
HA_OPENSTACK_LOGIN_PROJECT_NAME="${HA_OPENSTACK_LOGIN_PROJECT_NAME:-${OS_PROJECT_NAME}}"
HA_OPENSTACK_LOGIN_USER_DOMAIN_NAME="${HA_OPENSTACK_LOGIN_USER_DOMAIN_NAME:-${OS_USER_DOMAIN_NAME}}"
HA_OPENSTACK_LOGIN_PROJECT_DOMAIN_NAME="${HA_OPENSTACK_LOGIN_PROJECT_DOMAIN_NAME:-${OS_PROJECT_DOMAIN_NAME}}"
HA_OPENSTACK_LOGIN_PASSWORD="${HA_OPENSTACK_LOGIN_PASSWORD:-${OS_PASSWORD}}"
HA_OPENSTACK_LOGIN_PASSWORD_INPUT_PROVIDED="${HA_OPENSTACK_LOGIN_PASSWORD_INPUT_PROVIDED:-${OS_PASSWORD_INPUT_PROVIDED}}"
TF_VAR_BUILD_WORKER_COUNT_INPUT_PROVIDED=false
TF_VAR_GPU_WORKER_COUNT_INPUT_PROVIDED=false
TF_VAR_GITLAB_COUNT_INPUT_PROVIDED=false
TF_VAR_HARBOR_COUNT_INPUT_PROVIDED=false
[[ -n "${TF_VAR_build_worker_count+x}" ]] && TF_VAR_BUILD_WORKER_COUNT_INPUT_PROVIDED=true
[[ -n "${TF_VAR_gpu_worker_count+x}" ]] && TF_VAR_GPU_WORKER_COUNT_INPUT_PROVIDED=true
[[ -n "${TF_VAR_gitlab_count+x}" ]] && TF_VAR_GITLAB_COUNT_INPUT_PROVIDED=true
[[ -n "${TF_VAR_harbor_count+x}" ]] && TF_VAR_HARBOR_COUNT_INPUT_PROVIDED=true
TF_VAR_control_plane_image_name="${TF_VAR_control_plane_image_name:-ubuntu-22.04}"
TF_VAR_build_worker_image_name="${TF_VAR_build_worker_image_name:-ubuntu-22.04}"
TF_VAR_gpu_worker_image_name="${TF_VAR_gpu_worker_image_name:-ubuntu-22.04}"
TF_VAR_gitlab_image_name="${TF_VAR_gitlab_image_name:-ubuntu-22.04}"
TF_VAR_harbor_image_name="${TF_VAR_harbor_image_name:-ubuntu-22.04}"
TF_VAR_compute_instance_create_timeout="${TF_VAR_compute_instance_create_timeout:-120m}"
TF_VAR_compute_instance_update_timeout="${TF_VAR_compute_instance_update_timeout:-30m}"
TF_VAR_compute_instance_delete_timeout="${TF_VAR_compute_instance_delete_timeout:-60m}"
TF_VAR_build_worker_count="${TF_VAR_build_worker_count:-1}"
TF_VAR_gpu_worker_count="${TF_VAR_gpu_worker_count:-1}"
TF_VAR_gitlab_count="${TF_VAR_gitlab_count:-1}"
TF_VAR_harbor_count="${TF_VAR_harbor_count:-1}"
TF_VAR_gitlab_container_image="${TF_VAR_gitlab_container_image:-gitlab/gitlab-ce:18.11.4-ce.0}"
HA_DEVSTACK_CONTROL_FLAVOR_NAME="${HA_DEVSTACK_CONTROL_FLAVOR_NAME:-ha.m1.large}"
HA_DEVSTACK_CONTROL_FLAVOR_RAM="${HA_DEVSTACK_CONTROL_FLAVOR_RAM:-8192}"
HA_DEVSTACK_CONTROL_FLAVOR_VCPUS="${HA_DEVSTACK_CONTROL_FLAVOR_VCPUS:-4}"
HA_DEVSTACK_CONTROL_FLAVOR_DISK="${HA_DEVSTACK_CONTROL_FLAVOR_DISK:-80}"
HA_DEVSTACK_WORKER_FLAVOR_NAME="${HA_DEVSTACK_WORKER_FLAVOR_NAME:-ha.m1.large}"
HA_DEVSTACK_WORKER_FLAVOR_RAM="${HA_DEVSTACK_WORKER_FLAVOR_RAM:-8192}"
HA_DEVSTACK_WORKER_FLAVOR_VCPUS="${HA_DEVSTACK_WORKER_FLAVOR_VCPUS:-4}"
HA_DEVSTACK_WORKER_FLAVOR_DISK="${HA_DEVSTACK_WORKER_FLAVOR_DISK:-80}"
HA_DEVSTACK_GITLAB_FLAVOR_NAME="${HA_DEVSTACK_GITLAB_FLAVOR_NAME:-ha.m1.gitlab}"
HA_DEVSTACK_GITLAB_FLAVOR_RAM="${HA_DEVSTACK_GITLAB_FLAVOR_RAM:-16384}"
HA_DEVSTACK_GITLAB_FLAVOR_VCPUS="${HA_DEVSTACK_GITLAB_FLAVOR_VCPUS:-4}"
HA_DEVSTACK_GITLAB_FLAVOR_DISK="${HA_DEVSTACK_GITLAB_FLAVOR_DISK:-80}"
HA_DEVSTACK_HARBOR_FLAVOR_NAME="${HA_DEVSTACK_HARBOR_FLAVOR_NAME:-ha.m1.harbor}"
HA_DEVSTACK_HARBOR_FLAVOR_RAM="${HA_DEVSTACK_HARBOR_FLAVOR_RAM:-8192}"
HA_DEVSTACK_HARBOR_FLAVOR_VCPUS="${HA_DEVSTACK_HARBOR_FLAVOR_VCPUS:-4}"
HA_DEVSTACK_HARBOR_FLAVOR_DISK="${HA_DEVSTACK_HARBOR_FLAVOR_DISK:-80}"
TF_VAR_control_plane_flavor_name="${TF_VAR_control_plane_flavor_name:-${HA_DEVSTACK_CONTROL_FLAVOR_NAME}}"
TF_VAR_build_worker_flavor_name="${TF_VAR_build_worker_flavor_name:-${HA_DEVSTACK_WORKER_FLAVOR_NAME}}"
TF_VAR_gpu_worker_flavor_name="${TF_VAR_gpu_worker_flavor_name:-${HA_OPENSTACK_GPU_FLAVOR_NAME:-g1.large}}"
TF_VAR_gitlab_flavor_name="${TF_VAR_gitlab_flavor_name:-${HA_DEVSTACK_GITLAB_FLAVOR_NAME}}"
TF_VAR_harbor_flavor_name="${TF_VAR_harbor_flavor_name:-${HA_DEVSTACK_HARBOR_FLAVOR_NAME}}"
HA_OPENSTACK_GPU_PCI_ALIAS="${HA_OPENSTACK_GPU_PCI_ALIAS:-nvidia-gpu}"
HA_OPENSTACK_GPU_PCI_VENDOR_ID="${HA_OPENSTACK_GPU_PCI_VENDOR_ID:-10de}"
HA_OPENSTACK_GPU_PCI_PRODUCT_ID="${HA_OPENSTACK_GPU_PCI_PRODUCT_ID:-auto}"
HA_OPENSTACK_GPU_PCI_DEVICE_TYPE="${HA_OPENSTACK_GPU_PCI_DEVICE_TYPE:-type-PF}"
HA_OPENSTACK_GPU_PCI_NUMA_POLICY="${HA_OPENSTACK_GPU_PCI_NUMA_POLICY:-preferred}"
HA_OPENSTACK_GPU_BIND_IOMMU_GROUP="${HA_OPENSTACK_GPU_BIND_IOMMU_GROUP:-true}"
HA_OPENSTACK_GPU_FLAVOR_NAME="${HA_OPENSTACK_GPU_FLAVOR_NAME:-g1.large}"
HA_OPENSTACK_GPU_FLAVOR_RAM="${HA_OPENSTACK_GPU_FLAVOR_RAM:-8192}"
HA_OPENSTACK_GPU_FLAVOR_VCPUS="${HA_OPENSTACK_GPU_FLAVOR_VCPUS:-4}"
HA_OPENSTACK_GPU_FLAVOR_DISK="${HA_OPENSTACK_GPU_FLAVOR_DISK:-80}"
GITLAB_INSTALL_ENABLED="${GITLAB_INSTALL_ENABLED:-true}"
GITLAB_DOMAIN="${GITLAB_DOMAIN:-gitlab.${PRIVATE_CLOUD_BASE_DOMAIN}}"
GITLAB_EXTERNAL_URL="${GITLAB_EXTERNAL_URL:-https://${GITLAB_DOMAIN}}"
GITLAB_IMAGE="${GITLAB_IMAGE:-${TF_VAR_gitlab_container_image}}"
GITLAB_SIGNUP_ENABLED="${GITLAB_SIGNUP_ENABLED:-false}"
GITLAB_ADMIN_USERNAME="${GITLAB_ADMIN_USERNAME:-root}"
GITLAB_GPU_RUNNER_NAME_PREFIX="${GITLAB_GPU_RUNNER_NAME_PREFIX:-hybrid-ai-gpu}"
GITLAB_GPU_RUNNER_TAGS="${GITLAB_GPU_RUNNER_TAGS:-gpu-worker}"
GITLAB_UPSTREAM_PORT="${GITLAB_UPSTREAM_PORT:-18083}"
HARBOR_INSTALL_ENABLED="${HARBOR_INSTALL_ENABLED:-true}"
HARBOR_DOMAIN="${HARBOR_DOMAIN:-harbor.${PRIVATE_CLOUD_BASE_DOMAIN}}"
HARBOR_EXTERNAL_URL="${HARBOR_EXTERNAL_URL:-https://${HARBOR_DOMAIN}}"
HARBOR_VERSION="${HARBOR_VERSION:-v2.14.4}"
HARBOR_PROJECTS="${HARBOR_PROJECTS:-infra models}"
HARBOR_ROBOT_NAME="${HARBOR_ROBOT_NAME:-kaniko}"
HARBOR_HTTP_PORT="${HARBOR_HTTP_PORT:-80}"
HARBOR_UPSTREAM_PORT="${HARBOR_UPSTREAM_PORT:-18084}"
HARBOR_BOOTSTRAP_WAIT_SECONDS="${HARBOR_BOOTSTRAP_WAIT_SECONDS:-1800}"
HARBOR_ADMIN_PASSWORD="${HARBOR_ADMIN_PASSWORD:-}"
ARGO_WORKFLOWS_INSTALL_ENABLED="${ARGO_WORKFLOWS_INSTALL_ENABLED:-true}"
ARGO_WORKFLOWS_INSTALL_MANIFEST="${ARGO_WORKFLOWS_INSTALL_MANIFEST:-https://github.com/argoproj/argo-workflows/releases/download/v3.7.14/install.yaml}"
MINIO_VOLUME_SIZE="${MINIO_VOLUME_SIZE:-10}"
MINIO_ROOT_USER="${MINIO_ROOT_USER:-minioadmin}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-}"
HA_KUBECTL_TUNNEL_PORT="${HA_KUBECTL_TUNNEL_PORT:-16443}"
SSH_KEY="${ROOT}/.ha/ssh/hybrid-ai-private-admin"
SSH_CONFIG="${ROOT}/.ha/openstack/ssh_config"
KUBECONFIG_PATH="${ROOT}/.ha/openstack/kubeconfig"
TF_OUTPUT_JSON="${ROOT}/.ha/openstack/terraform-output.json"
IMAGE_CACHE_ENV="${ROOT}/.ha/openstack/image-cache/images.env"
HA_OPENSTACK_IMAGE_CACHE_ENABLED="${HA_OPENSTACK_IMAGE_CACHE_ENABLED:-true}"
HA_OPENSTACK_IMAGE_CACHE_DIR="${HA_OPENSTACK_IMAGE_CACHE_DIR:-${ROOT}/.ha/openstack/image-cache}"
HA_OPENSTACK_IMAGE_CACHE_PREFIX="${HA_OPENSTACK_IMAGE_CACHE_PREFIX:-hybrid-ai-cache}"
HA_OPENSTACK_IMAGE_CACHE_FLAVOR="${HA_OPENSTACK_IMAGE_CACHE_FLAVOR:-${TF_VAR_build_worker_flavor_name}}"
HA_OPENSTACK_IMAGE_CACHE_GITLAB_FLAVOR="${HA_OPENSTACK_IMAGE_CACHE_GITLAB_FLAVOR:-${TF_VAR_gitlab_flavor_name}}"
HA_OPENSTACK_IMAGE_CACHE_HARBOR_FLAVOR="${HA_OPENSTACK_IMAGE_CACHE_HARBOR_FLAVOR:-${TF_VAR_harbor_flavor_name}}"
HA_OPENSTACK_IMAGE_CACHE_DRIVER_PACKAGE="${HA_OPENSTACK_IMAGE_CACHE_DRIVER_PACKAGE:-nvidia-driver-595-open}"
HA_PRIVATE_CLOUD_AUTO_EXPAND_QUOTA="${HA_PRIVATE_CLOUD_AUTO_EXPAND_QUOTA:-true}"
HA_PRIVATE_CLOUD_QUOTA_HEADROOM_INSTANCES="${HA_PRIVATE_CLOUD_QUOTA_HEADROOM_INSTANCES:-3}"
HA_PRIVATE_CLOUD_QUOTA_HEADROOM_CORES="${HA_PRIVATE_CLOUD_QUOTA_HEADROOM_CORES:-8}"
HA_PRIVATE_CLOUD_QUOTA_HEADROOM_RAM_MB="${HA_PRIVATE_CLOUD_QUOTA_HEADROOM_RAM_MB:-16384}"
HA_PRIVATE_CLOUD_SETUP_STORAGE="${HA_PRIVATE_CLOUD_SETUP_STORAGE:-auto}"
HA_PRIVATE_CLOUD_SETUP_REGISTRY="${HA_PRIVATE_CLOUD_SETUP_REGISTRY:-auto}"
HA_PRIVATE_CLOUD_SETUP_MODEL_BUILD="${HA_PRIVATE_CLOUD_SETUP_MODEL_BUILD:-auto}"
HA_PRIVATE_CLOUD_SYNC_OPENSTACK_USER="${HA_PRIVATE_CLOUD_SYNC_OPENSTACK_USER:-auto}"
HA_TERRAFORM_APPLY_PARALLELISM="${HA_TERRAFORM_APPLY_PARALLELISM:-2}"
HA_ALLOW_UNMANAGED_OPENSTACK_STACK="${HA_ALLOW_UNMANAGED_OPENSTACK_STACK:-false}"

printf 'phase\tseconds\tstatus\n' >"${TIMINGS}"

log() {
  printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"
}

write_systemd_env_line() {
  local file="$1" name="$2" value="$3"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s="%s"\n' "$name" "$value" >>"$file"
}

phase() {
  local name="$1"
  shift
  local start end rc log_file
  log_file="${LOG_DIR}/${name}.log"
  start="$(date +%s)"
  log "START ${name}"
  set +e
  ( set -Eeuo pipefail; "$@" ) >"${log_file}" 2>&1
  rc="$?"
  set -e
  if [[ "${rc}" -eq 0 ]]; then
    end="$(date +%s)"
    printf '%s\t%s\tok\n' "${name}" "$((end - start))" >>"${TIMINGS}"
    log "OK ${name} ($((end - start))s)"
  else
    end="$(date +%s)"
    printf '%s\t%s\tfailed\n' "${name}" "$((end - start))" >>"${TIMINGS}"
    log "FAILED ${name} ($((end - start))s); tail follows from ${log_file}"
    tail -n 160 "${log_file}" || true
    return "${rc}"
  fi
}

phase_bg() {
  local name="$1"
  shift
  ( phase "${name}" "$@" ) &
  printf '%s\n' "$!" >"${LOG_DIR}/${name}.pid"
}

wait_phase_bg() {
  local name="$1"
  local pid
  pid="$(cat "${LOG_DIR}/${name}.pid")"
  if wait "${pid}"; then
    return 0
  fi
  return 1
}

require_tools() {
  local missing=0
  for tool in curl git lxc python3 ssh scp ssh-keygen terraform kubectl helm; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
      printf 'missing tool: %s\n' "${tool}" >&2
      missing=1
    fi
  done
  return "${missing}"
}

ensure_ssh_key() {
  if [[ ! -f "${SSH_KEY}" ]]; then
    ssh-keygen -t ed25519 -N '' -f "${SSH_KEY}" >/dev/null
  fi
}

write_ssh_config() {
  ensure_ssh_key
  {
    printf 'Host *\n'
    printf '  User ubuntu\n'
    printf '  IdentityFile %s\n' "${SSH_KEY}"
    printf '  BatchMode yes\n'
    printf '  StrictHostKeyChecking no\n'
    printf '  CheckHostIP no\n'
    printf '  UserKnownHostsFile /dev/null\n'
    printf '  LogLevel ERROR\n'
    printf '  ProxyCommand lxc exec ha-openstack -- nc %%h %%p\n'
  } >"${SSH_CONFIG}"
  chmod 600 "${SSH_CONFIG}"
}

wait_lxc_ip() {
  for _ in {1..60}; do
    if lxc exec ha-openstack -- ip -4 addr show eth0 2>/dev/null | grep -qP '(?<=inet\s)\d+(\.\d+){3}'; then
      return 0
    fi
    sleep 2
  done
  return 1
}

ensure_devstack_container_running() {
  local status device

  if ! lxc info ha-openstack >/dev/null 2>&1; then
    printf 'DevStack container ha-openstack is missing; rerun with run_mode=reinstall.\n' >&2
    return 1
  fi

  status="$(lxc list ha-openstack -c s --format csv | tr -d '"')"
  if [[ "$status" != "RUNNING" ]]; then
    log "starting DevStack container ha-openstack (current status: ${status:-unknown})"
    # Remove all vfio-group-* devices before start — they will be re-added by
    # bind_gpu_vfio + configure_lxc_devices once the container is running.
    # This prevents start failures when a VFIO device was added in a previous run
    # but the GPU is no longer bound (device path disappeared between prune and start).
    while IFS= read -r device; do
      case "$device" in
        vfio-group-*) lxc config device remove ha-openstack "$device" >/dev/null 2>&1 || true ;;
      esac
    done < <(lxc config device list ha-openstack 2>/dev/null || true)
    configure_lxc_devices
    lxc start ha-openstack
    wait_lxc_ip
  fi
}

desired_lxc_raw_config() {
  printf '%s\n' \
    'lxc.apparmor.profile=unconfined' \
    'lxc.cap.drop=' \
    'lxc.mount.auto=proc:rw sys:rw cgroup:rw'

  if [[ -d /dev/vfio ]]; then
    printf '%s\n' 'lxc.cgroup2.devices.allow = c 10:196 rwm'
    awk '/vfio/ {print "lxc.cgroup2.devices.allow = c " $1 ":* rwm"}' /proc/devices
  fi
}

add_lxc_vfio_devices() {
  local group_device group_id

  [[ -d /dev/vfio ]] || return 0
  lxc config device add ha-openstack vfio disk source=/dev/vfio path=/dev/vfio >/dev/null 2>&1 || true
  if [[ -c /dev/vfio/vfio ]]; then
    lxc config device add ha-openstack vfio-control unix-char source=/dev/vfio/vfio path=/dev/vfio/vfio >/dev/null 2>&1 || true
  fi
  for group_device in /dev/vfio/[0-9]*; do
    [[ -c "${group_device}" ]] || continue
    group_id="${group_device##*/}"
    lxc config device add "ha-openstack" "vfio-group-${group_id}" unix-char source="${group_device}" path="${group_device}" >/dev/null 2>&1 || true
  done
}

prune_stale_lxc_vfio_devices() {
  local device source

  while IFS= read -r device; do
    case "$device" in
      vfio|vfio-control|vfio-group-*)
        source="$(lxc config device get ha-openstack "$device" source 2>/dev/null || true)"
        if [[ -z "$source" || ! -e "$source" ]]; then
          lxc config device remove ha-openstack "$device" >/dev/null 2>&1 || true
        fi
        ;;
    esac
  done < <(lxc config device list ha-openstack 2>/dev/null || true)
}

configure_lxc_devices() {
  local kernel_modules_source
  kernel_modules_source="$(readlink -f /lib/modules)"
  prune_stale_lxc_vfio_devices
  lxc config device add ha-openstack kmsg unix-char source=/dev/kmsg path=/dev/kmsg >/dev/null 2>&1 || true
  lxc config device remove ha-openstack host-kernel-modules >/dev/null 2>&1 || true
  lxc config device add ha-openstack host-kernel-modules disk source="${kernel_modules_source}" path=/usr/lib/modules readonly=true >/dev/null 2>&1 || true
  if [[ -e /dev/kvm ]]; then
    lxc config device add ha-openstack kvm unix-char source=/dev/kvm path=/dev/kvm >/dev/null 2>&1 || true
  fi
  add_lxc_vfio_devices
}

configure_vfio_guest_access() {
  lxc exec ha-openstack -- bash -s <<'CONFIGURE_VFIO_GUEST_ACCESS'
set -euo pipefail

if [[ -d /dev/vfio ]]; then
  for dev in /dev/vfio/vfio /dev/vfio/[0-9]*; do
    [[ -c "$dev" ]] || continue
    if getent group kvm >/dev/null 2>&1; then
      chgrp kvm "$dev" || true
    fi
    chmod 660 "$dev" || true
  done
fi

conf=/etc/libvirt/qemu.conf
if [[ -f "$conf" ]]; then
  changed=0
  ensure_qemu_vfio_acl() {
    local dev="$1"
    [[ -c "$dev" ]] || return 0
    if grep -Fq "\"$dev\"" "$conf"; then
      return 0
    fi
    if grep -Fq '"/dev/vfio/vfio"' "$conf"; then
      sed -i "/\"\/dev\/vfio\/vfio\"/a\\    \"$dev\"," "$conf"
    elif grep -q '^cgroup_device_acl = \[' "$conf"; then
      sed -i "/^cgroup_device_acl = \[/a\\    \"$dev\"," "$conf"
    else
      cat >>"$conf" <<'EOF'
cgroup_device_acl = [
    "/dev/null", "/dev/full", "/dev/zero",
    "/dev/random", "/dev/urandom",
    "/dev/ptmx", "/dev/kvm", "/dev/kqemu",
    "/dev/rtc", "/dev/hpet","/dev/net/tun",
    "/dev/vfio/vfio",
]
EOF
    fi
    changed=1
  }

  ensure_qemu_vfio_acl /dev/vfio/vfio
  for dev in /dev/vfio/[0-9]*; do
    ensure_qemu_vfio_acl "$dev"
  done

  if [[ "$changed" -eq 1 ]] && systemctl list-unit-files libvirtd.service >/dev/null 2>&1; then
    systemctl restart libvirtd || true
    sleep 15
  fi
fi
CONFIGURE_VFIO_GUEST_ACCESS
}

create_devstack_container() {
  local raw_lxc
  lxc stop ha-openstack --force >/dev/null 2>&1 || true
  lxc delete ha-openstack --force >/dev/null 2>&1 || true
  raw_lxc="$(desired_lxc_raw_config)"
  lxc init ubuntu:24.04 ha-openstack \
    -c security.nesting=true \
    -c security.privileged=true \
    -c raw.lxc="${raw_lxc}"
  configure_lxc_devices
  lxc start ha-openstack
  wait_lxc_ip
  configure_vfio_guest_access
  lxc list ha-openstack
}

install_devstack_prereqs() {
  lxc exec ha-openstack -- bash -lc '
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq git sudo curl ca-certificates iproute2 net-tools kmod openssh-client netcat-openbsd python3-openstackclient
    id stack >/dev/null 2>&1 || useradd -s /bin/bash -d /opt/stack -m stack
    chmod +x /opt/stack
    printf "stack ALL=(ALL) NOPASSWD: ALL\n" >/etc/sudoers.d/stack
    chmod 440 /etc/sudoers.d/stack
    chown -R stack:stack /opt/stack
  '
}

detect_gpu_product() {
  local vendor_id product_id
  vendor_id="$(printf '%s' "${HA_OPENSTACK_GPU_PCI_VENDOR_ID}" | tr '[:upper:]' '[:lower:]' | sed 's/^0x//')"
  product_id="${HA_OPENSTACK_GPU_PCI_PRODUCT_ID}"
  if [[ "${product_id}" == "auto" ]]; then
    product_id="$(lxc exec ha-openstack -- bash -s -- "${vendor_id}" <<'DETECT_GPU' || true
set -euo pipefail
vendor_id="$1"
for device in /sys/bus/pci/devices/*; do
  vendor="$(cat "${device}/vendor" 2>/dev/null || true)"
  product="$(cat "${device}/device" 2>/dev/null || true)"
  class="$(cat "${device}/class" 2>/dev/null || true)"
  vendor="$(printf '%s' "${vendor#0x}" | tr '[:upper:]' '[:lower:]')"
  product="$(printf '%s' "${product#0x}" | tr '[:upper:]' '[:lower:]')"
  class="$(printf '%s' "${class#0x}" | tr '[:upper:]' '[:lower:]')"
  if [[ "$vendor" == "$vendor_id" && "$class" == 03* && -n "$product" ]]; then
    printf '%s\n' "$product"
    exit 0
  fi
done
DETECT_GPU
)"
  else
    product_id="$(printf '%s' "${product_id}" | tr '[:upper:]' '[:lower:]' | sed 's/^0x//')"
  fi
  printf '%s\n' "${product_id}"
}

bind_gpu_vfio() {
  local product_id="$1"
  [[ "${HA_OPENSTACK_GPU_BIND_IOMMU_GROUP}" == "true" ]] || return 0
  [[ -n "${product_id}" ]] || return 0
  lxc exec ha-openstack -- bash -s -- \
    "${HA_OPENSTACK_GPU_PCI_VENDOR_ID}" \
    "${product_id}" <<'BIND_GPU_VFIO'
set -euo pipefail
vendor_id="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/^0x//')"
product_id="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]' | sed 's/^0x//')"
bdf=""
for device in /sys/bus/pci/devices/*; do
  vendor="$(cat "${device}/vendor" 2>/dev/null || true)"
  product="$(cat "${device}/device" 2>/dev/null || true)"
  class="$(cat "${device}/class" 2>/dev/null || true)"
  vendor="$(printf '%s' "${vendor#0x}" | tr '[:upper:]' '[:lower:]')"
  product="$(printf '%s' "${product#0x}" | tr '[:upper:]' '[:lower:]')"
  class="$(printf '%s' "${class#0x}" | tr '[:upper:]' '[:lower:]')"
  if [[ "$vendor" == "$vendor_id" && "$product" == "$product_id" && "$class" == 03* ]]; then
    bdf="${device##*/}"
    break
  fi
done
[[ -n "$bdf" ]] || exit 0
group_dir="$(readlink -f "/sys/bus/pci/devices/${bdf}/iommu_group" 2>/dev/null || true)"
[[ -n "$group_dir" && -d "$group_dir" ]] || exit 0
modprobe vfio-pci
for member in "${group_dir}"/devices/*; do
  [[ -e "$member" ]] || continue
  member_bdf="${member##*/}"
  class="$(cat "${member}/class" 2>/dev/null || true)"
  class="$(printf '%s' "${class#0x}" | tr '[:upper:]' '[:lower:]')"
  [[ "$class" == 06* ]] && continue
  current_driver="$(basename "$(readlink -f "${member}/driver" 2>/dev/null)" 2>/dev/null || true)"
  [[ "$current_driver" == "vfio-pci" ]] && continue
  printf vfio-pci >"${member}/driver_override"
  driver_path="$(readlink -f "${member}/driver" 2>/dev/null || true)"
  [[ -n "$driver_path" ]] && printf '%s' "$member_bdf" >"${driver_path}/unbind"
  printf '%s' "$member_bdf" >/sys/bus/pci/drivers_probe
done
BIND_GPU_VFIO
  configure_lxc_devices
  configure_vfio_guest_access
}

clone_and_configure_devstack() {
  local ip product_id
  product_id="$1"
  lxc exec ha-openstack -- sudo -u stack -H bash -lc 'git clone --depth=1 --branch master https://opendev.org/openstack/devstack /opt/stack/devstack'
  ip="$(lxc exec ha-openstack -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1)"
  printf '%s' "${HA_DEVSTACK_PASSWORD}" \
    | lxc exec ha-openstack -- sudo -u stack -H bash -lc 'umask 077 && cat > /opt/stack/devstack/.devstack-password'
  lxc exec ha-openstack -- sudo -u stack -H bash -s -- \
    "${ip}" <<'WRITE_LOCAL_CONF'
set -euo pipefail
IP="$1"
PASSWORD="$(cat /opt/stack/devstack/.devstack-password)"
{
  printf '%s\n' '[[local|localrc]]'
  printf 'ADMIN_PASSWORD=%s\n' "$PASSWORD"
  printf 'DATABASE_PASSWORD=%s\n' "$PASSWORD"
  printf 'RABBIT_PASSWORD=%s\n' "$PASSWORD"
  printf 'SERVICE_PASSWORD=%s\n' "$PASSWORD"
  printf 'SERVICE_TOKEN=%s\n' "$PASSWORD"
  printf 'MYSQL_PASSWORD=%s\n' "$PASSWORD"
  printf 'HOST_IP=%s\n' "$IP"
  printf 'SERVICE_HOST=%s\n' "$IP"
  printf '%s\n' 'LOGFILE=/opt/stack/logs/stack.sh.log'
  printf '%s\n' 'LOG_COLOR=False'
  printf '%s\n' 'VERBOSE=True'
  printf '%s\n' 'LIBVIRT_TYPE=qemu'
  printf '%s\n' 'ENABLE_VOLUME_BACKING_FILE=True'
  printf '%s\n' 'ETCD_DOWNLOAD_URL=https://storage.googleapis.com/etcd'
  printf '%s\n' 'IMAGE_URLS=https://github.com/cirros-dev/cirros/releases/download/0.6.2/cirros-0.6.2-x86_64-disk.img'
  printf '%s\n' 'disable_service tempest'
  printf '%s\n' 'disable_service swift'
  printf '%s\n' 'disable_service cinder'
  printf '%s\n' 'ENABLE_KSM=False'
} >/opt/stack/devstack/local.conf
WRITE_LOCAL_CONF
  lxc exec ha-openstack -- chown stack:stack /opt/stack/devstack/local.conf
  lxc exec ha-openstack -- chmod 600 /opt/stack/devstack/local.conf
  lxc exec ha-openstack -- sed -i 's/^function configure_ksm {/function configure_ksm {\n    return 0/' /opt/stack/devstack/lib/host
}

run_devstack() {
  lxc exec ha-openstack -- sudo -u stack -H bash -s <<'RUN_DEVSTACK'
set -euo pipefail
cd /opt/stack/devstack
trap 'rm -f /opt/stack/devstack/.devstack-password' EXIT
export FORCE=yes
./stack.sh < /dev/null
RUN_DEVSTACK
}

ensure_flavors() {
  lxc exec ha-openstack -- sudo -u stack -H bash -s -- \
    "${HA_DEVSTACK_CONTROL_FLAVOR_NAME}" "${HA_DEVSTACK_CONTROL_FLAVOR_RAM}" "${HA_DEVSTACK_CONTROL_FLAVOR_VCPUS}" "${HA_DEVSTACK_CONTROL_FLAVOR_DISK}" \
    "${HA_DEVSTACK_WORKER_FLAVOR_NAME}" "${HA_DEVSTACK_WORKER_FLAVOR_RAM}" "${HA_DEVSTACK_WORKER_FLAVOR_VCPUS}" "${HA_DEVSTACK_WORKER_FLAVOR_DISK}" \
    "${HA_DEVSTACK_GITLAB_FLAVOR_NAME}" "${HA_DEVSTACK_GITLAB_FLAVOR_RAM}" "${HA_DEVSTACK_GITLAB_FLAVOR_VCPUS}" "${HA_DEVSTACK_GITLAB_FLAVOR_DISK}" \
    "${HA_DEVSTACK_HARBOR_FLAVOR_NAME}" "${HA_DEVSTACK_HARBOR_FLAVOR_RAM}" "${HA_DEVSTACK_HARBOR_FLAVOR_VCPUS}" "${HA_DEVSTACK_HARBOR_FLAVOR_DISK}" \
    "${HA_OPENSTACK_GPU_FLAVOR_NAME}" "${HA_OPENSTACK_GPU_FLAVOR_RAM}" "${HA_OPENSTACK_GPU_FLAVOR_VCPUS}" "${HA_OPENSTACK_GPU_FLAVOR_DISK}" <<'ENSURE_COMPUTE_FLAVORS'
set -eo pipefail
cd /opt/stack/devstack
set +u
source openrc admin admin >/dev/null
set -u
flavor_matches() {
  local name="$1" ram="$2" vcpus="$3" disk="$4"
  local flavor_json
  flavor_json="$(openstack flavor show "$name" -f json)"
  python3 - "$ram" "$vcpus" "$disk" "$flavor_json" <<'PY'
import json
import sys

expected_ram, expected_vcpus, expected_disk = map(int, sys.argv[1:4])
flavor = json.loads(sys.argv[4])
if (
    int(flavor["ram"]) == expected_ram
    and int(flavor["vcpus"]) == expected_vcpus
    and int(flavor["disk"]) == expected_disk
):
    sys.exit(0)
sys.exit(1)
PY
}

ensure_flavor() {
  local name="$1" ram="$2" vcpus="$3" disk="$4"
  if openstack flavor show "$name" >/dev/null 2>&1; then
    if flavor_matches "$name" "$ram" "$vcpus" "$disk"; then
      openstack flavor set --property "hw_rng:allowed=True" "$name"
      return 0
    fi
    openstack flavor delete "$name"
  fi
  openstack flavor create --ram "$ram" --vcpus "$vcpus" --disk "$disk" "$name" >/dev/null
  openstack flavor set --property "hw_rng:allowed=True" "$name"
}
ensure_flavor "$1" "$2" "$3" "$4"
ensure_flavor "$5" "$6" "$7" "$8"
ensure_flavor "$9" "${10}" "${11}" "${12}"
ensure_flavor "${13}" "${14}" "${15}" "${16}"
ensure_flavor "${17}" "${18}" "${19}" "${20}"
openstack flavor set --property "pci_passthrough:alias=nvidia-gpu:1" --property "hw:pci_numa_affinity_policy=preferred" "${17}" || true
ENSURE_COMPUTE_FLAVORS
}

configure_gpu_passthrough() {
  local product_id
  product_id="$(detect_gpu_product)"
  [[ -n "${product_id}" ]] || return 0
  configure_vfio_guest_access
  lxc exec ha-openstack -- sudo -u stack -H bash -s -- \
    "${HA_OPENSTACK_GPU_PCI_ALIAS}" \
    "${HA_OPENSTACK_GPU_PCI_VENDOR_ID}" \
    "${product_id}" \
    "${HA_OPENSTACK_GPU_PCI_DEVICE_TYPE}" \
    "${HA_OPENSTACK_GPU_PCI_NUMA_POLICY}" \
    "${HA_OPENSTACK_GPU_FLAVOR_NAME}" \
    "${HA_OPENSTACK_GPU_FLAVOR_RAM}" \
    "${HA_OPENSTACK_GPU_FLAVOR_VCPUS}" \
    "${HA_OPENSTACK_GPU_FLAVOR_DISK}" <<'CONFIGURE_GPU_PASSTHROUGH'
set -euo pipefail
gpu_alias="$1"
gpu_vendor_id="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]' | sed 's/^0x//')"
gpu_product_id="$3"
gpu_device_type="$4"
gpu_numa_policy="$5"
gpu_flavor_name="$6"
gpu_flavor_ram="$7"
gpu_flavor_vcpus="$8"
gpu_flavor_disk="$9"
cd /opt/stack/devstack
set +u
source openrc admin admin >/dev/null
source functions-common
set -u
device_spec="{\"vendor_id\":\"${gpu_vendor_id}\",\"product_id\":\"${gpu_product_id}\",\"dev_type\":\"${gpu_device_type}\"}"
alias_spec="{\"name\":\"${gpu_alias}\",\"vendor_id\":\"${gpu_vendor_id}\",\"product_id\":\"${gpu_product_id}\",\"device_type\":\"${gpu_device_type}\",\"numa_policy\":\"${gpu_numa_policy}\"}"
filters="ComputeFilter,ComputeCapabilitiesFilter,ImagePropertiesFilter,ServerGroupAntiAffinityFilter,ServerGroupAffinityFilter,SameHostFilter,DifferentHostFilter,PciPassthroughFilter"
for conf in /etc/nova/nova.conf /etc/nova/nova-cpu.conf; do
  [[ -f "$conf" ]] || continue
  iniset -sudo "$conf" pci device_spec "$device_spec"
  iniset -sudo "$conf" pci alias "$alias_spec"
  iniset -sudo "$conf" filter_scheduler available_filters "nova.scheduler.filters.all_filters"
  iniset -sudo "$conf" filter_scheduler enabled_filters "$filters"
done
if ! openstack flavor show "$gpu_flavor_name" >/dev/null 2>&1; then
  openstack flavor create --ram "$gpu_flavor_ram" --vcpus "$gpu_flavor_vcpus" --disk "$gpu_flavor_disk" "$gpu_flavor_name" >/dev/null
fi
openstack flavor set \
  --property "pci_passthrough:alias=${gpu_alias}:1" \
  --property "hw:pci_numa_affinity_policy=${gpu_numa_policy}" \
  --property "hw_rng:allowed=True" \
  "$gpu_flavor_name"
sudo systemctl restart devstack@n-api.service devstack@n-sch.service devstack@n-super-cond.service devstack@n-cpu.service 2>/dev/null \
  || sudo systemctl restart devstack@n-api.service devstack@n-sch.service devstack@n-cpu.service
CONFIGURE_GPU_PASSTHROUGH
}

ensure_images() {
  lxc exec ha-openstack -- sudo -u stack -H bash -s -- \
    "${TF_VAR_control_plane_image_name}" \
    "${TF_VAR_build_worker_image_name}" \
    "${TF_VAR_gpu_worker_image_name}" \
    "${TF_VAR_gitlab_image_name}" \
    "${TF_VAR_harbor_image_name}" <<'ENSURE_IMAGE'
set -eo pipefail
cd /opt/stack/devstack
set +u
source openrc admin admin >/dev/null
set -u
ensure_image() {
  local image_name="$1" image_url="" image_file=""
  [[ -n "$image_name" ]] || return 0
  if openstack image show "$image_name" >/dev/null 2>&1; then
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
      echo "unknown image: $image_name" >&2
      return 1
      ;;
  esac
  mkdir -p /opt/stack/images
  [[ -f "$image_file" ]] || curl -fL --retry 3 --retry-delay 5 -o "$image_file" "$image_url"
  openstack image create "$image_name" --disk-format qcow2 --container-format bare --public --file "$image_file" >/dev/null
}
seen=" "
for image_name in "$@"; do
  [[ "$seen" == *" $image_name "* ]] && continue
  seen="${seen}${image_name} "
  ensure_image "$image_name"
done
ENSURE_IMAGE
}

prepare_cached_images() {
  local args=()
  local apply_prefix effective_build_worker_count effective_gpu_worker_count effective_gitlab_count effective_harbor_count

  [[ "${MODE}" != "destroy" ]] || return 0
  cd "${ROOT}/private/openstack"
  rm -f private-cloud.auto.tfvars
  if [[ -n "${PRIVATE_CLOUD_TFVARS:-}" ]]; then
    printf '%s' "${PRIVATE_CLOUD_TFVARS}" > private-cloud.auto.tfvars
  fi

  apply_prefix="$(terraform_apply_prefix)"
  effective_build_worker_count="$(effective_worker_count build_worker_count "${TF_VAR_build_worker_count}" "$apply_prefix")"
  effective_gpu_worker_count="$(effective_worker_count gpu_worker_count "${TF_VAR_gpu_worker_count}" "$apply_prefix")"
  effective_gitlab_count="$(effective_worker_count gitlab_count "${TF_VAR_gitlab_count}" "$apply_prefix")"
  effective_harbor_count="$(effective_worker_count harbor_count "${TF_VAR_harbor_count}" "$apply_prefix")"

  export HA_OPENSTACK_IMAGE_CACHE_ENABLED
  export HA_OPENSTACK_IMAGE_CACHE_DIR
  export HA_OPENSTACK_IMAGE_CACHE_ENV="${IMAGE_CACHE_ENV}"
  export HA_OPENSTACK_IMAGE_CACHE_PREFIX
  export HA_OPENSTACK_IMAGE_CACHE_FLAVOR
  export HA_OPENSTACK_IMAGE_CACHE_GITLAB_FLAVOR
  export HA_OPENSTACK_IMAGE_CACHE_HARBOR_FLAVOR
  export HA_OPENSTACK_IMAGE_CACHE_DRIVER_PACKAGE
  export HA_OPENSTACK_IMAGE_CACHE_GITLAB_IMAGE="${GITLAB_IMAGE}"
  export HA_OPENSTACK_IMAGE_CACHE_SSH_KEY="${SSH_KEY}"
  export HA_OPENSTACK_IMAGE_CACHE_CONTROL_PLANE_NFS="true"
  if ! optional_apply_phase_enabled "${HA_PRIVATE_CLOUD_SETUP_STORAGE}"; then
    HA_OPENSTACK_IMAGE_CACHE_CONTROL_PLANE_NFS="false"
  fi

  args+=("control-plane=${TF_VAR_control_plane_image_name}")
  if [[ "${effective_build_worker_count}" != "0" ]]; then
    args+=("build-worker=${TF_VAR_build_worker_image_name}")
  fi
  if [[ "${effective_gpu_worker_count}" != "0" ]]; then
    args+=("gpu-worker=${TF_VAR_gpu_worker_image_name}")
  fi
  if [[ "${effective_gitlab_count}" != "0" ]]; then
    args+=("gitlab=${TF_VAR_gitlab_image_name}")
  fi
  if [[ "${effective_harbor_count}" != "0" ]]; then
    args+=("harbor=${TF_VAR_harbor_image_name}")
  fi

  "${ROOT}/private/openstack/scripts/cache-openstack-images.sh" "${args[@]}"
  load_cached_image_overrides
}

load_cached_image_overrides() {
  [[ "${HA_OPENSTACK_IMAGE_CACHE_ENABLED}" == "true" ]] || return 0
  [[ -s "${IMAGE_CACHE_ENV}" ]] || return 0
  # shellcheck disable=SC1090
  source "${IMAGE_CACHE_ENV}"
  export TF_VAR_control_plane_image_name TF_VAR_build_worker_image_name TF_VAR_gpu_worker_image_name TF_VAR_gitlab_image_name TF_VAR_harbor_image_name
}

terraform_var_value() {
  local name="$1"
  local default_value="$2"
  shift 2
  python3 - "$name" "$default_value" "$@" <<'PY'
import os
import re
import sys

name = sys.argv[1]
value = os.environ.get(f"TF_VAR_{name}", sys.argv[2])
assignment = re.compile(rf"^\s*{re.escape(name)}\s*=\s*(.*?)\s*$")


def parse_scalar(raw):
    raw = raw.strip()
    if raw.startswith('"') and raw.endswith('"'):
        return bytes(raw[1:-1], "utf-8").decode("unicode_escape")
    if raw.startswith("'") and raw.endswith("'"):
        return raw[1:-1]
    return raw


for path in sys.argv[3:]:
    if not os.path.exists(path):
        continue
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            match = assignment.match(line)
            if not match:
                continue
            value = parse_scalar(match.group(1).split(" #", 1)[0].split(" //", 1)[0])

print(value)
PY
}

terraform_var_int() {
  local name="$1"
  local default_value="$2"
  local value
  value="$(terraform_var_value "$name" "$default_value" private-cloud.auto.tfvars zz-local-devstack.auto.tfvars)"
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    printf 'Terraform variable %s must be a non-negative integer, got: %s\n' "$name" "$value" >&2
    return 1
  fi
  printf '%s\n' "$value"
}

terraform_apply_prefix() {
  terraform_var_value \
    project_name \
    hybrid-ai-private \
    "${ROOT}/private/openstack/private-cloud.auto.tfvars" \
    "${ROOT}/private/openstack/zz-local-devstack.auto.tfvars"
}

guard_unmanaged_openstack_stack() {
  local prefix="$1"
  local managed_compute
  local existing_servers

  [[ "${HA_ALLOW_UNMANAGED_OPENSTACK_STACK}" != "true" ]] || return 0
  managed_compute="$(terraform state list 2>/dev/null | grep -Ec '^openstack_compute_instance_v2\.' || true)"
  managed_compute="${managed_compute:-0}"
  [[ "$managed_compute" -eq 0 ]] || return 0

  existing_servers="$(lxc exec ha-openstack -- sudo -u stack -H bash -lc '
    set -euo pipefail
    prefix="$1"
    cd /opt/stack/devstack
    set +u
    source openrc admin admin >/dev/null
    set -u
    openstack server list --all-projects -f value -c ID -c Name -c Status \
      | while read -r id name status; do
          [[ -n "${id:-}" && -n "${name:-}" ]] || continue
          if [[ "$name" == "${prefix}-"* ]]; then
            printf "%s %s %s\n" "$id" "$name" "${status:-}"
          fi
        done
  ' _ "$prefix")"

  if [[ -n "$existing_servers" ]]; then
    {
      printf 'Terraform state has no managed compute instances, but OpenStack already has servers for project_name=%s:\n' "$prefix"
      printf '%s\n' "$existing_servers"
      printf 'Refusing to apply because this would create duplicate VMs. Run destroy/import with the matching backend state first.\n'
    } >&2
    return 1
  fi
}

optional_apply_phase_enabled() {
  local setting="$1"

  case "$setting" in
    true) return 0 ;;
    false) return 1 ;;
    auto) return 0 ;;
    *)
      printf 'optional apply phase setting must be true, false, or auto; got: %s\n' "$setting" >&2
      return 2
      ;;
  esac
}

skip_phase() {
  local name="$1"
  local reason="$2"

  printf '%s\t0\tskipped\n' "${name}" >>"${TIMINGS}"
  log "SKIP ${name}: ${reason}"
}

terraform_tfvars_has_var() {
  local name="$1"
  local file="$2"

  [[ -f "$file" ]] || return 1
  python3 - "$name" "$file" <<'PY'
import re
import sys

name, path = sys.argv[1], sys.argv[2]
pattern = re.compile(rf"^\s*{re.escape(name)}\s*=")
with open(path, "r", encoding="utf-8") as handle:
    for line in handle:
        if pattern.match(line):
            sys.exit(0)
sys.exit(1)
PY
}

effective_worker_count() {
  local name="$1"
  local default_value="$2"
  local _prefix="$3"
  local provided_var_name
  local env_var_name
  local value

  case "$name" in
    build_worker_count) provided_var_name="TF_VAR_BUILD_WORKER_COUNT_INPUT_PROVIDED" ;;
    gpu_worker_count) provided_var_name="TF_VAR_GPU_WORKER_COUNT_INPUT_PROVIDED" ;;
    gitlab_count) provided_var_name="TF_VAR_GITLAB_COUNT_INPUT_PROVIDED" ;;
    harbor_count) provided_var_name="TF_VAR_HARBOR_COUNT_INPUT_PROVIDED" ;;
    *) provided_var_name="" ;;
  esac

  if [[ -n "$provided_var_name" && "${!provided_var_name}" == "true" ]]; then
    env_var_name="TF_VAR_${name}"
    value="${!env_var_name}"
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
      printf 'Terraform variable %s must be a non-negative integer, got: %s\n' "$name" "$value" >&2
      return 1
    fi
    printf '%s\n' "$value"
    return 0
  fi

  terraform_var_value "$name" "$default_value" private-cloud.auto.tfvars
}

cleanup_openstack_orphans_before_apply() {
  local prefix

  [[ "${HA_PRIVATE_CLOUD_CLEANUP_ORPHANS_BEFORE_APPLY:-true}" == "true" ]] || return 0
  command -v lxc >/dev/null 2>&1 || return 0
  lxc info ha-openstack >/dev/null 2>&1 || return 0

  prefix="$(terraform_apply_prefix)"
  log "checking OpenStack orphan resources before apply for prefix ${prefix}"
  lxc exec ha-openstack -- sudo -u stack -H bash -s -- "$prefix" <<'CLEANUP_OPENSTACK_ORPHANS_BEFORE_APPLY'
set -euo pipefail
prefix="$1"
cd /opt/stack/devstack
set +u
source openrc admin admin >/dev/null
set -u

server_ids="$(openstack server list -f value -c ID -c Name | awk -v p="$prefix" '$2 ~ "^" p {print $1}')"
if [[ -n "$server_ids" ]]; then
  echo "existing servers found for ${prefix}; skipping orphan cleanup"
  exit 0
fi

network_id="$(openstack network list -f value -c ID -c Name | awk -v n="${prefix}-net" '$2 == n {print $1; exit}')"
router_id="$(openstack router list -f value -c ID -c Name | awk -v n="${prefix}-router" '$2 == n {print $1; exit}')"
subnet_id="$(openstack subnet list -f value -c ID -c Name | awk -v n="${prefix}-subnet" '$2 == n {print $1; exit}')"
sg_id="$(openstack security group list -f value -c ID -c Name | awk -v n="${prefix}-sg" '$2 == n {print $1; exit}')"

if [[ -z "$network_id$router_id$subnet_id$sg_id" ]]; then
  echo "no orphan OpenStack resources found for ${prefix}"
  exit 0
fi

echo "removing orphan OpenStack resources for ${prefix}"
network_port_ids=""
if [[ -n "$network_id" ]]; then
  network_port_ids="$(openstack port list --network "$network_id" -f value -c ID)"
fi
if [[ -n "$network_port_ids" ]]; then
  fip_ids="$(openstack floating ip list -f value -c ID -c Port | awk -v ports="$network_port_ids" '
    BEGIN {
      split(ports, lines, "\n")
      for (idx in lines) {
        if (lines[idx] != "") {
          keep[lines[idx]] = 1
        }
      }
    }
    $2 in keep {print $1}
  ')"
  if [[ -n "$fip_ids" ]]; then
    while IFS= read -r id; do
      [[ -n "$id" ]] && openstack floating ip delete "$id" || true
    done <<<"$fip_ids"
  fi
fi

if [[ -n "$router_id" && -n "$subnet_id" ]]; then
  openstack router remove subnet "$router_id" "$subnet_id" || true
fi
if [[ -n "$router_id" ]]; then
  openstack router delete "$router_id" || true
fi

if [[ -n "$network_id" ]]; then
  port_ids="$(openstack port list --network "$network_id" -f value -c ID)"
  if [[ -n "$port_ids" ]]; then
    while IFS= read -r id; do
      [[ -n "$id" ]] && openstack port delete "$id" || true
    done <<<"$port_ids"
  fi
fi
if [[ -n "$subnet_id" ]]; then
  openstack subnet delete "$subnet_id" || true
fi
if [[ -n "$network_id" ]]; then
  openstack network delete "$network_id" || true
fi
if [[ -n "$sg_id" ]]; then
  openstack security group delete "$sg_id" || true
fi
CLEANUP_OPENSTACK_ORPHANS_BEFORE_APPLY
}

preflight_openstack_quota() {
  local prefix control_count build_count gpu_count gitlab_count harbor_count
  local control_flavor build_flavor gpu_flavor gitlab_flavor harbor_flavor

  [[ "${HA_PRIVATE_CLOUD_QUOTA_PREFLIGHT:-true}" == "true" ]] || return 0
  command -v lxc >/dev/null 2>&1 || return 0
  lxc info ha-openstack >/dev/null 2>&1 || return 0

  prefix="$(terraform_apply_prefix)"
  control_count="$(terraform_var_int control_plane_count 1)"
  build_count="$(terraform_var_int build_worker_count 1)"
  gpu_count="$(terraform_var_int gpu_worker_count 1)"
  gitlab_count="$(terraform_var_int gitlab_count 1)"
  harbor_count="$(terraform_var_int harbor_count 1)"
  control_flavor="$(terraform_var_value control_plane_flavor_name "${HA_DEVSTACK_CONTROL_FLAVOR_NAME}" private-cloud.auto.tfvars zz-local-devstack.auto.tfvars)"
  build_flavor="$(terraform_var_value build_worker_flavor_name "${HA_DEVSTACK_WORKER_FLAVOR_NAME}" private-cloud.auto.tfvars zz-local-devstack.auto.tfvars)"
  gpu_flavor="$(terraform_var_value gpu_worker_flavor_name "${HA_OPENSTACK_GPU_FLAVOR_NAME}" private-cloud.auto.tfvars zz-local-devstack.auto.tfvars)"
  gitlab_flavor="$(terraform_var_value gitlab_flavor_name "${HA_DEVSTACK_GITLAB_FLAVOR_NAME}" private-cloud.auto.tfvars zz-local-devstack.auto.tfvars)"
  harbor_flavor="$(terraform_var_value harbor_flavor_name "${HA_DEVSTACK_HARBOR_FLAVOR_NAME}" private-cloud.auto.tfvars zz-local-devstack.auto.tfvars)"

  log "checking OpenStack quota before apply for prefix ${prefix}"
  lxc exec ha-openstack -- sudo -u stack -H bash -s -- \
    "$prefix" \
    "${HA_PRIVATE_CLOUD_AUTO_EXPAND_QUOTA}" \
    "${HA_PRIVATE_CLOUD_QUOTA_HEADROOM_INSTANCES}" \
    "${HA_PRIVATE_CLOUD_QUOTA_HEADROOM_CORES}" \
    "${HA_PRIVATE_CLOUD_QUOTA_HEADROOM_RAM_MB}" \
    control "$control_count" "$control_flavor" \
    build "$build_count" "$build_flavor" \
    gpu "$gpu_count" "$gpu_flavor" \
    gitlab "$gitlab_count" "$gitlab_flavor" \
    harbor "$harbor_count" "$harbor_flavor" <<'PREFLIGHT_OPENSTACK_QUOTA'
set -euo pipefail
prefix="$1"
auto_expand_quota="$2"
quota_headroom_instances="$3"
quota_headroom_cores="$4"
quota_headroom_ram_mb="$5"
shift 5
cd /opt/stack/devstack
set +u
source openrc admin admin >/dev/null
set -u

flavor_vcpus() {
  openstack flavor show "$1" -f value -c vcpus
}

flavor_ram() {
  openstack flavor show "$1" -f value -c ram
}

server_exists() {
  openstack server show "$1" >/dev/null 2>&1
}

missing_for_role() {
  local role="$1" count="$2" missing=0 index name
  for ((index = 1; index <= count; index += 1)); do
    printf -v name "%s-%s-%02d" "$prefix" "$role" "$index"
    if ! server_exists "$name"; then
      missing=$((missing + 1))
    fi
  done
  printf '%s\n' "$missing"
}

limits_json="$(openstack limits show --absolute -f json)"
read_limits() {
  local json="$1"
  python3 - "$json" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
values = {item["Name"]: int(item["Value"]) for item in payload}
print(
    values.get("max_total_cores", -1),
    values.get("total_cores_used", 0),
    values.get("max_total_ram_size", -1),
    values.get("total_ram_used", 0),
    values.get("max_total_instances", -1),
    values.get("total_instances_used", 0),
)
PY
}

read -r max_cores used_cores max_ram used_ram max_instances used_instances < <(read_limits "$limits_json")

need_cores=0
need_ram=0
need_instances=0
summary=()
while [[ $# -gt 0 ]]; do
  role="$1"
  count="$2"
  flavor="$3"
  shift 3
  [[ "$count" -gt 0 ]] || continue
  missing="$(missing_for_role "$role" "$count")"
  [[ "$missing" -gt 0 ]] || continue
  vcpus="$(flavor_vcpus "$flavor")"
  ram="$(flavor_ram "$flavor")"
  role_cores=$((missing * vcpus))
  role_ram=$((missing * ram))
  need_cores=$((need_cores + role_cores))
  need_ram=$((need_ram + role_ram))
  need_instances=$((need_instances + missing))
  summary+=("${role}: missing=${missing} flavor=${flavor} cores=${role_cores} ram_mb=${role_ram}")
done

if [[ "$need_instances" -eq 0 ]]; then
  echo "quota preflight: all requested servers already exist for ${prefix}"
  exit 0
fi

available_cores=999999999
available_ram=999999999
available_instances=999999999
[[ "$max_cores" -lt 0 ]] || available_cores=$((max_cores - used_cores))
[[ "$max_ram" -lt 0 ]] || available_ram=$((max_ram - used_ram))
[[ "$max_instances" -lt 0 ]] || available_instances=$((max_instances - used_instances))

echo "quota preflight demand for ${prefix}: instances=${need_instances} cores=${need_cores} ram_mb=${need_ram}"
printf '  %s\n' "${summary[@]}"
echo "quota preflight available: instances=${available_instances}/${max_instances} cores=${available_cores}/${max_cores} ram_mb=${available_ram}/${max_ram}"

if (( need_instances > available_instances || need_cores > available_cores || need_ram > available_ram )); then
  if [[ "$auto_expand_quota" == "true" ]]; then
    target_instances=$((used_instances + need_instances + quota_headroom_instances))
    target_cores=$((used_cores + need_cores + quota_headroom_cores))
    target_ram=$((used_ram + need_ram + quota_headroom_ram_mb))
    if [[ "$max_instances" -gt "$target_instances" ]]; then
      target_instances="$max_instances"
    fi
    if [[ "$max_cores" -gt "$target_cores" ]]; then
      target_cores="$max_cores"
    fi
    if [[ "$max_ram" -gt "$target_ram" ]]; then
      target_ram="$max_ram"
    fi

    echo "quota preflight auto-expanding local DevStack quota for project ${quota_project}: instances=${target_instances} cores=${target_cores} ram_mb=${target_ram}"
    openstack quota set \
      --instances "$target_instances" \
      --cores "$target_cores" \
      --ram "$target_ram" \
      "$quota_project"

    limits_json="$(openstack limits show --absolute -f json)"
    read -r max_cores used_cores max_ram used_ram max_instances used_instances < <(read_limits "$limits_json")
    available_cores=999999999
    available_ram=999999999
    available_instances=999999999
    [[ "$max_cores" -lt 0 ]] || available_cores=$((max_cores - used_cores))
    [[ "$max_ram" -lt 0 ]] || available_ram=$((max_ram - used_ram))
    [[ "$max_instances" -lt 0 ]] || available_instances=$((max_instances - used_instances))
    echo "quota preflight available after expansion: instances=${available_instances}/${max_instances} cores=${available_cores}/${max_cores} ram_mb=${available_ram}/${max_ram}"
  fi
fi

if (( need_instances > available_instances || need_cores > available_cores || need_ram > available_ram )); then
  cat >&2 <<EOF
OpenStack quota preflight failed before Terraform apply.
Requested missing resources for prefix '${prefix}' exceed remaining quota.
Destroy an existing stack, lower VM counts/flavors, or increase OpenStack quota before rerunning Actions.
EOF
  exit 1
fi

quota_project="${OS_PROJECT_NAME:-admin}"
fip_limit="$(openstack network quota show "$quota_project" -f value -c floatingip 2>/dev/null || true)"
if [[ "$fip_limit" =~ ^[0-9]+$ ]]; then
  used_fips="$(openstack floating ip list --project "$quota_project" -f value -c ID 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
  [[ "$used_fips" =~ ^[0-9]+$ ]] || used_fips=0
  available_fips=$(( fip_limit - used_fips ))
  echo "quota preflight floating IPs: available=${available_fips}/${fip_limit} need=${need_instances}"
  if (( need_instances > available_fips )); then
    if [[ "$auto_expand_quota" == "true" ]]; then
      target_fips=$(( used_fips + need_instances + quota_headroom_instances ))
      if [[ "$fip_limit" -gt "$target_fips" ]]; then
        target_fips="$fip_limit"
      fi
      echo "quota preflight auto-expanding Neutron floating IP quota for project ${quota_project}: floatingip=${target_fips}"
      openstack network quota set --floating-ip "$target_fips" "$quota_project"
      fip_limit="$(openstack network quota show "$quota_project" -f value -c floatingip 2>/dev/null || echo -1)"
      used_fips="$(openstack floating ip list --project "$quota_project" -f value -c ID 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
      [[ "$fip_limit" =~ ^[0-9]+$ ]] || fip_limit=-1
      [[ "$used_fips" =~ ^[0-9]+$ ]] || used_fips=0
      available_fips=$(( fip_limit - used_fips ))
      echo "quota preflight floating IPs after expansion: available=${available_fips}/${fip_limit}"
    fi
    if (( need_instances > available_fips )); then
      cat >&2 <<EOF
OpenStack quota preflight failed before Terraform apply.
Floating IP quota insufficient for project '${quota_project}': need ${need_instances}, available ${available_fips}/${fip_limit}.
Increase the Neutron floating IP quota or set HA_PRIVATE_CLOUD_AUTO_EXPAND_QUOTA=true.
EOF
      exit 1
    fi
  fi
fi
PREFLIGHT_OPENSTACK_QUOTA
}

ensure_openstack_user() {
  lxc exec ha-openstack -- sudo -u stack -H bash -s -- \
    "${HA_OPENSTACK_LOGIN_USERNAME}" \
    "${HA_OPENSTACK_LOGIN_PROJECT_NAME}" \
    "${HA_OPENSTACK_LOGIN_PASSWORD}" \
    "${HA_OPENSTACK_LOGIN_USER_DOMAIN_NAME}" \
    "${HA_OPENSTACK_LOGIN_PROJECT_DOMAIN_NAME}" <<'ENSURE_OPENSTACK_USER'
set -eo pipefail
target_username="$1"
target_project="$2"
target_password="$3"
target_user_domain="$4"
target_project_domain="$5"
cd /opt/stack/devstack
set +u
source openrc admin admin >/dev/null
set -u
openstack project show --domain "$target_project_domain" "$target_project" >/dev/null 2>&1 \
  || openstack project create --domain "$target_project_domain" "$target_project" >/dev/null
if openstack user show --domain "$target_user_domain" "$target_username" >/dev/null 2>&1; then
  openstack user set --domain "$target_user_domain" --password "$target_password" "$target_username"
else
  openstack user create --domain "$target_user_domain" --password "$target_password" "$target_username" >/dev/null
fi
if [[ "$target_username" != "admin" ]]; then
  openstack role add --project "$target_project" --project-domain "$target_project_domain" --user "$target_username" --user-domain "$target_user_domain" member
fi
ENSURE_OPENSTACK_USER
}

openstack_user_sync_enabled() {
  case "${HA_PRIVATE_CLOUD_SYNC_OPENSTACK_USER}" in
    true)
      return 0
      ;;
    false)
      return 1
      ;;
    auto)
      if [[ -n "${GITHUB_RUN_ID:-}" || -n "${HA_CI_COMMAND:-}" ]]; then
        return 0
      fi
      if [[ "${HA_OPENSTACK_LOGIN_USERNAME}" != "admin" || "${HA_OPENSTACK_LOGIN_PROJECT_NAME}" != "admin" ]]; then
        return 0
      fi
      return 1
      ;;
    *)
      printf 'HA_PRIVATE_CLOUD_SYNC_OPENSTACK_USER must be true, false, or auto; got: %s\n' "${HA_PRIVATE_CLOUD_SYNC_OPENSTACK_USER}" >&2
      return 2
      ;;
  esac
}

verify_openstack_login_user() {
  local auth_url

  auth_url="${HA_DEVSTACK_AUTH_URL:-http://127.0.0.1:18081/identity/v3}"
  OS_AUTH_URL="${auth_url}" \
  OS_USERNAME="${HA_OPENSTACK_LOGIN_USERNAME}" \
  OS_PASSWORD="${HA_OPENSTACK_LOGIN_PASSWORD}" \
  OS_PROJECT_NAME="${HA_OPENSTACK_LOGIN_PROJECT_NAME}" \
  OS_USER_DOMAIN_NAME="${HA_OPENSTACK_LOGIN_USER_DOMAIN_NAME}" \
  OS_PROJECT_DOMAIN_NAME="${HA_OPENSTACK_LOGIN_PROJECT_DOMAIN_NAME}" \
  OS_REGION_NAME="${OS_REGION_NAME}" \
  OS_IDENTITY_API_VERSION="${OS_IDENTITY_API_VERSION:-3}" \
    check_openstack_auth
}

sync_openstack_login_user() {
  if ! openstack_user_sync_enabled; then
    log "SKIP OpenStack login user sync"
    return 0
  fi

  [[ -n "${HA_OPENSTACK_LOGIN_PASSWORD}" ]] || {
    printf 'OpenStack login user sync requires HA_OPENSTACK_LOGIN_PASSWORD or OS_PASSWORD\n' >&2
    return 1
  }

  log "syncing OpenStack login user ${HA_OPENSTACK_LOGIN_USERNAME}/${HA_OPENSTACK_LOGIN_PROJECT_NAME}"
  ensure_openstack_user
  verify_openstack_login_user
}

ensure_devstack_egress() {
  lxc exec ha-openstack -- sudo -u stack -H bash -s <<'LOOKUP_PUBLIC_EGRESS' >"${LOG_DIR}/public-egress.env"
set -eo pipefail
cd /opt/stack/devstack
set +u
source openrc admin admin >/dev/null
set -u
public_subnet_id="$(openstack subnet list --network public --ip-version 4 -f value -c ID | head -n 1)"
[[ -n "$public_subnet_id" ]] || exit 0
public_cidr="$(openstack subnet show "$public_subnet_id" -f value -c cidr)"
public_gateway="$(openstack subnet show "$public_subnet_id" -f value -c gateway_ip)"
[[ -n "$public_cidr" && -n "$public_gateway" && "$public_gateway" != "None" ]] || exit 0
prefix="${public_cidr#*/}"
printf 'public_cidr=%s\n' "$public_cidr"
printf 'public_gateway_cidr=%s/%s\n' "$public_gateway" "$prefix"
LOOKUP_PUBLIC_EGRESS
  # shellcheck disable=SC1090
  source "${LOG_DIR}/public-egress.env" || true
  [[ -n "${public_cidr:-}" && -n "${public_gateway_cidr:-}" ]] || return 0
  lxc exec ha-openstack -- bash -s -- "${public_cidr}" "${public_gateway_cidr}" <<'ENSURE_PUBLIC_EGRESS'
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
ENSURE_PUBLIC_EGRESS
}

verify_devstack() {
  local attempt

  for attempt in {1..60}; do
    if lxc exec ha-openstack -- curl -fsS http://localhost/identity/v3 2>/dev/null | grep -q "v3.14" \
      && lxc exec ha-openstack -- sudo -u stack -H bash -lc 'cd /opt/stack/devstack && set +u && source openrc admin admin >/dev/null && openstack token issue -f value -c id >/dev/null' 2>/dev/null; then
      return 0
    fi
    if [[ "$attempt" -eq 1 ]]; then
      log "waiting for DevStack API readiness"
    fi
    sleep 5
  done

  printf 'DevStack API did not become ready; rerun with run_mode=reinstall if services are not recoverable.\n' >&2
  return 1
}

ensure_horizon_proxy() {
  lxc config device remove ha-openstack horizon-proxy >/dev/null 2>&1 || true
  lxc config device add ha-openstack horizon-proxy proxy listen=tcp:127.0.0.1:18081 connect=tcp:127.0.0.1:80 >/dev/null
}

configure_horizon_proxy_settings() {
  local horizon_domain
  horizon_domain="openstack.${PRIVATE_CLOUD_BASE_DOMAIN}"
  lxc exec ha-openstack -- bash -s -- "${horizon_domain}" <<'CONFIGURE_HORIZON'
set -euo pipefail
horizon_domain="$1"
settings="/opt/stack/horizon/openstack_dashboard/local/local_settings.py"
python3 - "$settings" "$horizon_domain" <<'PY'
import sys

settings, horizon_domain = sys.argv[1], sys.argv[2]
begin = "# BEGIN hybrid-ai Horizon proxy settings"
end = "# END hybrid-ai Horizon proxy settings"
with open(settings, "r", encoding="utf-8") as handle:
    content = handle.read()
if begin in content and end in content:
    before, rest = content.split(begin, 1)
    _, after = rest.split(end, 1)
    content = before + after.lstrip("\n")
origins = [
    f"http://{horizon_domain}",
    f"https://{horizon_domain}",
    "http://127.0.0.1:18081",
    "http://localhost:18081",
]
block = f"""
{begin}
USE_X_FORWARDED_HOST = True
SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")
CSRF_TRUSTED_ORIGINS = {origins!r}
{end}
"""
with open(settings, "w", encoding="utf-8") as handle:
    handle.write(content.rstrip() + "\n" + block.lstrip())
PY
systemctl reload apache2
CONFIGURE_HORIZON
}

devstack_reinstall() {
  local product_id
  create_devstack_container
  install_devstack_prereqs
  product_id="$(detect_gpu_product)"
  bind_gpu_vfio "${product_id}"
  clone_and_configure_devstack "${product_id}"
  run_devstack
  ensure_flavors
  configure_gpu_passthrough
  ensure_images
  sync_openstack_login_user
  ensure_devstack_egress
  ensure_horizon_proxy
  configure_horizon_proxy_settings
  verify_devstack
}

devstack_apply_check() {
  local product_id
  ensure_devstack_container_running
  verify_devstack
  sync_openstack_login_user
  configure_lxc_devices
  product_id="$(detect_gpu_product)"
  bind_gpu_vfio "${product_id}"
  configure_vfio_guest_access
  ensure_flavors
  configure_gpu_passthrough
  if [[ -z "${product_id}" && "${TF_VAR_gpu_worker_count:-0}" != "0" ]]; then
    log "warning: gpu_worker_count=${TF_VAR_gpu_worker_count} but no NVIDIA GPU detected in the LXC container — GPU workers will be created without PCI passthrough"
  fi
  ensure_devstack_egress
  ensure_horizon_proxy
  configure_horizon_proxy_settings
  verify_devstack
}

devstack_openrc_password() {
  command -v lxc >/dev/null 2>&1 || return 0
  lxc exec ha-openstack -- sudo -u stack -H bash -lc 'cd /opt/stack/devstack && set +u && source openrc admin admin >/dev/null && printf "%s" "${OS_PASSWORD:-}"' 2>/dev/null || true
}

use_local_devstack_openstack_env() {
  export OS_AUTH_URL="${HA_DEVSTACK_AUTH_URL:-http://127.0.0.1:18081/identity/v3}"
  export OS_USERNAME="${HA_DEVSTACK_USERNAME:-admin}"
  local devstack_password
  local openrc_password

  devstack_password="${HA_DEVSTACK_PASSWORD:-hybrid-ai-devstack}"
  openrc_password="$(devstack_openrc_password)"
  if [[ -n "$openrc_password" ]]; then
    devstack_password="$openrc_password"
  fi
  if [[ "${HA_OPENSTACK_LOGIN_USERNAME}" == "${HA_DEVSTACK_USERNAME:-admin}" \
    && "${HA_OPENSTACK_LOGIN_PROJECT_NAME}" == "${HA_DEVSTACK_PROJECT_NAME:-admin}" \
    && "${HA_OPENSTACK_LOGIN_USER_DOMAIN_NAME}" == "${HA_DEVSTACK_USER_DOMAIN_NAME:-Default}" \
    && "${HA_OPENSTACK_LOGIN_PROJECT_DOMAIN_NAME}" == "${HA_DEVSTACK_PROJECT_DOMAIN_NAME:-Default}" \
    && "${HA_OPENSTACK_LOGIN_PASSWORD_INPUT_PROVIDED}" == "true" ]]; then
    devstack_password="${HA_OPENSTACK_LOGIN_PASSWORD}"
  fi
  export OS_PASSWORD="$devstack_password"
  export OS_PROJECT_NAME="${HA_DEVSTACK_PROJECT_NAME:-admin}"
  export OS_USER_DOMAIN_NAME="${HA_DEVSTACK_USER_DOMAIN_NAME:-Default}"
  export OS_PROJECT_DOMAIN_NAME="${HA_DEVSTACK_PROJECT_DOMAIN_NAME:-Default}"
  export OS_REGION_NAME="${HA_DEVSTACK_REGION_NAME:-RegionOne}"
  export OS_IDENTITY_API_VERSION="${OS_IDENTITY_API_VERSION:-3}"
}

check_openstack_auth() {
  python3 - <<'PY'
import json
import os
import sys
import urllib.error
import urllib.request

required = [
    "OS_AUTH_URL",
    "OS_USERNAME",
    "OS_PASSWORD",
    "OS_PROJECT_NAME",
    "OS_USER_DOMAIN_NAME",
    "OS_PROJECT_DOMAIN_NAME",
]
missing = [name for name in required if not os.environ.get(name)]
if missing:
    print(f"OpenStack auth preflight failed: missing {', '.join(missing)}", file=sys.stderr)
    sys.exit(1)

auth_url = os.environ["OS_AUTH_URL"].rstrip("/")
url = f"{auth_url}/auth/tokens"
username = os.environ["OS_USERNAME"]
project = os.environ["OS_PROJECT_NAME"]
user_domain = os.environ["OS_USER_DOMAIN_NAME"]
project_domain = os.environ["OS_PROJECT_DOMAIN_NAME"]
payload = {
    "auth": {
        "identity": {
            "methods": ["password"],
            "password": {
                "user": {
                    "name": username,
                    "domain": {"name": user_domain},
                    "password": os.environ["OS_PASSWORD"],
                }
            },
        },
        "scope": {
            "project": {
                "name": project,
                "domain": {"name": project_domain},
            }
        },
    }
}
req = urllib.request.Request(
    url,
    data=json.dumps(payload).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST",
)
try:
    with urllib.request.urlopen(req, timeout=20) as response:
        if response.status not in (201, 202):
            print(f"OpenStack auth preflight failed: HTTP {response.status} for {url}", file=sys.stderr)
            sys.exit(1)
except urllib.error.HTTPError as exc:
    body = exc.read().decode("utf-8", "replace")[:500]
    print(
        "OpenStack auth preflight failed: "
        f"HTTP {exc.code} for {url} user={username} project={project} "
        f"user_domain={user_domain} project_domain={project_domain}: {body}",
        file=sys.stderr,
    )
    sys.exit(1)
except Exception as exc:
    print(
        "OpenStack auth preflight failed: "
        f"{exc} for {url} user={username} project={project} "
        f"user_domain={user_domain} project_domain={project_domain}",
        file=sys.stderr,
    )
    sys.exit(1)
PY
}

local_backend_state_path() {
  local backend_hcl="$1"

  [[ "${TF_BACKEND_TYPE:-local}" == "local" ]] || return 1
  awk '
    /^[[:space:]]*path[[:space:]]*=/ {
      sub(/^[^=]*=/, "", $0)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
      gsub(/^"|"$/, "", $0)
      print $0
      exit
    }
  ' "$backend_hcl"
}

prepare_noninteractive_backend_init() {
  local module_dir="$1"
  local backend_hcl="$2"
  local backend_path
  local archive_dir

  backend_path="$(local_backend_state_path "$backend_hcl" || true)"
  [[ -n "$backend_path" ]] || return 1
  if [[ "$backend_path" != /* ]]; then
    backend_path="${module_dir}/${backend_path}"
  fi

  mkdir -p "$(dirname "$backend_path")"
  rm -f "${module_dir}/.terraform/terraform.tfstate"

  if [[ -s "$backend_path" ]]; then
    if [[ -s "${module_dir}/terraform.tfstate" ]]; then
      archive_dir="${ROOT}/.ha/openstack/state-archive/$(date -u +%Y%m%dT%H%M%SZ)"
      mkdir -p "$archive_dir"
      mv "${module_dir}/terraform.tfstate" "${archive_dir}/terraform.tfstate"
      log "archived stale root Terraform state before backend reconfigure: ${archive_dir}/terraform.tfstate"
    fi
    return 0
  fi

  return 1
}

terraform_apply() {
  local effective_build_worker_count effective_gpu_worker_count effective_gitlab_count effective_harbor_count
  local effective_install_node_dependencies
  local effective_control_plane_flavor effective_build_worker_flavor effective_gpu_worker_flavor effective_gitlab_flavor effective_harbor_flavor
  local key_pair_name
  local apply_prefix
  ensure_ssh_key
  cd "${ROOT}/private/openstack"
  rm -f backend.generated.tf backend.hcl private-cloud.auto.tfvars zz-local-devstack.auto.tfvars private-cloud.tfplan
  use_local_devstack_openstack_env
  load_cached_image_overrides
  check_openstack_auth
  export TF_VAR_ssh_public_key
  TF_VAR_ssh_public_key="$(cat "${SSH_KEY}.pub")"
  export TF_VAR_control_plane_image_name TF_VAR_build_worker_image_name TF_VAR_gpu_worker_image_name TF_VAR_gitlab_image_name
  export TF_VAR_harbor_image_name
  export TF_VAR_control_plane_flavor_name TF_VAR_build_worker_flavor_name TF_VAR_gpu_worker_flavor_name
  export TF_VAR_gitlab_flavor_name TF_VAR_harbor_flavor_name
  export TF_VAR_gpu_worker_count TF_VAR_gitlab_count TF_VAR_harbor_count TF_VAR_gitlab_container_image
  if [[ -n "${PRIVATE_CLOUD_TFVARS:-}" ]]; then
    printf '%s' "${PRIVATE_CLOUD_TFVARS}" > private-cloud.auto.tfvars
  fi
  apply_prefix="$(terraform_apply_prefix)"
  effective_build_worker_count="$(effective_worker_count build_worker_count "${TF_VAR_build_worker_count}" "$apply_prefix")"
  effective_gpu_worker_count="$(effective_worker_count gpu_worker_count "${TF_VAR_gpu_worker_count}" "$apply_prefix")"
  effective_gitlab_count="$(effective_worker_count gitlab_count "${TF_VAR_gitlab_count}" "$apply_prefix")"
  effective_harbor_count="$(effective_worker_count harbor_count "${TF_VAR_harbor_count}" "$apply_prefix")"
  effective_control_plane_flavor="$(terraform_var_value control_plane_flavor_name "${TF_VAR_control_plane_flavor_name}" private-cloud.auto.tfvars)"
  effective_build_worker_flavor="$(terraform_var_value build_worker_flavor_name "${TF_VAR_build_worker_flavor_name}" private-cloud.auto.tfvars)"
  effective_gpu_worker_flavor="$(terraform_var_value gpu_worker_flavor_name "${TF_VAR_gpu_worker_flavor_name}" private-cloud.auto.tfvars)"
  effective_gitlab_flavor="$(terraform_var_value gitlab_flavor_name "${TF_VAR_gitlab_flavor_name}" private-cloud.auto.tfvars)"
  effective_harbor_flavor="$(terraform_var_value harbor_flavor_name "${TF_VAR_harbor_flavor_name}" private-cloud.auto.tfvars)"
  effective_install_node_dependencies="$(terraform_var_value install_node_dependencies true private-cloud.auto.tfvars)"
  if [[ -n "${PRIVATE_CLOUD_TFVARS:-}" && "$apply_prefix" == *-actions ]]; then
    if ! terraform_tfvars_has_var install_node_dependencies private-cloud.auto.tfvars; then
      effective_install_node_dependencies="false"
    fi
  fi
  public_network_id="$(lxc exec ha-openstack -- sudo -u stack -H bash -lc 'cd /opt/stack/devstack && set +u && source openrc admin admin >/dev/null && set -u && openstack network show public -f value -c id')"
  public_subnet_id="$(lxc exec ha-openstack -- sudo -u stack -H bash -lc 'cd /opt/stack/devstack && set +u && source openrc admin admin >/dev/null && set -u && openstack subnet list --network public --ip-version 4 -f value -c ID | head -n 1')"
  public_subnet_cidr="$(lxc exec ha-openstack -- sudo -u stack -H bash -lc "cd /opt/stack/devstack && set +u && source openrc admin admin >/dev/null && set -u && openstack subnet show '${public_subnet_id}' -f value -c cidr")"
  {
    printf 'external_network_id = "%s"\n' "$public_network_id"
    printf 'floating_ip_pool = "public"\n'
    printf 'assign_floating_ips = true\n'
    printf 'install_node_dependencies = %s\n' "${effective_install_node_dependencies}"
    printf 'ssh_allowed_cidrs = ["%s"]\n' "$public_subnet_cidr"
    printf 'gitlab_http_allowed_cidrs = ["%s"]\n' "$public_subnet_cidr"
    printf 'control_plane_image_name = "%s"\n' "${TF_VAR_control_plane_image_name}"
    printf 'control_plane_flavor_name = "%s"\n' "${effective_control_plane_flavor}"
    printf 'build_worker_count = %s\n' "${effective_build_worker_count}"
    printf 'build_worker_image_name = "%s"\n' "${TF_VAR_build_worker_image_name}"
    printf 'build_worker_flavor_name = "%s"\n' "${effective_build_worker_flavor}"
    printf 'gpu_worker_count = %s\n' "${effective_gpu_worker_count}"
    printf 'gpu_worker_image_name = "%s"\n' "${TF_VAR_gpu_worker_image_name}"
    printf 'gpu_worker_flavor_name = "%s"\n' "${effective_gpu_worker_flavor}"
    printf 'gitlab_count = %s\n' "${effective_gitlab_count}"
    printf 'gitlab_image_name = "%s"\n' "${TF_VAR_gitlab_image_name}"
    printf 'gitlab_flavor_name = "%s"\n' "${effective_gitlab_flavor}"
    printf 'gitlab_container_image = "%s"\n' "${TF_VAR_gitlab_container_image}"
    printf 'harbor_count = %s\n' "${effective_harbor_count}"
    printf 'harbor_image_name = "%s"\n' "${TF_VAR_harbor_image_name}"
    printf 'harbor_flavor_name = "%s"\n' "${effective_harbor_flavor}"
    printf 'harbor_http_allowed_cidrs = ["%s"]\n' "$public_subnet_cidr"
  } >zz-local-devstack.auto.tfvars
  cleanup_openstack_orphans_before_apply
  preflight_openstack_quota
  local backend_config="${TF_BACKEND_CONFIG:-}"
  local backend_config_compact="${backend_config//[[:space:]]/}"

  if [[ "$REQUIRE_BACKEND_CONFIG" == "true" && -z "$backend_config_compact" ]]; then
    echo "TF_BACKEND_CONFIG is required when --require-backend-config is set" >&2
    exit 1
  fi

  if [[ -n "$backend_config_compact" ]]; then
    printf 'terraform {\n  backend "%s" {}\n}\n' "${TF_BACKEND_TYPE:-local}" > backend.generated.tf
    printf '%s' "$backend_config" > backend.hcl
    if prepare_noninteractive_backend_init "$PWD" "${PWD}/backend.hcl"; then
      terraform init -input=false -reconfigure -backend-config=backend.hcl
    else
      terraform init -input=false -migrate-state -force-copy -backend-config=backend.hcl
    fi
  else
    rm -f .terraform/terraform.tfstate
    terraform init -input=false -reconfigure
  fi
  legacy_addresses="$(terraform state list 2>/dev/null | grep '^openstack_compute_floatingip_associate_v2\.' || true)"
  if [[ -n "${legacy_addresses}" ]]; then
    while IFS= read -r address; do
      [[ -n "${address}" ]] && terraform state rm "${address}"
    done <<<"${legacy_addresses}"
  fi
  guard_unmanaged_openstack_stack "$apply_prefix"
  key_pair_name="$(terraform_var_value key_pair_name hybrid-ai-private-admin private-cloud.auto.tfvars zz-local-devstack.auto.tfvars)"
  if ! terraform state show -no-color openstack_compute_keypair_v2.admin >/dev/null 2>&1; then
    terraform import openstack_compute_keypair_v2.admin "${key_pair_name}" >/dev/null 2>&1 || true
  fi
  terraform plan -input=false -out=private-cloud.tfplan
  terraform apply -input=false -parallelism="${HA_TERRAFORM_APPLY_PARALLELISM}" -auto-approve private-cloud.tfplan
  terraform output -json >"${TF_OUTPUT_JSON}"
}

wait_one_node_ssh() {
  local ip="$1"
  local name="$2"
  local ready=false
  local deadline=$((SECONDS + 900))

  while (( SECONDS < deadline )); do
    if ssh -F "${SSH_CONFIG}" -n -o ConnectTimeout=10 "${ip}" 'true' 2>/dev/null; then
      ready=true
      break
    fi
    sleep 10
  done
  [[ "${ready}" == "true" ]] || { echo "${name} (${ip}) did not become SSH-ready" >&2; return 1; }
}

wait_nodes_ssh() {
  write_ssh_config
  python3 - "${TF_OUTPUT_JSON}" >"${LOG_DIR}/node-inventory.txt" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)
for key in ("control_plane_nodes", "build_worker_nodes", "gpu_worker_nodes"):
    for node in data.get(key, {}).get("value", []):
        ip = node.get("floating_ip") or node.get("private_ip")
        if ip:
            print(ip, node.get("name", ""))
PY
  [[ -s "${LOG_DIR}/node-inventory.txt" ]] || { echo "node inventory is empty" >&2; return 1; }
  local pids=()
  local pid
  local rc=0
  while IFS=' ' read -r ip name; do
    ( wait_one_node_ssh "$ip" "$name" ) &
    pids+=("$!")
  done <"${LOG_DIR}/node-inventory.txt"
  for pid in "${pids[@]}"; do
    wait "$pid" || rc=1
  done
  return "$rc"
}

first_control_plane_ip() {
  python3 - "${TF_OUTPUT_JSON}" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)
nodes = data.get("control_plane_nodes", {}).get("value", [])
if nodes:
    print(nodes[0].get("floating_ip") or nodes[0].get("private_ip") or "")
PY
}

first_gitlab_ip() {
  python3 - "${TF_OUTPUT_JSON}" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)
nodes = data.get("gitlab_nodes", {}).get("value", [])
if nodes:
    print(nodes[0].get("floating_ip") or nodes[0].get("private_ip") or "")
PY
}

first_harbor_ip() {
  python3 - "${TF_OUTPUT_JSON}" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)
nodes = data.get("harbor_nodes", {}).get("value", [])
if nodes:
    print(nodes[0].get("floating_ip") or nodes[0].get("private_ip") or "")
PY
}

start_kubectl_tunnel() {
  local first_cp_ip
  first_cp_ip="$(first_control_plane_ip)"
  [[ -n "${first_cp_ip}" ]] || return 1
  pgrep -f "ssh .*127.0.0.1:${HA_KUBECTL_TUNNEL_PORT}:127.0.0.1:6443" | xargs -r kill || true
  ssh -F "${SSH_CONFIG}" -fN -L "127.0.0.1:${HA_KUBECTL_TUNNEL_PORT}:127.0.0.1:6443" "${first_cp_ip}"
}

bootstrap_k8s() {
  wait_nodes_ssh
  export HA_OPENSTACK_TF_OUTPUT_JSON="${TF_OUTPUT_JSON}"
  export HA_OPENSTACK_SSH_KEY="${SSH_KEY}"
  export HA_OPENSTACK_SSH_PROXY_CONTAINER="ha-openstack"
  export HA_OPENSTACK_SSH_TARGET="auto"
  export HA_OPENSTACK_KUBECONFIG="${KUBECONFIG_PATH}"
  export HA_K8S_API_ENDPOINT="127.0.0.1:${HA_KUBECTL_TUNNEL_PORT}"
  export HA_K8S_VERSION_MINOR="${HA_K8S_VERSION_MINOR:-v1.36}"
  export HA_K8S_POD_CIDR="${HA_K8S_POD_CIDR:-192.168.0.0/16}"
  export HA_K8S_CNI_MANIFEST="${HA_K8S_CNI_MANIFEST:-https://raw.githubusercontent.com/projectcalico/calico/v3.32.0/manifests/calico.yaml}"
  "${ROOT}/private/kubernetes-bootstrap/bootstrap-k8s.sh"
  start_kubectl_tunnel
  export KUBECONFIG="${KUBECONFIG_PATH}"
  kubectl get --raw='/readyz?verbose'
  kubectl get nodes -o wide
  kubectl -n kube-system rollout status daemonset/calico-node --timeout=600s
  kubectl -n kube-system rollout status deployment/calico-kube-controllers --timeout=600s
  kubectl -n kube-system rollout status deployment/coredns --timeout=600s
  kubectl apply -k "${ROOT}/private/kubernetes"
}

storage_inputs_env() {
  python3 - "${TF_OUTPUT_JSON}" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)
control_nodes = data.get("control_plane_nodes", {}).get("value", [])
if not control_nodes:
    raise SystemExit("missing control_plane_nodes")
nfs_server_ip = data.get("nfs_server_ip", {}).get("value")
private_network_cidr = data.get("private_network_cidr", {}).get("value")
nfs_ssh_ip = control_nodes[0].get("floating_ip") or control_nodes[0].get("private_ip")
print(f"NFS_SERVER_IP={nfs_server_ip}")
print(f"PRIVATE_NETWORK_CIDR={private_network_cidr}")
print(f"NFS_SSH_IP={nfs_ssh_ip}")
PY
}

prepare_nfs_server() {
  # shellcheck disable=SC1090
  source "${LOG_DIR}/storage.env"
  ssh -F "${SSH_CONFIG}" "${NFS_SSH_IP}" bash -s -- "${PRIVATE_NETWORK_CIDR}" <<'REMOTE'
set -euo pipefail
cidr="$1"
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
host="$(hostname)"
short="$(hostname -s)"
if ! grep -Eq "(^|[[:space:]])${short}([[:space:]]|$)" /etc/hosts; then
  printf '127.0.1.1 %s %s\n' "$host" "$short" | sudo tee -a /etc/hosts >/dev/null
fi
apt_get() {
  sudo apt-get \
    -o Acquire::ForceIPv4=true \
    -o Acquire::Retries=5 \
    -o Dpkg::Lock::Timeout=900 \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confnew \
    "$@"
}
if command -v cloud-init >/dev/null 2>&1; then
  cloud-init status --wait >/dev/null 2>&1 || true
fi
for _ in {1..180}; do
  if ! sudo fuser /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
if ! sudo test -x /usr/sbin/exportfs; then
  apt_get update -qq
  apt_get install -y -qq nfs-common nfs-kernel-server
fi
sudo mkdir -p /mnt/nfs/hybrid-ai /etc/exports.d
sudo chown nobody:nogroup /mnt/nfs/hybrid-ai
sudo chmod 0777 /mnt/nfs/hybrid-ai
printf '/mnt/nfs/hybrid-ai %s(rw,sync,no_subtree_check,no_root_squash)\n' "$cidr" | sudo tee /etc/exports.d/hybrid-ai.exports >/dev/null
sudo /usr/sbin/exportfs -ra
sudo systemctl enable --now nfs-server 2>/dev/null || sudo systemctl enable --now nfs-kernel-server
REMOTE
}

setup_storage() {
  write_ssh_config
  start_kubectl_tunnel
  export KUBECONFIG="${KUBECONFIG_PATH}"
  storage_inputs_env >"${LOG_DIR}/storage.env"
  prepare_nfs_server
  kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.31/deploy/local-path-storage.yaml
  kubectl -n local-path-storage rollout status deployment/local-path-provisioner --timeout=600s
  kubectl get storageclass local-path
  values_file="${LOG_DIR}/minio-operator-values.yaml"
  cat >"${values_file}" <<'VALUES'
operator:
  replicaCount: 1
  resources:
    requests:
      memory: 256Mi
      cpu: 100m
    limits:
      memory: 512Mi
      cpu: 500m
VALUES
  helm repo add minio-operator https://operator.min.io/
  helm repo update
  helm upgrade --install minio-operator minio-operator/operator \
    --namespace minio-operator --create-namespace --version 7.1.1 \
    --values "${values_file}" --wait --timeout 10m
  kubectl wait --for=condition=Established crd/tenants.minio.min.io --timeout=300s
  kubectl -n minio-operator rollout status deployment/minio-operator --timeout=600s
  kubectl create namespace minio-tenant --dry-run=client -o yaml | kubectl apply -f -
  existing_minio_root_user="$(kubectl -n minio-tenant get secret minio-creds-secret -o jsonpath='{.data.accessKey}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  existing_minio_root_password="$(kubectl -n minio-tenant get secret minio-creds-secret -o jsonpath='{.data.secretKey}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  minio_root_user="${MINIO_ROOT_USER:-${existing_minio_root_user:-minioadmin}}"
  minio_root_password="${MINIO_ROOT_PASSWORD:-${existing_minio_root_password:-}}"
  if [[ -z "${minio_root_password}" ]]; then
    if [[ -z "${MINIO_ROOT_PASSWORD}" ]]; then
      log "warning: MINIO_ROOT_PASSWORD is not set and no existing MinIO credentials found — generating a random password; set MINIO_ROOT_PASSWORD to preserve access across cluster reprovisioning"
    fi
    minio_root_password="$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(36))
PY
)"
  fi
  printf -v minio_config_env '%s\n%s\n%s' \
    "export MINIO_ROOT_USER=\"${minio_root_user}\"" \
    "export MINIO_ROOT_PASSWORD=\"${minio_root_password}\"" \
    'export MINIO_BROWSER="on"'
  kubectl -n minio-tenant create secret generic minio-creds-secret --from-literal=accessKey="${minio_root_user}" --from-literal=secretKey="${minio_root_password}" --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n minio-tenant create secret generic model-admin --from-literal=CONSOLE_ACCESS_KEY="${minio_root_user}" --from-literal=CONSOLE_SECRET_KEY="${minio_root_password}" --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n minio-tenant create secret generic minio-configuration --from-literal=config.env="${minio_config_env}" --dry-run=client -o yaml | kubectl apply -f -
  sed -E "s/storage: [0-9]+Gi/storage: ${MINIO_VOLUME_SIZE}Gi/g" "${ROOT}/private/storage/minio-tenant.yaml" | kubectl apply -f -
  for _ in {1..60}; do
    pod_count="$(kubectl get pods -n minio-tenant -l v1.min.io/tenant=hybrid-ai --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')"
    [[ "${pod_count:-0}" -gt 0 ]] && break
    sleep 10
  done
  for _ in {1..60}; do
    if kubectl get pods -n minio-tenant -l v1.min.io/tenant=hybrid-ai -o json | python3 -c '
import json, sys
pods = json.load(sys.stdin).get("items", [])
if not pods:
    sys.exit(1)
for pod in pods:
    statuses = {s.get("name"): s for s in pod.get("status", {}).get("containerStatuses", [])}
    if not statuses.get("minio", {}).get("ready"):
        sys.exit(1)
'; then
      break
    fi
    sleep 10
  done
  # shellcheck disable=SC1090
  source "${LOG_DIR}/storage.env"
  nfs_values="${LOG_DIR}/nfs-values.yaml"
  cat >"${nfs_values}" <<VALUES
replicaCount: 1
storageClass:
  create: true
  name: private-nfs-rwx
  defaultClass: false
  reclaimPolicy: Retain
  allowVolumeExpansion: true
  archiveOnDelete: false
  pathPattern: "\${.PVC.namespace}/\${.PVC.name}"
nfs:
  server: ${NFS_SERVER_IP}
  path: /mnt/nfs/hybrid-ai
  mountOptions:
    - hard
    - intr
    - rsize=1048576
    - wsize=1048576
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 256Mi
VALUES
  helm repo add nfs-subdir-external-provisioner https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/
  helm repo update
  helm upgrade --install nfs-subdir-external-provisioner nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
    --namespace nfs-provisioner --create-namespace --version 4.0.18 --values "${nfs_values}" --wait --timeout 10m
  kubectl -n nfs-provisioner rollout status deployment/nfs-subdir-external-provisioner --timeout=600s
  kubectl apply -f "${ROOT}/private/kubernetes/namespaces.yaml"
  kubectl apply -k "${ROOT}/private/storage"
  for pvc in model-build-cache model-artifacts; do
    kubectl -n model-build wait --for=jsonpath='{.status.phase}'=Bound "pvc/${pvc}" --timeout=600s
  done
  kubectl get storageclass
  kubectl get pvc -A
}

setup_gitlab() {
  [[ "${GITLAB_INSTALL_ENABLED}" == "true" ]] || return 0
  local target registry_host
  write_ssh_config
  target="$(first_gitlab_ip)"
  [[ -n "${target}" ]] || return 0
  registry_host="registry-1.docker.io"
  if [[ "${GITLAB_IMAGE}" == */*/* ]]; then
    registry_host="${GITLAB_IMAGE%%/*}"
  fi
  for i in {1..90}; do
    if ssh -o ConnectTimeout=10 -F "${SSH_CONFIG}" "${target}" \
      "getent ahostsv4 archive.ubuntu.com >/dev/null && curl -4 -fsSI --max-time 15 http://archive.ubuntu.com/ubuntu/ >/dev/null && curl -4 -sSI --max-time 15 https://${registry_host}/v2/ >/dev/null"; then
      break
    fi
    (( i % 6 == 0 )) && ensure_devstack_egress
    sleep 10
  done
  ssh -F "${SSH_CONFIG}" "${target}" \
    "sudo install -m 0755 -o root -g root /dev/stdin /usr/local/sbin/hybrid-ai-gitlab-bootstrap" \
    <"${ROOT}/private/openstack/scripts/hybrid-ai-gitlab-bootstrap"
  ssh -F "${SSH_CONFIG}" "${target}" bash -s -- \
    "${GITLAB_EXTERNAL_URL}" \
    "${GITLAB_DOMAIN}" \
    "${GITLAB_IMAGE}" \
    "${GITLAB_SIGNUP_ENABLED}" \
    "${GITLAB_ADMIN_USERNAME}" \
    "${GITLAB_GPU_RUNNER_NAME_PREFIX}" \
    "${GITLAB_GPU_RUNNER_TAGS}" \
    "" \
    "5400" \
    "" <<'REMOTE'
set -euo pipefail
external_url="$1"
gitlab_domain="$2"
gitlab_image="$3"
gitlab_signup_enabled="$4"
gitlab_admin_username="${5:-root}"
runner_name_prefix="$6"
runner_tags="$7"
root_password_file="${8:-}"
gitlab_bootstrap_wait_seconds="${9:-5400}"
gitlab_image_archive_source="${10:-}"
sudo install -d -m 0700 /etc/hybrid-ai
sudo install -d -m 0755 /usr/local/sbin /var/lib/hybrid-ai/gitlab-bootstrap /var/cache/hybrid-ai/container-images
env_file_tmp="$(mktemp)"
write_env_line() {
  local name="$1" value="$2"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s="%s"\n' "$name" "$value" >> "$env_file_tmp"
}
write_env_line GITLAB_EXTERNAL_URL "$external_url"
write_env_line GITLAB_DOMAIN "$gitlab_domain"
write_env_line GITLAB_IMAGE "$gitlab_image"
write_env_line GITLAB_IMAGE_ARCHIVE_FILE ""
write_env_line GITLAB_SIGNUP_ENABLED "$gitlab_signup_enabled"
write_env_line GITLAB_ADMIN_USERNAME "$gitlab_admin_username"
write_env_line GITLAB_ROOT_PASSWORD_FILE /etc/hybrid-ai/gitlab-root-password
write_env_line GITLAB_GPU_RUNNER_NAME_PREFIX "$runner_name_prefix"
write_env_line GITLAB_GPU_RUNNER_TAGS "$runner_tags"
write_env_line GITLAB_BOOTSTRAP_WAIT_SECONDS "$gitlab_bootstrap_wait_seconds"
sudo install -m 0644 -o root -g root "$env_file_tmp" /etc/hybrid-ai/gitlab-bootstrap.env
rm -f "$env_file_tmp"
sudo tee /etc/systemd/system/hybrid-ai-gitlab-bootstrap.service >/dev/null <<'EOF'
[Unit]
Description=Hybrid AI GitLab bootstrap
After=network-online.target docker.service
Wants=network-online.target docker.service

[Service]
Type=oneshot
TimeoutStartSec=100min
EnvironmentFile=/etc/hybrid-ai/gitlab-bootstrap.env
ExecStart=/usr/local/sbin/hybrid-ai-gitlab-bootstrap
EOF
sudo systemctl daemon-reload
sudo systemctl disable --now hybrid-ai-gitlab-bootstrap.timer >/dev/null 2>&1 || true
sudo systemctl reset-failed hybrid-ai-gitlab-bootstrap.service >/dev/null 2>&1 || true
if ! sudo systemctl start hybrid-ai-gitlab-bootstrap.service; then
  echo "warning: GitLab bootstrap service did not complete on the first attempt" >&2
fi
wait_gitlab_local_web() {
  local deadline=$((SECONDS + 900))
  while (( SECONDS < deadline )); do
    if curl -fsS http://127.0.0.1/-/readiness >/dev/null 2>&1 || curl -fsS http://127.0.0.1/users/sign_in >/dev/null 2>&1; then
      return 0
    fi
    sleep 10
  done
  return 1
}
if sudo systemctl is-failed --quiet hybrid-ai-gitlab-bootstrap.service && wait_gitlab_local_web; then
  echo "GitLab web became ready after the first bootstrap attempt; retrying idempotent account/token setup"
  sudo systemctl reset-failed hybrid-ai-gitlab-bootstrap.service >/dev/null 2>&1 || true
  if ! sudo systemctl start hybrid-ai-gitlab-bootstrap.service; then
    echo "warning: GitLab bootstrap service retry did not complete" >&2
  fi
fi
sudo systemctl is-failed --quiet hybrid-ai-gitlab-bootstrap.service && {
  sudo systemctl status hybrid-ai-gitlab-bootstrap.service --no-pager || true
  sudo journalctl -u hybrid-ai-gitlab-bootstrap.service -n 200 --no-pager || true
  sudo cat /var/lib/hybrid-ai/gitlab-bootstrap/status.env 2>/dev/null || true
  exit 1
}
curl -fsS http://127.0.0.1/users/sign_in >/dev/null 2>&1 || curl -fsS http://127.0.0.1/-/readiness >/dev/null
sudo cat /var/lib/hybrid-ai/gitlab-bootstrap/status.env 2>/dev/null || true
REMOTE
  lxc config device remove ha-openstack gitlab-proxy >/dev/null 2>&1 || true
  lxc config device add ha-openstack gitlab-proxy proxy \
    "listen=tcp:127.0.0.1:${GITLAB_UPSTREAM_PORT}" \
    "connect=tcp:${target}:80" >/dev/null
  curl -fsS "http://127.0.0.1:${GITLAB_UPSTREAM_PORT}/users/sign_in" >/dev/null 2>&1 \
    || curl -fsS "http://127.0.0.1:${GITLAB_UPSTREAM_PORT}/-/readiness" >/dev/null
}

setup_harbor() {
  [[ "${HARBOR_INSTALL_ENABLED}" == "true" ]] || return 0
  local target admin_password_file harbor_env_file harbor_env_payload

  write_ssh_config
  target="$(first_harbor_ip)"
  [[ -n "${target}" ]] || return 0

  for i in {1..90}; do
    if ssh -o ConnectTimeout=10 -F "${SSH_CONFIG}" "${target}" \
      "getent ahostsv4 archive.ubuntu.com >/dev/null && curl -4 -fsSI --max-time 15 http://archive.ubuntu.com/ubuntu/ >/dev/null && curl -4 -fsSI --max-time 15 https://github.com/ >/dev/null"; then
      break
    fi
    (( i % 6 == 0 )) && ensure_devstack_egress
    sleep 10
  done

  admin_password_file=""
  if [[ -n "${HARBOR_ADMIN_PASSWORD}" ]]; then
    admin_password_file="/tmp/harbor-admin-password-${RUN_ID}"
    printf '%s' "${HARBOR_ADMIN_PASSWORD}" | ssh -F "${SSH_CONFIG}" "${target}" "umask 077 && cat > ${admin_password_file}"
  else
    log "warning: HARBOR_ADMIN_PASSWORD is not set — Harbor will generate a random admin password stored only on the VM; reprovisioning the VM will lose it"
  fi

  ssh -F "${SSH_CONFIG}" "${target}" \
    "sudo install -m 0755 -o root -g root /dev/stdin /usr/local/sbin/hybrid-ai-harbor-bootstrap" \
    <"${ROOT}/private/openstack/scripts/hybrid-ai-harbor-bootstrap"

  harbor_env_file="${LOG_DIR}/harbor-bootstrap.env"
  : >"${harbor_env_file}"
  write_systemd_env_line "${harbor_env_file}" HARBOR_DOMAIN "${HARBOR_DOMAIN}"
  write_systemd_env_line "${harbor_env_file}" HARBOR_EXTERNAL_URL "${HARBOR_EXTERNAL_URL}"
  write_systemd_env_line "${harbor_env_file}" HARBOR_VERSION "${HARBOR_VERSION}"
  write_systemd_env_line "${harbor_env_file}" HARBOR_PROJECTS "${HARBOR_PROJECTS}"
  write_systemd_env_line "${harbor_env_file}" HARBOR_ROBOT_NAME "${HARBOR_ROBOT_NAME}"
  write_systemd_env_line "${harbor_env_file}" HARBOR_HTTP_PORT "${HARBOR_HTTP_PORT}"
  write_systemd_env_line "${harbor_env_file}" HARBOR_BOOTSTRAP_WAIT_SECONDS "${HARBOR_BOOTSTRAP_WAIT_SECONDS}"
  harbor_env_payload="$(base64 <"${harbor_env_file}" | tr -d '\n')"

  ssh -F "${SSH_CONFIG}" "${target}" bash -s -- \
    "${harbor_env_payload}" \
    "${admin_password_file}" <<'REMOTE'
set -euo pipefail
harbor_env_payload="$1"
harbor_admin_password_file="${2:-}"

cleanup() {
  if [[ -n "$harbor_admin_password_file" ]]; then
    sudo rm -f "$harbor_admin_password_file" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

sudo install -d -m 0700 /etc/hybrid-ai
sudo install -d -m 0755 /usr/local/sbin /var/lib/hybrid-ai/harbor-bootstrap
installed_admin_password_file=""
if [[ -n "$harbor_admin_password_file" && -s "$harbor_admin_password_file" ]]; then
  installed_admin_password_file="/etc/hybrid-ai/harbor-admin-password"
  sudo install -m 0600 -o root -g root "$harbor_admin_password_file" "$installed_admin_password_file"
fi

env_file_tmp="$(mktemp)"
printf '%s' "$harbor_env_payload" | base64 -d >"$env_file_tmp"
append_env_line() {
  local name="$1" value="$2"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s="%s"\n' "$name" "$value" >> "$env_file_tmp"
}
append_env_line HARBOR_ADMIN_PASSWORD_FILE "$installed_admin_password_file"
sudo install -m 0644 -o root -g root "$env_file_tmp" /etc/hybrid-ai/harbor-bootstrap.env
rm -f "$env_file_tmp"

sudo tee /etc/systemd/system/hybrid-ai-harbor-bootstrap.service >/dev/null <<'EOF'
[Unit]
Description=Hybrid AI Harbor bootstrap
After=network-online.target docker.service
Wants=network-online.target docker.service

[Service]
Type=oneshot
TimeoutStartSec=80min
EnvironmentFile=/etc/hybrid-ai/harbor-bootstrap.env
ExecStart=/usr/local/sbin/hybrid-ai-harbor-bootstrap
EOF

sudo systemctl daemon-reload
sudo systemctl reset-failed hybrid-ai-harbor-bootstrap.service >/dev/null 2>&1 || true
if ! sudo systemctl start hybrid-ai-harbor-bootstrap.service; then
  sudo systemctl status hybrid-ai-harbor-bootstrap.service --no-pager || true
  sudo journalctl -u hybrid-ai-harbor-bootstrap.service -n 200 --no-pager || true
  sudo cat /var/lib/hybrid-ai/harbor-bootstrap/status.env 2>/dev/null || true
  exit 1
fi

source /etc/hybrid-ai/harbor-bootstrap.env
curl -fsS "http://127.0.0.1:${HARBOR_HTTP_PORT}/api/v2.0/ping" >/dev/null 2>&1 \
  || curl -fsS "http://127.0.0.1:${HARBOR_HTTP_PORT}/api/v2.0/health" >/dev/null
sudo cat /var/lib/hybrid-ai/harbor-bootstrap/status.env 2>/dev/null || true
REMOTE

  lxc config device remove ha-openstack harbor-proxy >/dev/null 2>&1 || true
  lxc config device add ha-openstack harbor-proxy proxy \
    "listen=tcp:127.0.0.1:${HARBOR_UPSTREAM_PORT}" \
    "connect=tcp:${target}:${HARBOR_HTTP_PORT}" >/dev/null
  curl -fsS "http://127.0.0.1:${HARBOR_UPSTREAM_PORT}/api/v2.0/ping" >/dev/null 2>&1 \
    || curl -fsS "http://127.0.0.1:${HARBOR_UPSTREAM_PORT}/api/v2.0/health" >/dev/null

  start_kubectl_tunnel
  export KUBECONFIG="${KUBECONFIG_PATH}"
  robot_json="$(ssh -F "${SSH_CONFIG}" "${target}" 'sudo cat /var/lib/hybrid-ai/harbor-bootstrap/kaniko-robot.json')"
  printf '%s\n' "${robot_json}" >"${LOG_DIR}/harbor-kaniko-robot.json"
  python3 - "${LOG_DIR}/harbor-kaniko-robot.json" "${HARBOR_EXTERNAL_URL}" >"${LOG_DIR}/harbor-kaniko-robot.env" <<'PY'
import json
import shlex
import sys
import urllib.parse

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    payload = json.load(handle)
external_url = sys.argv[2]
parsed = urllib.parse.urlparse(external_url if "://" in external_url else f"//{external_url}", scheme="https")
registry = parsed.netloc or parsed.path.split("/")[0]
name = payload.get("name", "")
token = payload.get("token", "")
if not registry or not name or not token:
    raise SystemExit("incomplete Harbor robot credentials")
print(f"HARBOR_REGISTRY_SERVER={shlex.quote(registry)}")
print(f"HARBOR_ROBOT_USERNAME={shlex.quote(name)}")
print(f"HARBOR_ROBOT_TOKEN={shlex.quote(token)}")
PY
  # shellcheck disable=SC1090
  source "${LOG_DIR}/harbor-kaniko-robot.env"
  kubectl create namespace model-build --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n model-build create secret docker-registry harbor-kaniko-push \
    --docker-server="${HARBOR_REGISTRY_SERVER}" \
    --docker-username="${HARBOR_ROBOT_USERNAME}" \
    --docker-password="${HARBOR_ROBOT_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f -
}

setup_model_build_platform() {
  start_kubectl_tunnel
  export KUBECONFIG="${KUBECONFIG_PATH}"
  kubectl apply -k "${ROOT}/private/kubernetes"
  if [[ "${ARGO_WORKFLOWS_INSTALL_ENABLED}" == "true" ]]; then
    kubectl create namespace argo --dry-run=client -o yaml | kubectl apply -f -
    kubectl apply -n argo -f "${ARGO_WORKFLOWS_INSTALL_MANIFEST}"
    for crd in workflows.argoproj.io workflowtemplates.argoproj.io cronworkflows.argoproj.io; do
      kubectl wait --for=condition=Established "crd/${crd}" --timeout=300s
    done
    kubectl -n argo rollout status deployment/workflow-controller --timeout=600s
    if kubectl -n argo get deployment argo-server >/dev/null 2>&1; then
      kubectl -n argo rollout status deployment/argo-server --timeout=600s
    fi
  fi
  kubectl apply -k "${ROOT}/private/kubernetes/model-build-workflows"
  kubectl -n model-build get workflowtemplate model-build-job model-package-job
}

validate_gpu_lightweight() {
  write_ssh_config
  start_kubectl_tunnel
  export KUBECONFIG="${KUBECONFIG_PATH}"
  kubectl get nodes -l hybrid-ai.io/accelerator=nvidia -o wide
  kubectl -n kube-system get pods -o wide
}

setup_registry_services_parallel() {
  local rc=0

  phase_bg setup_gitlab setup_gitlab
  phase_bg setup_harbor setup_harbor
  wait_phase_bg setup_gitlab || rc=1
  wait_phase_bg setup_harbor || rc=1
  return "$rc"
}

apply_jobs() {
  phase prepare_cached_images prepare_cached_images
  phase terraform_apply terraform_apply
  phase bootstrap_k8s bootstrap_k8s
  if optional_apply_phase_enabled "${HA_PRIVATE_CLOUD_SETUP_STORAGE}"; then
    phase setup_storage setup_storage
  else
    skip_phase setup_storage "disabled for lightweight Actions stack"
  fi
  if optional_apply_phase_enabled "${HA_PRIVATE_CLOUD_SETUP_REGISTRY}"; then
    phase setup_registry_services setup_registry_services_parallel
  else
    skip_phase setup_registry_services "disabled for lightweight Actions stack"
  fi
  if optional_apply_phase_enabled "${HA_PRIVATE_CLOUD_SETUP_MODEL_BUILD}"; then
    phase setup_model_build_platform setup_model_build_platform
  else
    skip_phase setup_model_build_platform "disabled for lightweight Actions stack"
  fi
  if [[ "${VALIDATE_GPU}" == "true" ]]; then
    phase validate_gpu_lightweight validate_gpu_lightweight
  fi
}

main() {
  case "${MODE}" in
    reinstall)
      phase require_tools require_tools
      phase devstack_reinstall devstack_reinstall
      apply_jobs
      ;;
    apply)
      phase require_tools require_tools
      phase devstack_apply_check devstack_apply_check
      apply_jobs
      ;;
    *)
      printf 'usage: %s [reinstall|apply]\n' "$0" >&2
      return 64
      ;;
  esac
  log "DONE ${MODE}; timings: ${TIMINGS}"
}

main "$@"
