#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODE="${HA_PRIVATE_CLOUD_RUN_MODE:-apply}"
VALIDATE_GPU="${HA_PRIVATE_CLOUD_VALIDATE_GPU:-false}"
PHASES="${HA_PRIVATE_CLOUD_PHASES:-all}"
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
    --phases)
      [[ $# -ge 2 ]] || { printf 'missing value for --phases\n' >&2; exit 64; }
      PHASES="$2"
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
      printf 'usage: ha apply [--run-mode apply|reinstall] [--phases tools|devstack|proxy|images|terraform|control-plane|build-worker|gpu-worker|k8s|storage|model-build|gitlab|harbor|registry|finalize|provision|platform|all] [--validate-gpu] [--require-backend-config]\n'
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

case "$PHASES" in
  tools|devstack|proxy|images|terraform|control-plane|build-worker|gpu-worker|k8s|storage|model-build|gitlab|harbor|registry|finalize|provision|platform|all) ;;
  *)
    printf 'phases must be one of: tools, devstack, proxy, images, terraform, control-plane, build-worker, gpu-worker, k8s, storage, model-build, gitlab, harbor, registry, finalize, provision, platform, all\n' >&2
    exit 64
    ;;
esac

RUN_ID_PHASE="${PHASES//[^[:alnum:]_.-]/_}"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-${MODE}-${RUN_ID_PHASE}-$$}"
LOG_DIR="${ROOT}/.ha/ci/runs/${RUN_ID}"
TIMINGS="${LOG_DIR}/timings.tsv"
TIMINGS_LOCK="${TIMINGS}.lock"
mkdir -p "${LOG_DIR}" "${ROOT}/.ha/openstack" "${ROOT}/.ha/ssh"
PATH="${ROOT}/.ha/bin:${PATH}"
export TF_IN_AUTOMATION="${TF_IN_AUTOMATION:-true}"
export TF_INPUT="${TF_INPUT:-false}"

HA_DEVSTACK_PASSWORD="${HA_DEVSTACK_PASSWORD:-hybrid-ai-devstack}"
HA_DEVSTACK_LIBVIRT_TYPE="${HA_DEVSTACK_LIBVIRT_TYPE:-auto}"
HA_OPENSTACK_PERSISTENT_STORAGE="${HA_OPENSTACK_PERSISTENT_STORAGE:-true}"
HA_OPENSTACK_PERSISTENT_DIR="${HA_OPENSTACK_PERSISTENT_DIR:-${ROOT}/.ha/openstack/persistent}"
HA_OPENSTACK_GLANCE_STORE_DIR="${HA_OPENSTACK_GLANCE_STORE_DIR:-${HA_OPENSTACK_PERSISTENT_DIR}/glance-images}"
HA_OPENSTACK_NOVA_INSTANCES_DIR="${HA_OPENSTACK_NOVA_INSTANCES_DIR:-${HA_OPENSTACK_PERSISTENT_DIR}/nova-instances}"
HA_OPENSTACK_GLANCE_STORE_LXD_DEVICE="${HA_OPENSTACK_GLANCE_STORE_LXD_DEVICE:-hybrid-ai-glance-store}"
HA_OPENSTACK_NOVA_INSTANCES_LXD_DEVICE="${HA_OPENSTACK_NOVA_INSTANCES_LXD_DEVICE:-hybrid-ai-nova-instances}"
HA_OPENSTACK_GLANCE_STORE_CONTAINER_DIR="${HA_OPENSTACK_GLANCE_STORE_CONTAINER_DIR:-/opt/stack/data/glance/images}"
HA_OPENSTACK_NOVA_INSTANCES_CONTAINER_DIR="${HA_OPENSTACK_NOVA_INSTANCES_CONTAINER_DIR:-/opt/stack/data/nova/instances}"
HA_DEVSTACK_CACHE_ENABLED="${HA_DEVSTACK_CACHE_ENABLED:-true}"
HA_DEVSTACK_CACHE_DIR="${HA_DEVSTACK_CACHE_DIR:-${ROOT}/.ha/openstack/devstack-cache}"
HA_DEVSTACK_APT_CACHE_DIR="${HA_DEVSTACK_APT_CACHE_DIR:-${HA_DEVSTACK_CACHE_DIR}/apt/archives}"
HA_DEVSTACK_ROOT_CACHE_DIR="${HA_DEVSTACK_ROOT_CACHE_DIR:-${HA_DEVSTACK_CACHE_DIR}/root-cache}"
HA_DEVSTACK_STACK_CACHE_DIR="${HA_DEVSTACK_STACK_CACHE_DIR:-${HA_DEVSTACK_CACHE_DIR}/stack-cache}"
HA_DEVSTACK_LXD_STORAGE_POOL="${HA_DEVSTACK_LXD_STORAGE_POOL:-}"
HA_DEVSTACK_CONTAINER_CACHE_ENABLED="${HA_DEVSTACK_CONTAINER_CACHE_ENABLED:-${HA_DEVSTACK_CACHE_ENABLED}}"
HA_DEVSTACK_CONTAINER_CACHE_NAME="${HA_DEVSTACK_CONTAINER_CACHE_NAME:-ha-openstack-devstack-cache}"
HA_DEVSTACK_CONTAINER_CACHE_RESTORE="${HA_DEVSTACK_CONTAINER_CACHE_RESTORE:-true}"
HA_DEVSTACK_CONTAINER_CACHE_REFRESH="${HA_DEVSTACK_CONTAINER_CACHE_REFRESH:-true}"
HA_DEVSTACK_CONTAINER_CACHE_COW_DRIVERS="${HA_DEVSTACK_CONTAINER_CACHE_COW_DRIVERS:-btrfs,zfs,lvm}"
HA_DEVSTACK_CONTAINER_CACHE_VERSION="${HA_DEVSTACK_CONTAINER_CACHE_VERSION:-20260610.1}"

# ── OpenStack 백엔드 선택 (DevStack → Kolla 마이그레이션) ──────────────
# /etc/kolla/globals.yml 존재 시 자동으로 kolla. devstack 강제는 HA_OPENSTACK_PROVIDER=devstack.
HA_OPENSTACK_PROVIDER="${HA_OPENSTACK_PROVIDER:-$([ -f /etc/kolla/globals.yml ] && echo kolla || echo devstack)}"
HA_KOLLA_VENV="${HA_KOLLA_VENV:-${HOME}/.ha/kolla-venv}"
HA_KOLLA_DEPLOY_SCRIPT="${HA_KOLLA_DEPLOY_SCRIPT:-${ROOT}/private/openstack-kolla/deploy-kolla.sh}"
HA_KOLLA_ADMIN_OPENRC="${HA_KOLLA_ADMIN_OPENRC:-/etc/kolla/admin-openrc.sh}"
# tenant VM ProxyCommand용 nc 래퍼 (qdhcp netns 안에서 nc만 실행, 좁은 NOPASSWD sudoers와 함께)
HA_KOLLA_NETNS_NC="${HA_KOLLA_NETNS_NC:-/usr/local/sbin/ha-netns-nc}"

PRIVATE_CLOUD_BASE_DOMAIN="${PRIVATE_CLOUD_BASE_DOMAIN:-${HA_BASE_DOMAIN:-intp.me}}"
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
# shellcheck disable=SC2034 # read indirectly by effective_worker_count.
[[ -n "${TF_VAR_build_worker_count+x}" ]] && TF_VAR_BUILD_WORKER_COUNT_INPUT_PROVIDED=true
# shellcheck disable=SC2034 # read indirectly by effective_worker_count.
[[ -n "${TF_VAR_gpu_worker_count+x}" ]] && TF_VAR_GPU_WORKER_COUNT_INPUT_PROVIDED=true
# shellcheck disable=SC2034 # read indirectly by effective_worker_count.
[[ -n "${TF_VAR_gitlab_count+x}" ]] && TF_VAR_GITLAB_COUNT_INPUT_PROVIDED=true
# shellcheck disable=SC2034 # read indirectly by effective_worker_count.
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
HA_DEVSTACK_CONTROL_FLAVOR_NAME="${HA_DEVSTACK_CONTROL_FLAVOR_NAME:-ha.m1.control}"
HA_DEVSTACK_CONTROL_FLAVOR_RAM="${HA_DEVSTACK_CONTROL_FLAVOR_RAM:-8192}"
HA_DEVSTACK_CONTROL_FLAVOR_VCPUS="${HA_DEVSTACK_CONTROL_FLAVOR_VCPUS:-3}"
HA_DEVSTACK_CONTROL_FLAVOR_DISK="${HA_DEVSTACK_CONTROL_FLAVOR_DISK:-80}"
HA_DEVSTACK_WORKER_FLAVOR_NAME="${HA_DEVSTACK_WORKER_FLAVOR_NAME:-ha.m1.build}"
HA_DEVSTACK_WORKER_FLAVOR_RAM="${HA_DEVSTACK_WORKER_FLAVOR_RAM:-6144}"
HA_DEVSTACK_WORKER_FLAVOR_VCPUS="${HA_DEVSTACK_WORKER_FLAVOR_VCPUS:-2}"
HA_DEVSTACK_WORKER_FLAVOR_DISK="${HA_DEVSTACK_WORKER_FLAVOR_DISK:-80}"
HA_DEVSTACK_GITLAB_FLAVOR_NAME="${HA_DEVSTACK_GITLAB_FLAVOR_NAME:-ha.m1.gitlab}"
HA_DEVSTACK_GITLAB_FLAVOR_RAM="${HA_DEVSTACK_GITLAB_FLAVOR_RAM:-12288}"
HA_DEVSTACK_GITLAB_FLAVOR_VCPUS="${HA_DEVSTACK_GITLAB_FLAVOR_VCPUS:-3}"
HA_DEVSTACK_GITLAB_FLAVOR_DISK="${HA_DEVSTACK_GITLAB_FLAVOR_DISK:-80}"
HA_DEVSTACK_HARBOR_FLAVOR_NAME="${HA_DEVSTACK_HARBOR_FLAVOR_NAME:-ha.m1.harbor}"
HA_DEVSTACK_HARBOR_FLAVOR_RAM="${HA_DEVSTACK_HARBOR_FLAVOR_RAM:-4096}"
HA_DEVSTACK_HARBOR_FLAVOR_VCPUS="${HA_DEVSTACK_HARBOR_FLAVOR_VCPUS:-2}"
HA_DEVSTACK_HARBOR_FLAVOR_DISK="${HA_DEVSTACK_HARBOR_FLAVOR_DISK:-80}"
HA_DEVSTACK_CONTROL_PLANE_PRIVATE_IPS="${HA_DEVSTACK_CONTROL_PLANE_PRIVATE_IPS:-10.42.0.88}"
HA_DEVSTACK_BUILD_WORKER_PRIVATE_IPS="${HA_DEVSTACK_BUILD_WORKER_PRIVATE_IPS:-10.42.0.5}"
HA_DEVSTACK_GPU_WORKER_PRIVATE_IPS="${HA_DEVSTACK_GPU_WORKER_PRIVATE_IPS:-10.42.0.11}"
HA_DEVSTACK_GITLAB_PRIVATE_IPS="${HA_DEVSTACK_GITLAB_PRIVATE_IPS:-10.42.0.61}"
HA_DEVSTACK_HARBOR_PRIVATE_IPS="${HA_DEVSTACK_HARBOR_PRIVATE_IPS:-10.42.0.127}"
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
GITLAB_ROOT_PASSWORD="${GITLAB_ROOT_PASSWORD:-}"
GITLAB_GPU_RUNNER_NAME_PREFIX="${GITLAB_GPU_RUNNER_NAME_PREFIX:-hybrid-ai-gpu}"
GITLAB_GPU_RUNNER_TAGS="${GITLAB_GPU_RUNNER_TAGS:-gpu-worker}"
GITLAB_UPSTREAM_PORT="${GITLAB_UPSTREAM_PORT:-18083}"
GITLAB_LOGS_TMPFS="${GITLAB_LOGS_TMPFS:-true}"
GITLAB_LOGS_TMPFS_SIZE="${GITLAB_LOGS_TMPFS_SIZE:-512m}"
GITLAB_TMPFS_SIZE="${GITLAB_TMPFS_SIZE:-1g}"
GITLAB_RAILS_TMPFS_ENABLED="${GITLAB_RAILS_TMPFS_ENABLED:-false}"
GITLAB_RAILS_TMPFS_SIZE="${GITLAB_RAILS_TMPFS_SIZE:-512m}"
GITLAB_DOCKER_BLKIO_WEIGHT="${GITLAB_DOCKER_BLKIO_WEIGHT:-300}"
GITLAB_RECREATE_FOR_IO_PROFILE="${GITLAB_RECREATE_FOR_IO_PROFILE:-true}"
GITLAB_DOCKER_LOG_MAX_SIZE="${GITLAB_DOCKER_LOG_MAX_SIZE:-10m}"
GITLAB_DOCKER_LOG_MAX_FILE="${GITLAB_DOCKER_LOG_MAX_FILE:-3}"
HARBOR_INSTALL_ENABLED="${HARBOR_INSTALL_ENABLED:-true}"
HARBOR_ADMIN_USERNAME="${HARBOR_ADMIN_USERNAME:-admin}"
HARBOR_DOMAIN="${HARBOR_DOMAIN:-harbor.${PRIVATE_CLOUD_BASE_DOMAIN}}"
HARBOR_EXTERNAL_URL="${HARBOR_EXTERNAL_URL:-https://${HARBOR_DOMAIN}}"
HARBOR_VERSION="${HARBOR_VERSION:-v2.14.4}"
HARBOR_PROJECTS="${HARBOR_PROJECTS:-infra models}"
HARBOR_ROBOT_NAME="${HARBOR_ROBOT_NAME:-kaniko}"
HARBOR_HTTP_PORT="${HARBOR_HTTP_PORT:-80}"
HARBOR_UPSTREAM_PORT="${HARBOR_UPSTREAM_PORT:-18084}"
HARBOR_BOOTSTRAP_WAIT_SECONDS="${HARBOR_BOOTSTRAP_WAIT_SECONDS:-1800}"
HARBOR_ADMIN_PASSWORD="${HARBOR_ADMIN_PASSWORD:-}"
HARBOR_CA_CERT="${HARBOR_CA_CERT:-}"
GITLAB_PIPELINE_TRIGGER_TOKEN="${GITLAB_PIPELINE_TRIGGER_TOKEN:-}"
MINIO_DOMAIN="${MINIO_DOMAIN:-minio.${PRIVATE_CLOUD_BASE_DOMAIN}}"
MINIO_CONSOLE_DOMAIN="${MINIO_CONSOLE_DOMAIN:-minio-console.${PRIVATE_CLOUD_BASE_DOMAIN}}"
MINIO_API_NODEPORT="${MINIO_API_NODEPORT:-30900}"
MINIO_CONSOLE_NODEPORT="${MINIO_CONSOLE_NODEPORT:-30990}"
MINIO_API_UPSTREAM_PORT="${MINIO_API_UPSTREAM_PORT:-19000}"
MINIO_CONSOLE_UPSTREAM_PORT="${MINIO_CONSOLE_UPSTREAM_PORT:-19090}"
MINIO_PROXY_ENABLED="${MINIO_PROXY_ENABLED:-true}"
PRIVATE_CLOUD_PROXY_ENABLED="${PRIVATE_CLOUD_PROXY_ENABLED:-true}"
PRIVATE_CLOUD_PROXY_TLS_MODE="${PRIVATE_CLOUD_PROXY_TLS_MODE:-auto}"
PRIVATE_CLOUD_DNS_TTL="${PRIVATE_CLOUD_DNS_TTL:-${HA_CLOUDFLARE_DNS_TTL:-120}}"
PRIVATE_CLOUD_DNS_SERVICES="${PRIVATE_CLOUD_DNS_SERVICES:-${HA_DNS_SERVICES:-openstack,k8s,grafana,argocd,gitlab,harbor,minio,minio-console}}"
PRIVATE_CLOUD_DNS_SSH_ALIASES="${PRIVATE_CLOUD_DNS_SSH_ALIASES:-${HA_DNS_SSH_ALIASES:-control-ssh,build-ssh,gpu-ssh,gitlab-ssh,harbor-ssh}}"
PRIVATE_CLOUD_ASSIGN_FLOATING_IPS="${PRIVATE_CLOUD_ASSIGN_FLOATING_IPS:-true}"
PRIVATE_CLOUD_INTERNAL_DNS_ENABLED="${PRIVATE_CLOUD_INTERNAL_DNS_ENABLED:-false}"
PRIVATE_CLOUD_INTERNAL_DNS_ZONE="${PRIVATE_CLOUD_INTERNAL_DNS_ZONE:-internal.${PRIVATE_CLOUD_BASE_DOMAIN}}"
PRIVATE_CLOUD_INTERNAL_DNS_RECORDS="${PRIVATE_CLOUD_INTERNAL_DNS_RECORDS:-}"
PRIVATE_CLOUD_SSH_TUNNELS_ENABLED="${PRIVATE_CLOUD_SSH_TUNNELS_ENABLED:-true}"
PRIVATE_CLOUD_SSH_TUNNEL_LISTEN_ADDRESS="${PRIVATE_CLOUD_SSH_TUNNEL_LISTEN_ADDRESS:-auto}"
PRIVATE_CLOUD_SSH_CONTROL_PORT="${PRIVATE_CLOUD_SSH_CONTROL_PORT:-2201}"
PRIVATE_CLOUD_SSH_BUILD_PORT="${PRIVATE_CLOUD_SSH_BUILD_PORT:-2202}"
PRIVATE_CLOUD_SSH_GPU_PORT="${PRIVATE_CLOUD_SSH_GPU_PORT:-2203}"
PRIVATE_CLOUD_SSH_GITLAB_PORT="${PRIVATE_CLOUD_SSH_GITLAB_PORT:-2204}"
PRIVATE_CLOUD_SSH_HARBOR_PORT="${PRIVATE_CLOUD_SSH_HARBOR_PORT:-2205}"
ARGO_WORKFLOWS_INSTALL_ENABLED="${ARGO_WORKFLOWS_INSTALL_ENABLED:-true}"
ARGO_WORKFLOWS_INSTALL_MANIFEST="${ARGO_WORKFLOWS_INSTALL_MANIFEST:-https://github.com/argoproj/argo-workflows/releases/download/v3.7.14/install.yaml}"
MINIO_VOLUME_SIZE="${MINIO_VOLUME_SIZE:-10}"
MINIO_ROOT_USER="${MINIO_ROOT_USER:-3stacks}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-}"
MINIO_CONSOLE_USER="${MINIO_CONSOLE_USER:-model-admin}"
MINIO_CONSOLE_PASSWORD="${MINIO_CONSOLE_PASSWORD:-}"
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
HA_PRIVATE_CLOUD_QUOTA_HEADROOM_INSTANCES="${HA_PRIVATE_CLOUD_QUOTA_HEADROOM_INSTANCES:-0}"
HA_PRIVATE_CLOUD_QUOTA_HEADROOM_CORES="${HA_PRIVATE_CLOUD_QUOTA_HEADROOM_CORES:-0}"
HA_PRIVATE_CLOUD_QUOTA_HEADROOM_RAM_MB="${HA_PRIVATE_CLOUD_QUOTA_HEADROOM_RAM_MB:-0}"
HA_PRIVATE_CLOUD_HOST_RESOURCE_PREFLIGHT="${HA_PRIVATE_CLOUD_HOST_RESOURCE_PREFLIGHT:-true}"
HA_PRIVATE_CLOUD_HOST_VCPU_RESERVE="${HA_PRIVATE_CLOUD_HOST_VCPU_RESERVE:-2}"
HA_PRIVATE_CLOUD_HOST_RAM_RESERVE_MB="${HA_PRIVATE_CLOUD_HOST_RAM_RESERVE_MB:-20480}"
HA_PRIVATE_CLOUD_HOST_DISK_RESERVE_GB="${HA_PRIVATE_CLOUD_HOST_DISK_RESERVE_GB:-160}"
HA_PRIVATE_CLOUD_SETUP_STORAGE="${HA_PRIVATE_CLOUD_SETUP_STORAGE:-auto}"
HA_PRIVATE_CLOUD_SETUP_REGISTRY="${HA_PRIVATE_CLOUD_SETUP_REGISTRY:-auto}"
HA_PRIVATE_CLOUD_SETUP_MODEL_BUILD="${HA_PRIVATE_CLOUD_SETUP_MODEL_BUILD:-auto}"
HA_PRIVATE_CLOUD_SYNC_OPENSTACK_USER="${HA_PRIVATE_CLOUD_SYNC_OPENSTACK_USER:-auto}"
HA_TERRAFORM_APPLY_PARALLELISM="${HA_TERRAFORM_APPLY_PARALLELISM:-2}"
HA_ALLOW_UNMANAGED_OPENSTACK_STACK="${HA_ALLOW_UNMANAGED_OPENSTACK_STACK:-false}"
DEVSTACK_CONTAINER_RESTORED_FROM_CACHE=false

printf 'phase\tseconds\tstatus\n' >"${TIMINGS}"

log() {
  printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"
}

record_timing() {
  local name="$1" seconds="$2" status="$3" lock_fd
  if command -v flock >/dev/null 2>&1; then
    exec {lock_fd}>"${TIMINGS_LOCK}"
    flock "${lock_fd}"
    printf '%s\t%s\t%s\n' "${name}" "${seconds}" "${status}" >>"${TIMINGS}"
    flock -u "${lock_fd}"
    exec {lock_fd}>&-
  else
    printf '%s\t%s\t%s\n' "${name}" "${seconds}" "${status}" >>"${TIMINGS}"
  fi
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
  local start end rc log_file parallel grouped
  log_file="${LOG_DIR}/${name}.log"
  parallel="${_PHASE_PARALLEL:-0}"
  grouped=0
  [[ "${GITHUB_ACTIONS:-}" == "true" && "${parallel}" != "1" ]] && grouped=1
  start="$(date +%s)"
  if [[ "${grouped}" -eq 1 ]]; then
    printf '::group::%s\n' "${name}"
  fi
  log "START ${name}"
  # Stream phase output to both the console (live progress) and the per-phase log.
  # Parallel phases prefix each line with the phase name so interleaved output stays readable.
  set +e
  if [[ "${parallel}" == "1" ]]; then
    ( set -Eeuo pipefail; "$@" ) 2>&1 | sed "s/^/[${name}] /" | tee "${log_file}"
  else
    ( set -Eeuo pipefail; "$@" ) 2>&1 | tee "${log_file}"
  fi
  rc="${PIPESTATUS[0]}"
  set -e
  end="$(date +%s)"
  if [[ "${rc}" -eq 0 ]]; then
    record_timing "${name}" "$((end - start))" ok
    log "OK ${name} ($((end - start))s)"
    if [[ "${grouped}" -eq 1 ]]; then
      printf '::endgroup::\n'
    fi
    return 0
  fi
  record_timing "${name}" "$((end - start))" failed
  log "FAILED ${name} ($((end - start))s); see ${log_file}"
  if [[ "${grouped}" -eq 1 ]]; then
    printf '::endgroup::\n'
  fi
  return "${rc}"
}

phase_bg() {
  local name="$1"
  shift
  ( _PHASE_PARALLEL=1 phase "${name}" "$@" ) &
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
  for tool in curl flock git lxc python3 ssh scp ssh-keygen terraform kubectl helm; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
      printf 'missing tool: %s\n' "${tool}" >&2
      missing=1
    fi
  done
  return "${missing}"
}

ensure_ssh_key() {
  local lock_fd lock_file
  mkdir -p "$(dirname "${SSH_KEY}")"
  lock_file="${SSH_KEY}.lock"
  exec {lock_fd}>"${lock_file}"
  flock "${lock_fd}"
  if [[ ! -f "${SSH_KEY}" ]]; then
    ssh-keygen -t ed25519 -N '' -f "${SSH_KEY}" >/dev/null
  fi
  flock -u "${lock_fd}"
  exec {lock_fd}>&-
}

write_ssh_config() {
  local tmp_config proxy_cmd
  ensure_ssh_key
  if [[ "${HA_OPENSTACK_PROVIDER}" == "kolla" ]]; then
    # Kolla: VM은 OpenStack Floating IP(ext-net)로 직접 접근 → ProxyCommand 불필요
    proxy_cmd=""
  else
    proxy_cmd="lxc exec ha-openstack -- nc %h %p"
  fi
  tmp_config="${SSH_CONFIG}.$$"
  {
    printf 'Host *\n'
    printf '  User ubuntu\n'
    printf '  IdentityFile %s\n' "${SSH_KEY}"
    printf '  BatchMode yes\n'
    printf '  StrictHostKeyChecking no\n'
    printf '  CheckHostIP no\n'
    printf '  UserKnownHostsFile /dev/null\n'
    printf '  LogLevel ERROR\n'
    [[ -n "${proxy_cmd}" ]] && printf '  ProxyCommand %s\n' "${proxy_cmd}"
  } >"${tmp_config}"
  chmod 600 "${tmp_config}"
  mv "${tmp_config}" "${SSH_CONFIG}"
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

ensure_lxc_proxy_device_unlocked() {
  local device="$1" listen="$2" connect="$3" attempt rc output

  rc=1
  output=""
  for attempt in {1..6}; do
    lxc config device remove ha-openstack "${device}" >/dev/null 2>&1 || true
    if output="$(lxc config device add ha-openstack "${device}" proxy "listen=${listen}" "connect=${connect}" 2>&1 >/dev/null)"; then
      return 0
    fi
    rc=$?
    sleep "$((attempt * 2))"
  done

  printf 'failed to configure LXC proxy device %s: %s\n' "${device}" "${output}" >&2
  return "${rc}"
}

# 호스트→VM 서비스 엔드포인트: Kolla=FIP(target):service_port 직접, DevStack=127.0.0.1:upstream(LXD)
host_svc_ep() {
  if [[ "${HA_OPENSTACK_PROVIDER}" == "kolla" ]]; then printf '%s:%s' "$1" "$2"; else printf '127.0.0.1:%s' "$3"; fi
}

ensure_lxc_proxy_device() {
  local lock_file lock_fd rc
  # Kolla: 호스트가 OpenStack Floating IP로 VM 서비스에 직접 접근 → LXD proxy device 불필요 (no-op)
  if [[ "${HA_OPENSTACK_PROVIDER}" == "kolla" ]]; then
    return 0
  fi
  lock_file="${ROOT}/.ha/openstack/lxc-config.lock"
  mkdir -p "$(dirname "${lock_file}")"
  exec {lock_fd}>"${lock_file}"
  flock "${lock_fd}"
  ensure_lxc_proxy_device_unlocked "$@"
  rc=$?
  flock -u "${lock_fd}"
  exec {lock_fd}>&-
  return "${rc}"
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

ensure_host_vfio_legacy_group_devices() {
  local vfio_major group_dir group_id group_node group_devt dev_major dev_minor expected_devt actual_devt
  local member current_driver has_vfio_device

  [[ -d /dev/vfio ]] || return 0
  vfio_major="$(awk '$2 == "vfio" {print $1; exit}' /proc/devices)"
  [[ -n "${vfio_major}" ]] || return 0

  for group_dir in /sys/kernel/iommu_groups/[0-9]*; do
    [[ -d "${group_dir}" ]] || continue
    has_vfio_device=0
    for member in "${group_dir}"/devices/*; do
      [[ -e "${member}" ]] || continue
      current_driver="$(basename "$(readlink -f "${member}/driver" 2>/dev/null)" 2>/dev/null || true)"
      if [[ "${current_driver}" == "vfio-pci" ]]; then
        has_vfio_device=1
        break
      fi
    done
    [[ "${has_vfio_device}" == "1" ]] || continue

    group_id="${group_dir##*/}"
    group_node="/dev/vfio/${group_id}"
    group_devt="$(cat "/sys/class/vfio/${group_id}/dev" 2>/dev/null || true)"
    if [[ "${group_devt}" =~ ^[0-9]+:[0-9]+$ ]]; then
      dev_major="${group_devt%%:*}"
      dev_minor="${group_devt##*:}"
    else
      dev_major="${vfio_major}"
      dev_minor="${group_id}"
    fi
    expected_devt="$(printf '%x:%x' "${dev_major}" "${dev_minor}")"
    actual_devt="$(stat -c '%t:%T' "${group_node}" 2>/dev/null || true)"

    if [[ -e "${group_node}" && ( ! -c "${group_node}" || "${actual_devt}" != "${expected_devt}" ) ]]; then
      rm -f "${group_node}" || true
    fi
    if [[ ! -e "${group_node}" ]]; then
      mknod "${group_node}" c "${dev_major}" "${dev_minor}" 2>/dev/null || true
    fi
  done
}

add_lxc_vfio_devices() {
  local group_device group_id

  [[ -d /dev/vfio ]] || return 0
  ensure_host_vfio_legacy_group_devices
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
  local device source group_id group_devt expected_devt actual_devt dev_major dev_minor

  while IFS= read -r device; do
    case "$device" in
      vfio|vfio-control|vfio-group-*)
        source="$(lxc config device get ha-openstack "$device" source 2>/dev/null || true)"
        if [[ -z "$source" || ! -e "$source" ]]; then
          lxc config device remove ha-openstack "$device" >/dev/null 2>&1 || true
          continue
        fi
        case "$device" in
          vfio-group-*)
            group_id="${device#vfio-group-}"
            group_devt="$(cat "/sys/class/vfio/${group_id}/dev" 2>/dev/null || true)"
            if [[ "${group_devt}" =~ ^[0-9]+:[0-9]+$ ]]; then
              dev_major="${group_devt%%:*}"
              dev_minor="${group_devt##*:}"
              expected_devt="$(printf '%x:%x' "${dev_major}" "${dev_minor}")"
              actual_devt="$(stat -c '%t:%T' "$source" 2>/dev/null || true)"
              if [[ ! -c "$source" || "$actual_devt" != "$expected_devt" ]]; then
                lxc config device remove ha-openstack "$device" >/dev/null 2>&1 || true
              fi
            fi
            ;;
        esac
      ;;
    esac
  done < <(lxc config device list ha-openstack 2>/dev/null || true)
}

remove_stale_vfio_group_mounts() {
  local device source group_id group_devt expected_devt actual_devt dev_major dev_minor

  while IFS= read -r device; do
    case "$device" in
      vfio-group-*)
        source="$(lxc config device get ha-openstack "$device" source 2>/dev/null || true)"
        group_id="${device#vfio-group-}"
        group_devt="$(cat "/sys/class/vfio/${group_id}/dev" 2>/dev/null || true)"
        [[ -n "$source" && "${group_devt}" =~ ^[0-9]+:[0-9]+$ ]] || continue
        dev_major="${group_devt%%:*}"
        dev_minor="${group_devt##*:}"
        expected_devt="$(printf '%x:%x' "${dev_major}" "${dev_minor}")"
        actual_devt="$(stat -c '%t:%T' "$source" 2>/dev/null || true)"
        if [[ ! -c "$source" || "$actual_devt" != "$expected_devt" ]]; then
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
  remove_stale_vfio_group_mounts
  lxc config device add ha-openstack kmsg unix-char source=/dev/kmsg path=/dev/kmsg >/dev/null 2>&1 || true
  lxc config device remove ha-openstack host-kernel-modules >/dev/null 2>&1 || true
  lxc config device add ha-openstack host-kernel-modules disk source="${kernel_modules_source}" path=/usr/lib/modules readonly=true >/dev/null 2>&1 || true
  if [[ -e /dev/kvm ]]; then
    lxc config device add ha-openstack kvm unix-char source=/dev/kvm path=/dev/kvm >/dev/null 2>&1 || true
  fi
  add_lxc_vfio_devices
}

remove_transient_lxc_devices() {
  local instance="$1" device

  while IFS= read -r device; do
    case "$device" in
      horizon-proxy|host-kernel-modules|hybrid-ai-devstack-apt-cache|hybrid-ai-devstack-root-cache|hybrid-ai-devstack-stack-cache|"$HA_OPENSTACK_GLANCE_STORE_LXD_DEVICE"|"$HA_OPENSTACK_NOVA_INSTANCES_LXD_DEVICE"|hybrid-ai-image-cache|kmsg|kvm|vfio|vfio-control|vfio-group-*|hybrid-ai-public-http|hybrid-ai-public-https|hybrid-ai-ssh-*|minio-api-proxy|minio-console-proxy)
        lxc config device remove "$instance" "$device" >/dev/null 2>&1 || true
        ;;
    esac
  done < <(lxc config device list "$instance" 2>/dev/null || true)
}

lxc_instance_root_pool() {
  local instance="$1" pool
  pool="$(lxc config device get "$instance" root pool 2>/dev/null || true)"
  if [[ -z "$pool" ]]; then
    pool="$(lxc profile device get default root pool 2>/dev/null || true)"
  fi
  printf '%s\n' "$pool"
}

lxc_storage_driver() {
  local pool="$1"
  [[ -n "$pool" ]] || return 1
  lxc storage show "$pool" 2>/dev/null | awk '$1 == "driver:" {print $2; exit}'
}

lxc_storage_driver_supports_container_cache() {
  local driver="$1"
  [[ -n "$driver" ]] || return 1
  case ",${HA_DEVSTACK_CONTAINER_CACHE_COW_DRIVERS}," in
    *,"$driver",*) return 0 ;;
    *) return 1 ;;
  esac
}

devstack_container_cache_key() {
  {
    printf 'version=%s\n' "$HA_DEVSTACK_CONTAINER_CACHE_VERSION"
    printf 'ubuntu=24.04\n'
    printf 'password=%s\n' "$HA_DEVSTACK_PASSWORD"
    printf 'libvirt_type=%s\n' "$HA_DEVSTACK_LIBVIRT_TYPE"
    printf 'nova_instances_dir=%s\n' "$HA_OPENSTACK_NOVA_INSTANCES_CONTAINER_DIR"
    printf 'glance_store_dir=%s\n' "$HA_OPENSTACK_GLANCE_STORE_CONTAINER_DIR"
    printf 'force_raw_images=false\n'
  } | sha256sum | awk '{print substr($1, 1, 16)}'
}

restore_devstack_container_cache() {
  local cache_name cache_key cached_key cache_pool cache_driver raw_lxc

  [[ "${HA_DEVSTACK_CONTAINER_CACHE_ENABLED}" == "true" ]] || return 1
  [[ "${HA_DEVSTACK_CONTAINER_CACHE_RESTORE}" == "true" ]] || return 1

  cache_name="$HA_DEVSTACK_CONTAINER_CACHE_NAME"
  lxc info "$cache_name" >/dev/null 2>&1 || return 1

  cache_pool="$(lxc_instance_root_pool "$cache_name")"
  cache_driver="$(lxc_storage_driver "$cache_pool")"
  if ! lxc_storage_driver_supports_container_cache "$cache_driver"; then
    log "DevStack container cache ${cache_name} is on ${cache_driver:-unknown} storage; skipping to avoid I/O-heavy rootfs copy"
    return 1
  fi

  cache_key="$(devstack_container_cache_key)"
  cached_key="$(lxc config get "$cache_name" user.hybrid-ai.devstack-cache-key 2>/dev/null || true)"
  if [[ "$cached_key" != "$cache_key" ]]; then
    log "DevStack container cache exists but does not match current config; rebuilding"
    return 1
  fi

  log "restoring DevStack container from LXD cache ${cache_name}"
  lxc stop ha-openstack --force >/dev/null 2>&1 || true
  lxc delete ha-openstack --force >/dev/null 2>&1 || true
  lxc copy "$cache_name" ha-openstack --instance-only

  raw_lxc="$(desired_lxc_raw_config)"
  lxc config set ha-openstack security.nesting true
  lxc config set ha-openstack security.privileged true
  lxc config set ha-openstack raw.lxc "$raw_lxc"
  remove_transient_lxc_devices ha-openstack
  configure_lxc_devices
  lxc start ha-openstack
  wait_lxc_ip
  configure_vfio_guest_access
  configure_devstack_apt_cache
  configure_devstack_user_caches
  configure_devstack_persistent_storage

  if verify_devstack; then
    DEVSTACK_CONTAINER_RESTORED_FROM_CACHE=true
    lxc list ha-openstack
    return 0
  fi

  log "cached DevStack container did not become ready; rebuilding from Ubuntu base"
  lxc stop ha-openstack --force >/dev/null 2>&1 || true
  lxc delete ha-openstack --force >/dev/null 2>&1 || true
  DEVSTACK_CONTAINER_RESTORED_FROM_CACHE=false
  return 1
}

configure_devstack_cache_mount() {
  local device="$1"
  local host_dir="$2"
  local container_dir="$3"
  local container_parent source path

  [[ "${HA_DEVSTACK_CACHE_ENABLED}" == "true" ]] || return 0

  mkdir -p "$host_dir"
  container_parent="${container_dir%/*}"
  lxc exec ha-openstack -- mkdir -p "$container_parent" >/dev/null

  source="$(lxc config device get ha-openstack "$device" source 2>/dev/null || true)"
  path="$(lxc config device get ha-openstack "$device" path 2>/dev/null || true)"
  if [[ -n "$source" || -n "$path" ]]; then
    if [[ "$source" != "$host_dir" || "$path" != "$container_dir" ]]; then
      lxc config device remove ha-openstack "$device" >/dev/null
      source=""
      path=""
    fi
  fi
  if [[ -z "$source" && -z "$path" ]]; then
    lxc config device add ha-openstack "$device" disk \
      source="$host_dir" \
      path="$container_dir" >/dev/null
  fi
}

configure_devstack_apt_cache() {
  [[ "${HA_DEVSTACK_CACHE_ENABLED}" == "true" ]] || return 0

  log "configuring DevStack APT package cache"
  configure_devstack_cache_mount \
    hybrid-ai-devstack-apt-cache \
    "$HA_DEVSTACK_APT_CACHE_DIR" \
    /var/cache/apt/archives
  lxc exec ha-openstack -- bash -s <<'CONFIGURE_DEVSTACK_APT_CACHE'
set -euo pipefail
install -d -m 0755 /var/cache/apt/archives
install -d -m 0700 /var/cache/apt/archives/partial
if getent passwd _apt >/dev/null 2>&1; then
  chown _apt:root /var/cache/apt/archives/partial
fi
cat >/etc/apt/apt.conf.d/99hybrid-ai-cache <<'EOF'
Binary::apt::APT::Keep-Downloaded-Packages "true";
APT::Keep-Downloaded-Packages "true";
Acquire::Retries "5";
Acquire::ForceIPv4 "true";
EOF
CONFIGURE_DEVSTACK_APT_CACHE
}

configure_devstack_user_caches() {
  [[ "${HA_DEVSTACK_CACHE_ENABLED}" == "true" ]] || return 0

  log "configuring DevStack root/stack user caches"
  configure_devstack_cache_mount \
    hybrid-ai-devstack-root-cache \
    "$HA_DEVSTACK_ROOT_CACHE_DIR" \
    /root/.cache
  configure_devstack_cache_mount \
    hybrid-ai-devstack-stack-cache \
    "$HA_DEVSTACK_STACK_CACHE_DIR" \
    /opt/stack/.cache
  lxc exec ha-openstack -- bash -s <<'CONFIGURE_DEVSTACK_USER_CACHES'
set -euo pipefail
install -d -m 0755 /root/.cache /root/.cache/pip
if id stack >/dev/null 2>&1; then
  install -d -o stack -g stack -m 0755 /opt/stack/.cache /opt/stack/.cache/pip
fi
cat >/etc/pip.conf <<'EOF'
[global]
disable-pip-version-check = true
EOF
CONFIGURE_DEVSTACK_USER_CACHES
}

refresh_devstack_container_cache() {
  local cache_name cache_key pool driver tmp_name was_running

  [[ "${HA_DEVSTACK_CONTAINER_CACHE_ENABLED}" == "true" ]] || return 0
  [[ "${HA_DEVSTACK_CONTAINER_CACHE_REFRESH}" == "true" ]] || return 0
  lxc info ha-openstack >/dev/null 2>&1 || return 0

  pool="$(lxc_instance_root_pool ha-openstack)"
  driver="$(lxc_storage_driver "$pool")"
  if ! lxc_storage_driver_supports_container_cache "$driver"; then
    log "skipping DevStack container cache refresh on ${driver:-unknown} storage to avoid I/O-heavy rootfs copy"
    return 0
  fi

  cache_name="$HA_DEVSTACK_CONTAINER_CACHE_NAME"
  cache_key="$(devstack_container_cache_key)"
  tmp_name="${cache_name}-tmp-$$"
  was_running="$(lxc list ha-openstack -c s --format csv | tr -d '"')"

  log "refreshing DevStack LXD container cache ${cache_name}"
  lxc delete "$tmp_name" --force >/dev/null 2>&1 || true
  if [[ "$was_running" == "RUNNING" ]]; then
    lxc stop ha-openstack --timeout 60 >/dev/null 2>&1 || lxc stop ha-openstack --force >/dev/null
  fi
  lxc copy ha-openstack "$tmp_name" --instance-only
  if [[ "$was_running" == "RUNNING" ]]; then
    lxc start ha-openstack
    wait_lxc_ip
    verify_devstack
  fi

  remove_transient_lxc_devices "$tmp_name"
  lxc config set "$tmp_name" boot.autostart false
  lxc config set "$tmp_name" user.hybrid-ai.devstack-cache-key "$cache_key"
  lxc config set "$tmp_name" user.hybrid-ai.devstack-cache-version "$HA_DEVSTACK_CONTAINER_CACHE_VERSION"
  lxc config set "$tmp_name" user.hybrid-ai.devstack-cache-updated-at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  lxc delete "$cache_name" --force >/dev/null 2>&1 || true
  lxc move "$tmp_name" "$cache_name"
  lxc list "$cache_name"
}

configure_vfio_guest_access() {
  lxc exec ha-openstack -- bash -s <<'CONFIGURE_VFIO_GUEST_ACCESS'
set -euo pipefail

ensure_vfio_legacy_group_devices() {
  local vfio_major group_dir group_id group_node group_devt dev_major dev_minor expected_devt actual_devt
  local member current_driver has_vfio_device

  [[ -d /dev/vfio ]] || return 0
  vfio_major="$(awk '$2 == "vfio" {print $1; exit}' /proc/devices)"
  [[ -n "${vfio_major}" ]] || return 0

  for group_dir in /sys/kernel/iommu_groups/[0-9]*; do
    [[ -d "${group_dir}" ]] || continue
    has_vfio_device=0
    for member in "${group_dir}"/devices/*; do
      [[ -e "${member}" ]] || continue
      current_driver="$(basename "$(readlink -f "${member}/driver" 2>/dev/null)" 2>/dev/null || true)"
      if [[ "${current_driver}" == "vfio-pci" ]]; then
        has_vfio_device=1
        break
      fi
    done
    [[ "${has_vfio_device}" == "1" ]] || continue

    group_id="${group_dir##*/}"
    group_node="/dev/vfio/${group_id}"
    group_devt="$(cat "/sys/class/vfio/${group_id}/dev" 2>/dev/null || true)"
    if [[ "${group_devt}" =~ ^[0-9]+:[0-9]+$ ]]; then
      dev_major="${group_devt%%:*}"
      dev_minor="${group_devt##*:}"
    else
      dev_major="${vfio_major}"
      dev_minor="${group_id}"
    fi
    expected_devt="$(printf '%x:%x' "${dev_major}" "${dev_minor}")"
    actual_devt="$(stat -c '%t:%T' "${group_node}" 2>/dev/null || true)"

    if [[ -e "${group_node}" && ( ! -c "${group_node}" || "${actual_devt}" != "${expected_devt}" ) ]]; then
      rm -f "${group_node}" || true
    fi
    if [[ ! -e "${group_node}" ]]; then
      mknod "${group_node}" c "${dev_major}" "${dev_minor}" 2>/dev/null || true
    fi
  done
}

ensure_vfio_legacy_group_devices

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
  local raw_lxc init_args=()
  DEVSTACK_CONTAINER_RESTORED_FROM_CACHE=false
  if restore_devstack_container_cache; then
    return 0
  fi

  lxc stop ha-openstack --force >/dev/null 2>&1 || true
  lxc delete ha-openstack --force >/dev/null 2>&1 || true
  raw_lxc="$(desired_lxc_raw_config)"
  init_args=(lxc init ubuntu:24.04 ha-openstack \
    -c security.nesting=true \
    -c security.privileged=true \
    -c raw.lxc="${raw_lxc}")
  if [[ -n "$HA_DEVSTACK_LXD_STORAGE_POOL" ]]; then
    init_args+=(--storage "$HA_DEVSTACK_LXD_STORAGE_POOL")
  fi
  "${init_args[@]}"
  configure_lxc_devices
  lxc start ha-openstack
  wait_lxc_ip
  lxc exec ha-openstack -- cloud-init status --wait >/dev/null 2>&1 || true
  configure_vfio_guest_access
  configure_devstack_apt_cache
  lxc list ha-openstack
}

configure_devstack_persistent_mount() {
  local device="$1"
  local host_dir="$2"
  local container_dir="$3"
  local container_parent source path

  [[ "${HA_OPENSTACK_PERSISTENT_STORAGE}" == "true" ]] || return 0

  mkdir -p "$host_dir"
  container_parent="${container_dir%/*}"
  lxc exec ha-openstack -- mkdir -p "$container_parent" >/dev/null

  source="$(lxc config device get ha-openstack "$device" source 2>/dev/null || true)"
  path="$(lxc config device get ha-openstack "$device" path 2>/dev/null || true)"
  if [[ -n "$source" || -n "$path" ]]; then
    if [[ "$source" != "$host_dir" || "$path" != "$container_dir" ]]; then
      lxc config device remove ha-openstack "$device" >/dev/null
      source=""
      path=""
    fi
  fi
  if [[ -z "$source" && -z "$path" ]]; then
    lxc config device add ha-openstack "$device" disk \
      source="$host_dir" \
      path="$container_dir" >/dev/null
  fi

  lxc exec ha-openstack -- bash -s -- "$container_dir" <<'PERSISTENT_MOUNT_PERMS'
set -euo pipefail
container_dir="$1"
container_parent="${container_dir%/*}"
mkdir -p "$container_dir"
if id stack >/dev/null 2>&1; then
  mkdir -p /opt/stack/data "$container_parent"
  chown stack:stack /opt/stack /opt/stack/data "$container_parent"
  chown -R stack:stack "$container_dir"
fi
chmod 0755 "$container_dir"
PERSISTENT_MOUNT_PERMS
}

configure_devstack_persistent_storage() {
  [[ "${HA_OPENSTACK_PERSISTENT_STORAGE}" == "true" ]] || return 0

  log "configuring persistent OpenStack storage mounts"
  configure_devstack_persistent_mount \
    "$HA_OPENSTACK_GLANCE_STORE_LXD_DEVICE" \
    "$HA_OPENSTACK_GLANCE_STORE_DIR" \
    "$HA_OPENSTACK_GLANCE_STORE_CONTAINER_DIR"
  configure_devstack_persistent_mount \
    "$HA_OPENSTACK_NOVA_INSTANCES_LXD_DEVICE" \
    "$HA_OPENSTACK_NOVA_INSTANCES_DIR" \
    "$HA_OPENSTACK_NOVA_INSTANCES_CONTAINER_DIR"
}

install_devstack_prereqs() {
  lxc exec ha-openstack -- bash -lc '
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=a
    export NEEDRESTART_SUSPEND=1
    apt-get update -qq
    apt-get install -y -qq git sudo curl ca-certificates iproute2 net-tools kmod openssh-client netcat-openbsd python3-openstackclient
    id stack >/dev/null 2>&1 || useradd -s /bin/bash -d /opt/stack -m stack
    chmod +x /opt/stack
    printf "stack ALL=(ALL) NOPASSWD: ALL\n" >/etc/sudoers.d/stack
    chmod 440 /etc/sudoers.d/stack
    chown -R stack:stack /opt/stack
  '
  configure_devstack_user_caches
  configure_devstack_persistent_storage
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
  current_driver=""
  driver_path=""
  if [[ -L "${member}/driver" ]]; then
    driver_path="$(readlink -f "${member}/driver" 2>/dev/null || true)"
    current_driver="${driver_path##*/}"
  fi
  if [[ "$class" == 06* ]]; then
    if [[ -n "$current_driver" && "$current_driver" != "vfio-pci" ]]; then
      [[ -n "$driver_path" ]] && printf '%s' "$member_bdf" >"${driver_path}/unbind" || true
    fi
    continue
  fi
  [[ "$current_driver" == "vfio-pci" ]] && continue
  printf vfio-pci >"${member}/driver_override"
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
    "${ip}" \
    "${HA_DEVSTACK_LIBVIRT_TYPE}" \
    "${HA_OPENSTACK_NOVA_INSTANCES_CONTAINER_DIR}" \
    "${HA_OPENSTACK_GLANCE_STORE_CONTAINER_DIR}" <<'WRITE_LOCAL_CONF'
set -euo pipefail
IP="$1"
requested_libvirt_type="$2"
nova_instances_dir="$3"
glance_store_dir="$4"
PASSWORD="$(cat /opt/stack/devstack/.devstack-password)"
if [[ "$requested_libvirt_type" == "auto" ]]; then
  if [[ -e /dev/kvm ]]; then
    libvirt_type="kvm"
  else
    libvirt_type="qemu"
  fi
else
  libvirt_type="$requested_libvirt_type"
fi
printf 'DevStack libvirt type: %s\n' "$libvirt_type"
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
  printf 'LIBVIRT_TYPE=%s\n' "$libvirt_type"
  printf '%s\n' 'ENABLE_VOLUME_BACKING_FILE=True'
  printf '%s\n' 'ETCD_DOWNLOAD_URL=https://storage.googleapis.com/etcd'
  printf '%s\n' 'IMAGE_URLS=https://github.com/cirros-dev/cirros/releases/download/0.6.2/cirros-0.6.2-x86_64-disk.img'
  printf '%s\n' 'disable_service tempest'
  printf '%s\n' 'disable_service swift'
  printf '%s\n' 'disable_service cinder'
  printf '%s\n' 'ENABLE_KSM=False'
  printf '%s\n' ''
  printf '%s\n' '[[post-config|$NOVA_CONF]]'
  printf '%s\n' '[DEFAULT]'
  printf 'instances_path = %s\n' "$nova_instances_dir"
  printf '%s\n' 'force_raw_images = False'
  printf '%s\n' ''
  printf '%s\n' '[neutron]'
  printf '%s\n' 'project_domain_name = Default'
  printf '%s\n' ''
  printf '%s\n' '[[post-config|/etc/nova/nova-cpu.conf]]'
  printf '%s\n' '[DEFAULT]'
  printf 'instances_path = %s\n' "$nova_instances_dir"
  printf '%s\n' 'force_raw_images = False'
  printf '%s\n' ''
  printf '%s\n' '[neutron]'
  printf '%s\n' 'project_domain_name = Default'
  printf '%s\n' ''
  printf '%s\n' '[[post-config|$GLANCE_API_CONF]]'
  printf '%s\n' '[glance_store]'
  printf 'filesystem_store_datadir = %s\n' "$glance_store_dir"
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

write_tf_string_list() {
  local name="$1"
  local raw="$2"
  [[ -n "$raw" ]] || return 0

  python3 - "$name" "$raw" <<'PY'
import json
import re
import sys

name = sys.argv[1]
raw = sys.argv[2]
items = [item.strip() for item in re.split(r"[\s,]+", raw) if item.strip()]
if items:
    print(f"{name} = {json.dumps(items)}")
PY
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

  # shellcheck disable=SC2016
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

tf_bool_value() {
  local name="$1"
  local value="${2,,}"

  case "${value}" in
    true|1|yes|on)
      printf 'true\n'
      ;;
    false|0|no|off)
      printf 'false\n'
      ;;
    *)
      printf '%s must be true or false; got: %s\n' "$name" "$2" >&2
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

guard_terraform_plan_deletes() {
  local plan_json="${LOG_DIR}/terraform-plan.json"

  [[ "${HA_PRIVATE_CLOUD_ALLOW_TERRAFORM_DESTROY:-false}" == "true" ]] && return 0

  terraform show -json private-cloud.tfplan >"${plan_json}"
  python3 - "${plan_json}" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    plan = json.load(handle)

destructive = []
for change in plan.get("resource_changes", []):
    actions = change.get("change", {}).get("actions", [])
    if "delete" in actions:
        destructive.append(f"{change.get('address', '<unknown>')}: {','.join(actions)}")

if destructive:
    print("Terraform plan includes delete/replacement actions; refusing apply.", file=sys.stderr)
    print("Set HA_PRIVATE_CLOUD_ALLOW_TERRAFORM_DESTROY=true only when the destructive plan is intentional.", file=sys.stderr)
    for item in destructive:
        print(f"- {item}", file=sys.stderr)
    sys.exit(1)
PY
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
  if [[ "${HA_OPENSTACK_PROVIDER}" == "kolla" ]]; then
    log "skip quota preflight: Kolla provider (기존 VM reconciled, 쿼터 충족)"
    return 0
  fi
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
    "${OS_PROJECT_NAME:-admin}" \
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
quota_project="$6"
shift 6
cd /opt/stack/devstack
set +u
source openrc admin admin >/dev/null
set -u
quota_project_id="$(openstack project show "$quota_project" -f value -c id)"

flavor_vcpus() {
  openstack flavor show "$1" -f value -c vcpus
}

flavor_ram() {
  openstack flavor show "$1" -f value -c ram
}

server_exists() {
  local name="$1" id server_name project_id
  while read -r id server_name; do
    [[ -n "$id" && "$server_name" == "$name" ]] || continue
    project_id="$(openstack server show "$id" -f value -c project_id)"
    [[ "$project_id" == "$quota_project_id" ]] && return 0
  done < <(openstack server list --all-projects -f value -c ID -c Name)
  return 1
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

if [[ "$auto_expand_quota" == "true" ]]; then
  target_instances=$((used_instances + need_instances + quota_headroom_instances))
  target_cores=$((used_cores + need_cores + quota_headroom_cores))
  target_ram=$((used_ram + need_ram + quota_headroom_ram_mb))
  expand_quota=false
  if [[ "$max_instances" -lt 0 || "$max_instances" -lt "$target_instances" ]]; then
    expand_quota=true
  fi
  if [[ "$max_cores" -lt 0 || "$max_cores" -lt "$target_cores" ]]; then
    expand_quota=true
  fi
  if [[ "$max_ram" -lt 0 || "$max_ram" -lt "$target_ram" ]]; then
    expand_quota=true
  fi
  if [[ "$expand_quota" == "true" ]]; then
    echo "quota preflight ensuring local DevStack quota headroom for project ${quota_project}: instances=${target_instances} cores=${target_cores} ram_mb=${target_ram}"
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
    echo "quota preflight available after headroom check: instances=${available_instances}/${max_instances} cores=${available_cores}/${max_cores} ram_mb=${available_ram}/${max_ram}"
  fi
elif (( need_instances > available_instances || need_cores > available_cores || need_ram > available_ram )); then
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

preflight_host_capacity() {
  if [[ "${HA_OPENSTACK_PROVIDER}" == "kolla" ]]; then
    log "skip host capacity preflight: Kolla provider (bare-metal nova, DevStack 컨테이너 없음)"
    return 0
  fi
  local apply_prefix="$1"
  local control_count="$2"
  local control_flavor="$3"
  local build_count="$4"
  local build_flavor="$5"
  local gpu_count="$6"
  local gpu_flavor="$7"
  local gitlab_count="$8"
  local gitlab_flavor="$9"
  local harbor_count="${10}"
  local harbor_flavor="${11}"
  local host_vcpus host_ram_mb host_disk_avail_gb
  local max_guest_vcpus max_guest_ram_mb max_guest_disk_gb

  [[ "${HA_PRIVATE_CLOUD_HOST_RESOURCE_PREFLIGHT}" == "true" ]] || return 0
  command -v lxc >/dev/null 2>&1 || return 0
  lxc info ha-openstack >/dev/null 2>&1 || return 0

  host_vcpus="$(nproc)"
  host_ram_mb="$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)"
  host_disk_avail_gb="$(df -BG "$ROOT" | awk 'NR == 2 {gsub("G", "", $4); print int($4)}')"
  max_guest_vcpus="${HA_PRIVATE_CLOUD_HOST_MAX_GUEST_VCPUS:-$((host_vcpus - HA_PRIVATE_CLOUD_HOST_VCPU_RESERVE))}"
  max_guest_ram_mb="${HA_PRIVATE_CLOUD_HOST_MAX_GUEST_RAM_MB:-$((host_ram_mb - HA_PRIVATE_CLOUD_HOST_RAM_RESERVE_MB))}"
  max_guest_disk_gb="${HA_PRIVATE_CLOUD_HOST_MAX_GUEST_DISK_GB:-$((host_disk_avail_gb - HA_PRIVATE_CLOUD_HOST_DISK_RESERVE_GB))}"
  (( max_guest_vcpus > 0 )) || max_guest_vcpus=0
  (( max_guest_ram_mb > 0 )) || max_guest_ram_mb=0
  (( max_guest_disk_gb > 0 )) || max_guest_disk_gb=0

  log "checking host capacity before apply: host_vcpus=${host_vcpus} host_ram_mb=${host_ram_mb} disk_avail_gb=${host_disk_avail_gb}"
  lxc exec ha-openstack -- sudo -u stack -H bash -s -- \
    "$max_guest_vcpus" \
    "$max_guest_ram_mb" \
    "$max_guest_disk_gb" \
    "$apply_prefix" \
    control "$control_count" "$control_flavor" \
    build "$build_count" "$build_flavor" \
    gpu "$gpu_count" "$gpu_flavor" \
    gitlab "$gitlab_count" "$gitlab_flavor" \
    harbor "$harbor_count" "$harbor_flavor" <<'PREFLIGHT_HOST_CAPACITY'
set -euo pipefail
max_guest_vcpus="$1"
max_guest_ram_mb="$2"
max_guest_disk_gb="$3"
apply_prefix="$4"
shift 4
cd /opt/stack/devstack
set +u
source openrc admin admin >/dev/null
set -u

flavor_value() {
  local flavor="$1"
  local column="$2"
  openstack flavor show "$flavor" -f value -c "$column"
}

total_vcpus=0
total_ram_mb=0
total_disk_gb=0
missing_disk_gb=0
existing_vcpus=0
existing_ram_mb=0
existing_disk_gb=0
summary=()
existing_summary=()
server_list_json="$(openstack server list --all-projects -f json -c Name -c Status -c Flavor)"
server_list_names="$(python3 - "$server_list_json" <<'PY'
import json
import sys

servers = json.loads(sys.argv[1] or "[]")
skip_statuses = {"DELETED", "SOFT_DELETED"}
for server in servers:
    name = str(server.get("Name") or "")
    status = str(server.get("Status") or "")
    if not name:
        continue
    if status.upper() in skip_statuses:
        continue
    print(f"{name}\t{status}")
PY
)"

server_exists() {
  local target="$1"
  local name status

  while IFS=$'\t' read -r name status; do
    [[ -n "$name" ]] || continue
    [[ "$name" == "$target" ]] && return 0
  done <<<"$server_list_names"
  return 1
}

while [[ $# -gt 0 ]]; do
  role="$1"
  count="$2"
  flavor="$3"
  shift 3
  [[ "$count" -gt 0 ]] || continue
  vcpus="$(flavor_value "$flavor" vcpus)"
  ram_mb="$(flavor_value "$flavor" ram)"
  disk_gb="$(flavor_value "$flavor" disk)"
  role_vcpus=$((count * vcpus))
  role_ram_mb=$((count * ram_mb))
  role_disk_gb=$((count * disk_gb))
  role_missing=0
  for ((index = 1; index <= count; index += 1)); do
    printf -v server_name "%s-%s-%02d" "$apply_prefix" "$role" "$index"
    if ! server_exists "$server_name"; then
      role_missing=$((role_missing + 1))
    fi
  done
  role_missing_disk_gb=$((role_missing * disk_gb))
  total_vcpus=$((total_vcpus + role_vcpus))
  total_ram_mb=$((total_ram_mb + role_ram_mb))
  total_disk_gb=$((total_disk_gb + role_disk_gb))
  missing_disk_gb=$((missing_disk_gb + role_missing_disk_gb))
  summary+=("${role}: count=${count} missing=${role_missing} flavor=${flavor} vcpus=${role_vcpus} ram_mb=${role_ram_mb} disk_gb=${role_disk_gb} additional_disk_gb=${role_missing_disk_gb}")
done

while IFS=$'\t' read -r name status flavor; do
  [[ -n "$name" && -n "$flavor" ]] || continue
  vcpus="$(flavor_value "$flavor" vcpus)"
  ram_mb="$(flavor_value "$flavor" ram)"
  disk_gb="$(flavor_value "$flavor" disk)"
  existing_vcpus=$((existing_vcpus + vcpus))
  existing_ram_mb=$((existing_ram_mb + ram_mb))
  existing_disk_gb=$((existing_disk_gb + disk_gb))
  existing_summary+=("${name}: status=${status} flavor=${flavor} vcpus=${vcpus} ram_mb=${ram_mb} disk_gb=${disk_gb}")
done < <(
  python3 - "$apply_prefix" "$server_list_json" <<'PY'
import json
import sys

prefix = sys.argv[1]
servers = json.loads(sys.argv[2] or "[]")
skip_statuses = {"DELETED", "SOFT_DELETED"}
for server in servers:
    name = str(server.get("Name") or "")
    status = str(server.get("Status") or "")
    flavor = str(server.get("Flavor") or "")
    if not name or not flavor:
        continue
    if name.startswith(prefix):
        continue
    if status.upper() in skip_statuses:
        continue
    print(f"{name}\t{status}\t{flavor}")
PY
)

total_after_vcpus=$((total_vcpus + existing_vcpus))
total_after_ram_mb=$((total_ram_mb + existing_ram_mb))

echo "host capacity requested target stack: vcpus=${total_vcpus} ram_mb=${total_ram_mb} disk_gb=${total_disk_gb}"
printf '  %s\n' "${summary[@]}"
echo "host capacity existing other stacks: vcpus=${existing_vcpus} ram_mb=${existing_ram_mb} disk_gb=${existing_disk_gb}"
if [[ "${#existing_summary[@]}" -gt 0 ]]; then
  printf '  %s\n' "${existing_summary[@]}"
fi
echo "host capacity total after apply: vcpus=${total_after_vcpus}/${max_guest_vcpus} ram_mb=${total_after_ram_mb}/${max_guest_ram_mb}"
echo "host capacity additional disk required: disk_gb=${missing_disk_gb}/${max_guest_disk_gb}"
if (( total_after_vcpus > max_guest_vcpus || total_after_ram_mb > max_guest_ram_mb || missing_disk_gb > max_guest_disk_gb )); then
  cat >&2 <<EOF
Host capacity preflight failed.
Requested VM resources plus existing OpenStack VMs exceed the physical host budget for this local DevStack.
Destroy another stack, lower counts/flavors, or explicitly raise HA_PRIVATE_CLOUD_HOST_MAX_GUEST_* after verifying the host can sustain it.
EOF
  exit 1
fi
PREFLIGHT_HOST_CAPACITY
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
  openstack role add --project "$target_project" --project-domain "$target_project_domain" --user "$target_username" --user-domain "$target_user_domain" admin
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
  if [[ "${HA_OPENSTACK_PROVIDER}" == "kolla" ]]; then
    return 0  # Kolla: egress는 호스트 systemd(kolla-egress-nat.service)가 담당
  fi
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
  # shellcheck disable=SC1091
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
  ensure_lxc_proxy_device horizon-proxy tcp:127.0.0.1:18081 tcp:127.0.0.1:80
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

host_has_caddy_cloudflare_dns() {
  command -v caddy >/dev/null 2>&1 || return 1
  caddy list-modules 2>/dev/null | grep -qx 'dns.providers.cloudflare'
}

install_host_caddy_if_needed() {
  if command -v caddy >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1; then
    return 0
  fi

  sudo systemctl stop apt-daily.service apt-daily-upgrade.service unattended-upgrades.service >/dev/null 2>&1 || true
  sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 \
    apt-get -o Dpkg::Lock::Timeout=900 update -qq
  sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 \
    apt-get -o Dpkg::Lock::Timeout=900 install -y -qq caddy openssl
}

ensure_internal_tls_certificate() {
  sudo install -d -m 0755 /etc/hybrid-ai/caddy
  if sudo test -s /etc/hybrid-ai/caddy/intp.me.crt && sudo test -s /etc/hybrid-ai/caddy/intp.me.key; then
    return 0
  fi

  sudo openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -keyout /etc/hybrid-ai/caddy/intp.me.key \
    -out /etc/hybrid-ai/caddy/intp.me.crt \
    -subj "/CN=*.${PRIVATE_CLOUD_BASE_DOMAIN}" \
    -addext "subjectAltName=DNS:${PRIVATE_CLOUD_BASE_DOMAIN},DNS:*.${PRIVATE_CLOUD_BASE_DOMAIN}" >/dev/null 2>&1
  sudo chmod 0644 /etc/hybrid-ai/caddy/intp.me.crt
  sudo chmod 0640 /etc/hybrid-ai/caddy/intp.me.key
  sudo chgrp caddy /etc/hybrid-ai/caddy/intp.me.key >/dev/null 2>&1 || true
}

write_caddy_environment() {
  local env_file="${LOG_DIR}/caddy.env"

  : >"${env_file}"
  write_systemd_env_line "${env_file}" HA_CADDY_ACME_EMAIL "admin@${PRIVATE_CLOUD_BASE_DOMAIN}"
  write_systemd_env_line "${env_file}" HA_OPENSTACK_DOMAIN "openstack.${PRIVATE_CLOUD_BASE_DOMAIN}"
  write_systemd_env_line "${env_file}" HA_K8S_DOMAIN "k8s.${PRIVATE_CLOUD_BASE_DOMAIN}"
  write_systemd_env_line "${env_file}" HA_GRAFANA_DOMAIN "grafana.${PRIVATE_CLOUD_BASE_DOMAIN}"
  write_systemd_env_line "${env_file}" HA_ARGOCD_DOMAIN "argocd.${PRIVATE_CLOUD_BASE_DOMAIN}"
  write_systemd_env_line "${env_file}" HA_GIT_DOMAIN "${GITLAB_DOMAIN}"
  write_systemd_env_line "${env_file}" HA_HARBOR_DOMAIN "${HARBOR_DOMAIN}"
  write_systemd_env_line "${env_file}" HA_MINIO_DOMAIN "${MINIO_DOMAIN}"
  write_systemd_env_line "${env_file}" HA_MINIO_CONSOLE_DOMAIN "${MINIO_CONSOLE_DOMAIN}"
  write_systemd_env_line "${env_file}" HA_OPENSTACK_HORIZON_UPSTREAM "127.0.0.1:18081"
  write_systemd_env_line "${env_file}" HA_K8S_DASHBOARD_UPSTREAM "127.0.0.1:18082"
  write_systemd_env_line "${env_file}" HA_GRAFANA_UPSTREAM "127.0.0.1:3000"
  write_systemd_env_line "${env_file}" HA_ARGOCD_UPSTREAM "127.0.0.1:8080"
  write_systemd_env_line "${env_file}" HA_GITLAB_UPSTREAM "127.0.0.1:${GITLAB_UPSTREAM_PORT}"
  write_systemd_env_line "${env_file}" HA_HARBOR_UPSTREAM "127.0.0.1:${HARBOR_UPSTREAM_PORT}"
  write_systemd_env_line "${env_file}" HA_MINIO_API_UPSTREAM "127.0.0.1:${MINIO_API_UPSTREAM_PORT}"
  write_systemd_env_line "${env_file}" HA_MINIO_CONSOLE_UPSTREAM "127.0.0.1:${MINIO_CONSOLE_UPSTREAM_PORT}"
  write_systemd_env_line "${env_file}" CLOUDFLARE_API_TOKEN "${CLOUDFLARE_API_TOKEN:-}"
  sudo install -d -m 0755 /etc/hybrid-ai /etc/systemd/system/caddy.service.d
  sudo install -m 0640 -o root -g root "${env_file}" /etc/hybrid-ai/caddy.env
  sudo tee /etc/systemd/system/caddy.service.d/hybrid-ai-env.conf >/dev/null <<'EOF'
[Service]
EnvironmentFile=/etc/hybrid-ai/caddy.env
EOF
}

setup_host_reverse_proxy() {
  local config_path mode

  install_host_caddy_if_needed
  write_caddy_environment

  mode="${PRIVATE_CLOUD_PROXY_TLS_MODE}"
  if [[ "$mode" == "auto" ]]; then
    if [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] && host_has_caddy_cloudflare_dns; then
      mode="cloudflare"
    else
      mode="internal"
    fi
  fi

  case "$mode" in
    cloudflare)
      if ! host_has_caddy_cloudflare_dns; then
        log "warning: Caddy lacks dns.providers.cloudflare; falling back to internal TLS"
        mode="internal"
      fi
      ;;
    internal)
      ;;
    *)
      printf 'PRIVATE_CLOUD_PROXY_TLS_MODE must be auto, cloudflare, or internal; got: %s\n' "$mode" >&2
      return 64
      ;;
  esac

  if [[ "$mode" == "cloudflare" ]]; then
    config_path="${ROOT}/private/reverse-proxy/Caddyfile.cloudflare"
  else
    ensure_internal_tls_certificate
    config_path="${ROOT}/private/reverse-proxy/Caddyfile.internal-tls"
  fi

  sudo install -m 0644 -o root -g root "${config_path}" /etc/caddy/Caddyfile
  sudo systemctl daemon-reload
  set -a
  # shellcheck disable=SC1091
  source "${LOG_DIR}/caddy.env"
  set +a
  sudo --preserve-env=HA_CADDY_ACME_EMAIL,HA_OPENSTACK_DOMAIN,HA_K8S_DOMAIN,HA_GRAFANA_DOMAIN,HA_ARGOCD_DOMAIN,HA_GIT_DOMAIN,HA_HARBOR_DOMAIN,HA_MINIO_DOMAIN,HA_MINIO_CONSOLE_DOMAIN,HA_OPENSTACK_HORIZON_UPSTREAM,HA_K8S_DASHBOARD_UPSTREAM,HA_GRAFANA_UPSTREAM,HA_ARGOCD_UPSTREAM,HA_GITLAB_UPSTREAM,HA_HARBOR_UPSTREAM,HA_MINIO_API_UPSTREAM,HA_MINIO_CONSOLE_UPSTREAM,CLOUDFLARE_API_TOKEN \
    caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
  sudo systemctl enable --now caddy
  sudo systemctl restart caddy
  log "reverse proxy ready with ${mode} TLS profile"
}

write_lxc_caddyfile() {
  local control_ip gitlab_ip harbor_ip minio_ip caddyfile

  control_ip="$(first_control_plane_ip || true)"
  gitlab_ip="$(first_gitlab_ip || true)"
  harbor_ip="$(first_harbor_ip || true)"
  minio_ip="$(first_minio_upstream_ip || true)"
  [[ -n "$control_ip" ]] || control_ip="127.0.0.1"
  [[ -n "$gitlab_ip" ]] || gitlab_ip="127.0.0.1"
  [[ -n "$harbor_ip" ]] || harbor_ip="127.0.0.1"
  [[ -n "$minio_ip" ]] || minio_ip="127.0.0.1"
  caddyfile="${LOG_DIR}/Caddyfile.lxc"

  cat >"${caddyfile}" <<EOF
{
	auto_https off
}

http://openstack.${PRIVATE_CLOUD_BASE_DOMAIN}:8088,
http://k8s.${PRIVATE_CLOUD_BASE_DOMAIN}:8088,
http://grafana.${PRIVATE_CLOUD_BASE_DOMAIN}:8088,
http://argocd.${PRIVATE_CLOUD_BASE_DOMAIN}:8088,
http://${GITLAB_DOMAIN}:8088,
http://${HARBOR_DOMAIN}:8088,
http://${MINIO_DOMAIN}:8088,
http://${MINIO_CONSOLE_DOMAIN}:8088 {
	redir https://{host}{uri} permanent
}

openstack.${PRIVATE_CLOUD_BASE_DOMAIN}:8443 {
	tls /etc/hybrid-ai/caddy/intp.me.crt /etc/hybrid-ai/caddy/intp.me.key
	encode zstd gzip
	reverse_proxy 127.0.0.1:80 {
		header_up Host {host}
		header_up X-Forwarded-Host {host}
		header_up X-Forwarded-Proto https
	}
}

k8s.${PRIVATE_CLOUD_BASE_DOMAIN}:8443 {
	tls /etc/hybrid-ai/caddy/intp.me.crt /etc/hybrid-ai/caddy/intp.me.key
	encode zstd gzip
	respond "k8s dashboard upstream is not attached to the LXC reverse proxy" 503
}

grafana.${PRIVATE_CLOUD_BASE_DOMAIN}:8443 {
	tls /etc/hybrid-ai/caddy/intp.me.crt /etc/hybrid-ai/caddy/intp.me.key
	encode zstd gzip
	respond "grafana upstream is not attached to the LXC reverse proxy" 503
}

argocd.${PRIVATE_CLOUD_BASE_DOMAIN}:8443 {
	tls /etc/hybrid-ai/caddy/intp.me.crt /etc/hybrid-ai/caddy/intp.me.key
	encode zstd gzip
	respond "argocd upstream is not attached to the LXC reverse proxy" 503
}

${GITLAB_DOMAIN}:8443 {
	tls /etc/hybrid-ai/caddy/intp.me.crt /etc/hybrid-ai/caddy/intp.me.key
	encode zstd gzip
	reverse_proxy ${gitlab_ip}:80 {
		header_up Host {host}
		header_up X-Forwarded-Host {host}
		header_up X-Forwarded-Proto https
		header_up X-Forwarded-Ssl on
		header_up X-Forwarded-Port 443
	}
}

${HARBOR_DOMAIN}:8443 {
	tls /etc/hybrid-ai/caddy/intp.me.crt /etc/hybrid-ai/caddy/intp.me.key
	encode zstd gzip
	reverse_proxy ${harbor_ip}:${HARBOR_HTTP_PORT} {
		header_up Host {host}
		header_up X-Forwarded-Host {host}
		header_up X-Forwarded-Proto https
		header_up X-Forwarded-Ssl on
		header_up X-Forwarded-Port 443
	}
}

${MINIO_DOMAIN}:8443 {
	tls /etc/hybrid-ai/caddy/intp.me.crt /etc/hybrid-ai/caddy/intp.me.key
	encode zstd gzip
	reverse_proxy ${minio_ip}:${MINIO_API_NODEPORT} {
		header_up Host {host}
		header_up X-Forwarded-Host {host}
		header_up X-Forwarded-Proto https
		header_up X-Forwarded-Ssl on
		header_up X-Forwarded-Port 443
	}
}

${MINIO_CONSOLE_DOMAIN}:8443 {
	tls /etc/hybrid-ai/caddy/intp.me.crt /etc/hybrid-ai/caddy/intp.me.key
	encode zstd gzip
	reverse_proxy ${minio_ip}:${MINIO_CONSOLE_NODEPORT} {
		header_up Host {host}
		header_up X-Forwarded-Host {host}
		header_up X-Forwarded-Proto https
		header_up X-Forwarded-Ssl on
		header_up X-Forwarded-Port 443
	}
}
EOF
  printf '%s\n' "$caddyfile"
}

setup_lxc_reverse_proxy() {
  local caddyfile

  ensure_devstack_container_running
  caddyfile="$(write_lxc_caddyfile)"
  lxc exec ha-openstack -- bash -s -- "${PRIVATE_CLOUD_BASE_DOMAIN}" <<'REMOTE'
set -euo pipefail
base_domain="$1"
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
systemctl stop apt-daily.service apt-daily-upgrade.service unattended-upgrades.service >/dev/null 2>&1 || true
if ! command -v caddy >/dev/null 2>&1 || ! command -v openssl >/dev/null 2>&1; then
  apt-get -o Dpkg::Lock::Timeout=900 update -qq
  apt-get -o Dpkg::Lock::Timeout=900 install -y -qq caddy openssl
fi
install -d -m 0755 /etc/hybrid-ai/caddy /etc/caddy
if [[ ! -s /etc/hybrid-ai/caddy/intp.me.crt || ! -s /etc/hybrid-ai/caddy/intp.me.key ]]; then
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -keyout /etc/hybrid-ai/caddy/intp.me.key \
    -out /etc/hybrid-ai/caddy/intp.me.crt \
    -subj "/CN=*.${base_domain}" \
    -addext "subjectAltName=DNS:${base_domain},DNS:*.${base_domain}" >/dev/null 2>&1
  chmod 0644 /etc/hybrid-ai/caddy/intp.me.crt
  chmod 0640 /etc/hybrid-ai/caddy/intp.me.key
  chgrp caddy /etc/hybrid-ai/caddy/intp.me.key >/dev/null 2>&1 || true
fi
REMOTE
  lxc exec ha-openstack -- tee /etc/caddy/Caddyfile >/dev/null <"${caddyfile}"
  lxc exec ha-openstack -- caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
  lxc exec ha-openstack -- systemctl enable --now caddy
  lxc exec ha-openstack -- systemctl restart caddy

  ensure_lxc_proxy_device hybrid-ai-public-http tcp:0.0.0.0:80 tcp:127.0.0.1:8088
  ensure_lxc_proxy_device hybrid-ai-public-https tcp:0.0.0.0:443 tcp:127.0.0.1:8443
  log "reverse proxy ready with LXC internal TLS fallback"
}

ensure_tf_output_json_available() {
  if [[ -s "${TF_OUTPUT_JSON}" ]]; then
    return 0
  fi

  (
    cd "${ROOT}/private/openstack"
    terraform output -json >"${TF_OUTPUT_JSON}"
  ) >/dev/null 2>&1
}

detect_tailscale_ip() {
  local ip
  if [[ -n "${PRIVATE_CLOUD_TAILSCALE_IP:-}" ]]; then
    printf '%s\n' "${PRIVATE_CLOUD_TAILSCALE_IP}"
    return 0
  fi
  if [[ -n "${HA_TAILSCALE_IP:-}" ]]; then
    printf '%s\n' "${HA_TAILSCALE_IP}"
    return 0
  fi

  if command -v tailscale >/dev/null 2>&1; then
    ip="$(tailscale ip -4 2>/dev/null | head -n 1 || true)"
    if [[ -n "${ip}" ]]; then
      printf '%s\n' "${ip}"
      return 0
    fi
  fi

  return 1
}

sync_cloudflare_dns() {
  local tailscale_ip internal_dns_enabled internal_dns_records

  if [[ -z "${CLOUDFLARE_API_TOKEN:-}" || -z "${CLOUDFLARE_ZONE_ID:-}" ]]; then
    log "skip Cloudflare DNS sync: CLOUDFLARE_API_TOKEN or CLOUDFLARE_ZONE_ID is missing"
    return 0
  fi

  tailscale_ip="$(detect_tailscale_ip || true)"
  if [[ -z "${tailscale_ip}" ]]; then
    log "skip Cloudflare DNS sync: PRIVATE_CLOUD_TAILSCALE_IP is missing and tailscale ip is unavailable"
    return 0
  fi

  export PRIVATE_CLOUD_TAILSCALE_IP="${tailscale_ip}"
  export PRIVATE_CLOUD_BASE_DOMAIN
  export PRIVATE_CLOUD_DNS_TTL
  export PRIVATE_CLOUD_DNS_SERVICES
  export PRIVATE_CLOUD_DNS_SSH_ALIASES
  internal_dns_enabled="$(tf_bool_value PRIVATE_CLOUD_INTERNAL_DNS_ENABLED "${PRIVATE_CLOUD_INTERNAL_DNS_ENABLED}")"
  export PRIVATE_CLOUD_INTERNAL_DNS_ENABLED="${internal_dns_enabled}"
  export PRIVATE_CLOUD_INTERNAL_DNS_ZONE
  if [[ "${internal_dns_enabled}" == "true" ]]; then
    internal_dns_records="$(internal_dns_records_from_inventory || true)"
    if [[ -z "${internal_dns_records}" ]]; then
      log "warning: internal DNS is enabled, but no internal records are available"
    fi
    export PRIVATE_CLOUD_INTERNAL_DNS_RECORDS="${internal_dns_records}"
  else
    export PRIVATE_CLOUD_INTERNAL_DNS_RECORDS=""
  fi

  python3 "${ROOT}/private/reverse-proxy/cloudflare_dns.py" --apply
  log "Cloudflare DNS records synced for ${PRIVATE_CLOUD_BASE_DOMAIN}"
}

ssh_tunnel_listen_address() {
  case "${PRIVATE_CLOUD_SSH_TUNNEL_LISTEN_ADDRESS}" in
    auto)
      detect_tailscale_ip || printf '0.0.0.0\n'
      ;;
    *)
      printf '%s\n' "${PRIVATE_CLOUD_SSH_TUNNEL_LISTEN_ADDRESS}"
      ;;
  esac
}

ensure_openstack_private_route() {
  local private_cidr router_name gateway

  if [[ "${HA_OPENSTACK_PROVIDER}" == "kolla" ]]; then
    log "skip private route setup: Kolla provider (VM 접속은 qdhcp netns ProxyCommand 경유)"
    return 0
  fi

  if ! command -v lxc >/dev/null 2>&1 || ! lxc info ha-openstack >/dev/null 2>&1; then
    log "skip private route setup: ha-openstack container is unavailable"
    return 0
  fi

  if ! ensure_tf_output_json_available; then
    log "skip private route setup: Terraform output is unavailable"
    return 0
  fi

  private_cidr="$(python3 - "${TF_OUTPUT_JSON}" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)
print(data.get("private_network_cidr", {}).get("value", "10.42.0.0/24"))
PY
)"
  router_name="$(terraform_apply_prefix)-router"
  gateway="$(lxc exec ha-openstack -- sudo -u stack -H bash -s -- "$router_name" <<'REMOTE' 2>/dev/null || true
set -euo pipefail
router_name="$1"
cd /opt/stack/devstack
set +u
source openrc admin admin >/dev/null
set -u
openstack router show "$router_name" -f json -c external_gateway_info | python3 -c '
import json
import sys
data = json.load(sys.stdin).get("external_gateway_info") or {}
if isinstance(data, str):
    data = json.loads(data)
fixed_ips = data.get("external_fixed_ips") or []
for fixed_ip in fixed_ips:
    ip = fixed_ip.get("ip_address", "")
    if "." in ip:
        print(ip)
        break
'
REMOTE
)"

  if [[ -z "${gateway}" ]]; then
    log "skip private route setup: router external gateway is unavailable"
    return 0
  fi

  lxc exec ha-openstack -- ip route replace "${private_cidr}" via "${gateway}" dev br-ex
  log "private route ready in ha-openstack: ${private_cidr} via ${gateway}"
}

setup_openstack_ssh_tunnels() {
  local inventory listen_address base_domain
  [[ "${PRIVATE_CLOUD_SSH_TUNNELS_ENABLED}" == "true" ]] || return 0

  if ! ensure_tf_output_json_available; then
    log "skip OpenStack SSH tunnels: Terraform output is unavailable"
    return 0
  fi

  inventory="${LOG_DIR}/ssh-tunnels.tsv"
  python3 - \
    "${TF_OUTPUT_JSON}" \
    "${PRIVATE_CLOUD_SSH_CONTROL_PORT}" \
    "${PRIVATE_CLOUD_SSH_BUILD_PORT}" \
    "${PRIVATE_CLOUD_SSH_GPU_PORT}" \
    "${PRIVATE_CLOUD_SSH_GITLAB_PORT}" \
    "${PRIVATE_CLOUD_SSH_HARBOR_PORT}" >"${inventory}" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)

roles = (
    ("control", "control_plane_nodes", "PRIVATE_CLOUD_SSH_CONTROL_PORT", sys.argv[2]),
    ("build", "build_worker_nodes", "PRIVATE_CLOUD_SSH_BUILD_PORT", sys.argv[3]),
    ("gpu", "gpu_worker_nodes", "PRIVATE_CLOUD_SSH_GPU_PORT", sys.argv[4]),
    ("gitlab", "gitlab_nodes", "PRIVATE_CLOUD_SSH_GITLAB_PORT", sys.argv[5]),
    ("harbor", "harbor_nodes", "PRIVATE_CLOUD_SSH_HARBOR_PORT", sys.argv[6]),
)

for role, key, port_name, port_value in roles:
    port = port_value.strip()
    if not port:
        continue
    try:
        port_number = int(port)
    except ValueError:
        raise SystemExit(f"{port_name} must be a TCP port number, got: {port}")
    if port_number < 1 or port_number > 65535:
        raise SystemExit(f"{port_name} must be between 1 and 65535, got: {port}")
    nodes = data.get(key, {}).get("value", [])
    if not nodes:
        continue
    node = nodes[0]
    ip = node.get("floating_ip") or node.get("private_ip")
    if not ip:
        continue
    print(f"{role}\t{port}\t{ip}\t{node.get('name', '')}")
PY

  if [[ ! -s "${inventory}" ]]; then
    log "skip OpenStack SSH tunnels: no tunnelable VM nodes found"
    return 0
  fi

  listen_address="$(ssh_tunnel_listen_address)"
  base_domain="${PRIVATE_CLOUD_BASE_DOMAIN:-intp.me}"

  while IFS=$'\t' read -r role port ip name; do
    ensure_lxc_proxy_device "hybrid-ai-ssh-${role}" "tcp:${listen_address}:${port}" "tcp:${ip}:22"
    log "ssh tunnel ready: ${role}-ssh.${base_domain}:${port} -> ${name} (${ip}:22)"
  done <"${inventory}"
}

setup_minio_entrypoints() {
  local minio_ip
  [[ "${MINIO_PROXY_ENABLED}" == "true" ]] || return 0

  if ! ensure_tf_output_json_available; then
    log "skip MinIO entrypoints: Terraform output is unavailable"
    return 0
  fi

  minio_ip="$(first_minio_upstream_ip || true)"
  if [[ -z "${minio_ip}" ]]; then
    log "skip MinIO entrypoints: MinIO upstream IP is unavailable"
    return 0
  fi

  ensure_lxc_proxy_device minio-api-proxy "tcp:127.0.0.1:${MINIO_API_UPSTREAM_PORT}" "tcp:${minio_ip}:${MINIO_API_NODEPORT}"
  ensure_lxc_proxy_device minio-console-proxy "tcp:127.0.0.1:${MINIO_CONSOLE_UPSTREAM_PORT}" "tcp:${minio_ip}:${MINIO_CONSOLE_NODEPORT}"
  log "MinIO entrypoints ready: ${MINIO_DOMAIN} -> ${minio_ip}:${MINIO_API_NODEPORT}, ${MINIO_CONSOLE_DOMAIN} -> ${minio_ip}:${MINIO_CONSOLE_NODEPORT}"
}

setup_reverse_proxy() {
  [[ "${PRIVATE_CLOUD_PROXY_ENABLED}" == "true" ]] || return 0

  if sudo -n true >/dev/null 2>&1; then
    setup_host_reverse_proxy
  else
    log "host sudo is unavailable; using LXC reverse proxy fallback"
    setup_lxc_reverse_proxy
  fi
}

# ── Kolla provider 함수 (DevStack lxc-exec 경로 대체) ───────────────────
# Kolla openrc로 openstack 실행 (DevStack의 'lxc exec ha-openstack -- source openrc' 대체)
kolla_os() {
  (
    set -euo pipefail
    # shellcheck disable=SC1091
    source "${HA_KOLLA_VENV}/bin/activate"
    # shellcheck disable=SC1091
    source "${HA_KOLLA_ADMIN_OPENRC}"
    openstack "$@"
  )
}

# terraform이 참조하는 flavor 보장 (Kolla 네이티브, 멱등 — 있으면 no-op)
_kolla_ensure_flavor() {
  local name="$1" ram="$2" vcpus="$3" disk="$4"
  if kolla_os flavor show "$name" >/dev/null 2>&1; then
    kolla_os flavor set --property "hw_rng:allowed=True" "$name" >/dev/null 2>&1 || true
    return 0
  fi
  kolla_os flavor create --ram "$ram" --vcpus "$vcpus" --disk "$disk" "$name" >/dev/null
  kolla_os flavor set --property "hw_rng:allowed=True" "$name" >/dev/null 2>&1 || true
}

ensure_flavors_kolla() {
  _kolla_ensure_flavor "${HA_DEVSTACK_CONTROL_FLAVOR_NAME}" "${HA_DEVSTACK_CONTROL_FLAVOR_RAM}" "${HA_DEVSTACK_CONTROL_FLAVOR_VCPUS}" "${HA_DEVSTACK_CONTROL_FLAVOR_DISK}"
  _kolla_ensure_flavor "${HA_DEVSTACK_WORKER_FLAVOR_NAME}" "${HA_DEVSTACK_WORKER_FLAVOR_RAM}" "${HA_DEVSTACK_WORKER_FLAVOR_VCPUS}" "${HA_DEVSTACK_WORKER_FLAVOR_DISK}"
  _kolla_ensure_flavor "${HA_DEVSTACK_GITLAB_FLAVOR_NAME}" "${HA_DEVSTACK_GITLAB_FLAVOR_RAM}" "${HA_DEVSTACK_GITLAB_FLAVOR_VCPUS}" "${HA_DEVSTACK_GITLAB_FLAVOR_DISK}"
  _kolla_ensure_flavor "${HA_DEVSTACK_HARBOR_FLAVOR_NAME}" "${HA_DEVSTACK_HARBOR_FLAVOR_RAM}" "${HA_DEVSTACK_HARBOR_FLAVOR_VCPUS}" "${HA_DEVSTACK_HARBOR_FLAVOR_DISK}"
  _kolla_ensure_flavor "${HA_OPENSTACK_GPU_FLAVOR_NAME}" "${HA_OPENSTACK_GPU_FLAVOR_RAM}" "${HA_OPENSTACK_GPU_FLAVOR_VCPUS}" "${HA_OPENSTACK_GPU_FLAVOR_DISK}"
  kolla_os flavor set --property "pci_passthrough:alias=nvidia-gpu:1" --property "hw:pci_numa_affinity_policy=preferred" "${HA_OPENSTACK_GPU_FLAVOR_NAME}" >/dev/null 2>&1 || true
}

# apply 모드: Kolla 헬스 검증 (재배포·컨테이너 조작 없음 = 멱등·무파괴)
kolla_apply_check() {
  [[ -f "${HA_KOLLA_ADMIN_OPENRC}" ]] || { log "error: ${HA_KOLLA_ADMIN_OPENRC} 없음 — deploy-kolla.sh로 먼저 배포 필요"; return 1; }
  [[ -d "${HA_KOLLA_VENV}" ]] || { log "error: kolla venv(${HA_KOLLA_VENV}) 없음 — deploy-kolla.sh 먼저"; return 1; }
  if kolla_os endpoint list >/dev/null 2>&1; then
    log "Kolla OpenStack 정상 (keystone endpoint 응답)"
  else
    log "error: Kolla OpenStack 미응답 — 컨트롤플레인 점검 필요"
    return 1
  fi
  ensure_flavors_kolla
}

# reinstall 모드: Kolla 배포 스크립트 호출 (deploy-kolla.sh가 멱등 처리)
kolla_reinstall() {
  log "Kolla 배포/재구성: ${HA_KOLLA_DEPLOY_SCRIPT}"
  bash "${HA_KOLLA_DEPLOY_SCRIPT}"
  ensure_flavors_kolla
}

devstack_reinstall() {
  local product_id
  create_devstack_container
  if [[ "$DEVSTACK_CONTAINER_RESTORED_FROM_CACHE" != "true" ]]; then
    install_devstack_prereqs
    product_id="$(detect_gpu_product)"
    bind_gpu_vfio "${product_id}"
    clone_and_configure_devstack "${product_id}"
    run_devstack
  else
    product_id="$(detect_gpu_product)"
    bind_gpu_vfio "${product_id}"
  fi
  ensure_horizon_proxy
  ensure_flavors
  configure_gpu_passthrough
  ensure_images
  sync_openstack_login_user
  ensure_devstack_egress
  configure_horizon_proxy_settings
  verify_devstack
  if [[ "$DEVSTACK_CONTAINER_RESTORED_FROM_CACHE" != "true" ]]; then
    refresh_devstack_container_cache
  fi
}

devstack_apply_check() {
  local product_id
  ensure_devstack_container_running
  verify_devstack
  ensure_horizon_proxy
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
  configure_horizon_proxy_settings
  verify_devstack
}

devstack_openrc_password() {
  command -v lxc >/dev/null 2>&1 || return 0
  # shellcheck disable=SC2016
  lxc exec ha-openstack -- sudo -u stack -H bash -lc 'cd /opt/stack/devstack && set +u && source openrc admin admin >/dev/null && printf "%s" "${OS_PASSWORD:-}"' 2>/dev/null || true
}

use_local_devstack_openstack_env() {
  if [[ "${HA_OPENSTACK_PROVIDER}" == "kolla" ]]; then
    # Kolla Keystone 인증: admin-openrc(URL/project/domains/admin) 기반 + keystone v3 보장
    set +u
    # shellcheck disable=SC1090
    . "${HA_KOLLA_ADMIN_OPENRC}" >/dev/null 2>&1 || true
    set -u
    [[ -n "${OS_AUTH_URL:-}" ]] || export OS_AUTH_URL="http://192.168.0.250:5000"
    [[ "${OS_AUTH_URL}" == */v3 ]] || export OS_AUTH_URL="${OS_AUTH_URL%/}/v3"
    # CI 로그인 자격(3stacks 등)이 제공되면 우선 적용
    if [[ "${HA_OPENSTACK_LOGIN_PASSWORD_INPUT_PROVIDED:-false}" == "true" ]]; then
      export OS_USERNAME="${HA_OPENSTACK_LOGIN_USERNAME:-${OS_USERNAME:-3stacks}}"
      export OS_PASSWORD="${HA_OPENSTACK_LOGIN_PASSWORD}"
      export OS_PROJECT_NAME="${HA_OPENSTACK_LOGIN_PROJECT_NAME:-${OS_PROJECT_NAME:-admin}}"
      export OS_USER_DOMAIN_NAME="${HA_OPENSTACK_LOGIN_USER_DOMAIN_NAME:-${OS_USER_DOMAIN_NAME:-Default}}"
      export OS_PROJECT_DOMAIN_NAME="${HA_OPENSTACK_LOGIN_PROJECT_DOMAIN_NAME:-${OS_PROJECT_DOMAIN_NAME:-Default}}"
    fi
    export OS_REGION_NAME="${OS_REGION_NAME:-RegionOne}"
    export OS_IDENTITY_API_VERSION=3
    return
  fi
  export OS_AUTH_URL="${HA_DEVSTACK_AUTH_URL:-http://127.0.0.1:18081/identity/v3}"
  export OS_USERNAME="${HA_OPENSTACK_LOGIN_USERNAME:-${HA_DEVSTACK_USERNAME:-admin}}"
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
  if [[ "${OS_USERNAME}" == "${HA_OPENSTACK_LOGIN_USERNAME}" \
    && "${HA_OPENSTACK_LOGIN_PASSWORD_INPUT_PROVIDED}" == "true" ]]; then
    devstack_password="${HA_OPENSTACK_LOGIN_PASSWORD}"
  fi
  export OS_PASSWORD="$devstack_password"
  export OS_PROJECT_NAME="${HA_OPENSTACK_LOGIN_PROJECT_NAME:-${HA_DEVSTACK_PROJECT_NAME:-admin}}"
  export OS_USER_DOMAIN_NAME="${HA_OPENSTACK_LOGIN_USER_DOMAIN_NAME:-${HA_DEVSTACK_USER_DOMAIN_NAME:-Default}}"
  export OS_PROJECT_DOMAIN_NAME="${HA_OPENSTACK_LOGIN_PROJECT_DOMAIN_NAME:-${HA_DEVSTACK_PROJECT_DOMAIN_NAME:-Default}}"
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
  local effective_control_plane_count effective_build_worker_count effective_gpu_worker_count effective_gitlab_count effective_harbor_count
  local effective_install_node_dependencies
  local effective_control_plane_flavor effective_build_worker_flavor effective_gpu_worker_flavor effective_gitlab_flavor effective_harbor_flavor
  local key_pair_name
  local apply_prefix
  local assign_floating_ips
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
  effective_control_plane_count="$(terraform_var_int control_plane_count 1)"
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
  if [[ "${HA_OPENSTACK_PROVIDER}" == "kolla" ]]; then
    # Kolla: 외부망은 ext-net (DevStack 'public' 대체), FIP 미사용(접속=in-cluster cloudflared)
    local _extnet="${HA_KOLLA_EXTERNAL_NETWORK:-ext-net}"
    public_network_id="$(kolla_os network show "${_extnet}" -f value -c id)"
    public_subnet_id="$(kolla_os subnet list --network "${_extnet}" --ip-version 4 -f value -c ID | head -n 1)"
    public_subnet_cidr="$(kolla_os subnet show "${public_subnet_id}" -f value -c cidr)"
    # Kolla: OpenStack Floating IP로 호스트→VM 직접 접근 (DevStack LXD proxy 대체)
    assign_floating_ips="$(tf_bool_value PRIVATE_CLOUD_ASSIGN_FLOATING_IPS "${PRIVATE_CLOUD_ASSIGN_FLOATING_IPS}")"
    fip_pool="${_extnet}"
  else
    public_network_id="$(lxc exec ha-openstack -- sudo -u stack -H bash -lc 'cd /opt/stack/devstack && set +u && source openrc admin admin >/dev/null && set -u && openstack network show public -f value -c id')"
    public_subnet_id="$(lxc exec ha-openstack -- sudo -u stack -H bash -lc 'cd /opt/stack/devstack && set +u && source openrc admin admin >/dev/null && set -u && openstack subnet list --network public --ip-version 4 -f value -c ID | head -n 1')"
    public_subnet_cidr="$(lxc exec ha-openstack -- sudo -u stack -H bash -lc "cd /opt/stack/devstack && set +u && source openrc admin admin >/dev/null && set -u && openstack subnet show '${public_subnet_id}' -f value -c cidr")"
    assign_floating_ips="$(tf_bool_value PRIVATE_CLOUD_ASSIGN_FLOATING_IPS "${PRIVATE_CLOUD_ASSIGN_FLOATING_IPS}")"
    fip_pool="public"
  fi
  {
    printf 'external_network_id = "%s"\n' "$public_network_id"
    printf 'floating_ip_pool = "%s"\n' "${fip_pool:-public}"
    printf 'assign_floating_ips = %s\n' "$assign_floating_ips"
    printf 'install_node_dependencies = %s\n' "${effective_install_node_dependencies}"
    printf 'ssh_allowed_cidrs = ["%s"]\n' "$public_subnet_cidr"
    printf 'gitlab_http_allowed_cidrs = ["%s"]\n' "$public_subnet_cidr"
    printf 'minio_nodeport_allowed_cidrs = ["%s"]\n' "$public_subnet_cidr"
    printf 'control_plane_count = %s\n' "${effective_control_plane_count}"
    printf 'control_plane_image_name = "%s"\n' "${TF_VAR_control_plane_image_name}"
    printf 'control_plane_flavor_name = "%s"\n' "${effective_control_plane_flavor}"
    write_tf_string_list control_plane_private_ips "${HA_DEVSTACK_CONTROL_PLANE_PRIVATE_IPS}"
    printf 'build_worker_count = %s\n' "${effective_build_worker_count}"
    printf 'build_worker_image_name = "%s"\n' "${TF_VAR_build_worker_image_name}"
    printf 'build_worker_flavor_name = "%s"\n' "${effective_build_worker_flavor}"
    write_tf_string_list build_worker_private_ips "${HA_DEVSTACK_BUILD_WORKER_PRIVATE_IPS}"
    printf 'gpu_worker_count = %s\n' "${effective_gpu_worker_count}"
    printf 'gpu_worker_image_name = "%s"\n' "${TF_VAR_gpu_worker_image_name}"
    printf 'gpu_worker_flavor_name = "%s"\n' "${effective_gpu_worker_flavor}"
    write_tf_string_list gpu_worker_private_ips "${HA_DEVSTACK_GPU_WORKER_PRIVATE_IPS}"
    printf 'gitlab_count = %s\n' "${effective_gitlab_count}"
    printf 'gitlab_image_name = "%s"\n' "${TF_VAR_gitlab_image_name}"
    printf 'gitlab_flavor_name = "%s"\n' "${effective_gitlab_flavor}"
    write_tf_string_list gitlab_private_ips "${HA_DEVSTACK_GITLAB_PRIVATE_IPS}"
    printf 'gitlab_container_image = "%s"\n' "${TF_VAR_gitlab_container_image}"
    printf 'harbor_count = %s\n' "${effective_harbor_count}"
    printf 'harbor_image_name = "%s"\n' "${TF_VAR_harbor_image_name}"
    printf 'harbor_flavor_name = "%s"\n' "${effective_harbor_flavor}"
    write_tf_string_list harbor_private_ips "${HA_DEVSTACK_HARBOR_PRIVATE_IPS}"
    printf 'harbor_http_allowed_cidrs = ["%s"]\n' "$public_subnet_cidr"
  } >zz-local-devstack.auto.tfvars
  cleanup_openstack_orphans_before_apply
  preflight_host_capacity \
    "${apply_prefix}" \
    "${effective_control_plane_count}" "${effective_control_plane_flavor}" \
    "${effective_build_worker_count}" "${effective_build_worker_flavor}" \
    "${effective_gpu_worker_count}" "${effective_gpu_worker_flavor}" \
    "${effective_gitlab_count}" "${effective_gitlab_flavor}" \
    "${effective_harbor_count}" "${effective_harbor_flavor}"
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
  guard_terraform_plan_deletes
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
  ensure_openstack_private_route
  write_ssh_config
  python3 - "${TF_OUTPUT_JSON}" >"${LOG_DIR}/node-inventory.txt" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)
for key in ("control_plane_nodes", "build_worker_nodes", "gpu_worker_nodes", "harbor_nodes"):
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

write_role_node_inventory() {
  local output="$1"
  local tf_key="$2"

  python3 - "${TF_OUTPUT_JSON}" "$tf_key" >"$output" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)

for node in data.get(sys.argv[2], {}).get("value", []):
    ip = node.get("floating_ip") or node.get("private_ip")
    if ip:
        print(f"{ip}\t{node.get('name', '')}")
PY
}

inspect_one_node() {
  local ip="$1"
  local name="$2"
  local role="$3"

  wait_one_node_ssh "$ip" "$name"
  ssh -F "${SSH_CONFIG}" -o ConnectTimeout=10 "$ip" bash -s -- "$role" "$name" <<'REMOTE'
set -euo pipefail
role="$1"
name="$2"
cloud_init_status=0
cloud_init_output=""
printf 'vm_role=%s\n' "$role"
printf 'vm_name=%s\n' "$name"
printf 'hostname=%s\n' "$(hostname -f 2>/dev/null || hostname)"
printf 'kernel=%s\n' "$(uname -r)"
printf 'uptime='
uptime || true
printf '\n== cloud-init ==\n'
if command -v cloud-init >/dev/null 2>&1; then
  cloud_init_output="$(cloud-init status --wait --long 2>&1)" || cloud_init_status=$?
  printf '%s\n' "$cloud_init_output"
  if grep -Eq '^(status|extended_status): error' <<<"$cloud_init_output"; then
    cloud_init_status=1
  fi
else
  echo "cloud-init not installed"
fi
printf '\n== memory ==\n'
free -h || true
printf '\n== filesystems ==\n'
df -h / /var/lib/docker /srv/gitlab /data 2>/dev/null || df -h /
printf '\n== block devices ==\n'
if command -v lsblk >/dev/null 2>&1; then
  lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS
fi
printf '\n== io sample ==\n'
if command -v iostat >/dev/null 2>&1; then
  iostat -xz 1 2 || true
else
  echo "iostat not installed"
fi
printf '\n== failed units ==\n'
systemctl --failed --no-pager || true
printf '\n== cloud-init output (tail) ==\n'
sudo tail -n 40 /var/log/cloud-init-output.log 2>/dev/null || echo "no cloud-init output log"
for bootstrap_log in /var/log/hybrid-ai-*.log; do
  [[ -f "$bootstrap_log" ]] || continue
  printf '\n== %s (tail) ==\n' "$bootstrap_log"
  sudo tail -n 40 "$bootstrap_log" || true
done
if [[ "$role" == "gpu-worker" ]]; then
  gpu_dependency_status=0
  printf '\n== gpu dependency check ==\n'
  if sudo test -x /usr/local/sbin/hybrid-ai-dependency-check; then
    sudo /usr/local/sbin/hybrid-ai-dependency-check || gpu_dependency_status=$?
  else
    echo "missing GPU dependency check: /usr/local/sbin/hybrid-ai-dependency-check" >&2
    gpu_dependency_status=1
  fi
  if [[ "$cloud_init_status" -ne 0 && "$gpu_dependency_status" -eq 0 ]]; then
    echo "cloud-init reported a previous error, but the GPU runtime dependency check passed"
  fi
  exit "$gpu_dependency_status"
fi
exit "$cloud_init_status"
REMOTE
}

wait_role_nodes_ssh() {
  local role="$1"
  local tf_key="$2"
  local inventory="${LOG_DIR}/${role}-inventory.tsv"
  local pids=()
  local pid rc=0

  ensure_openstack_private_route
  write_ssh_config
  write_role_node_inventory "$inventory" "$tf_key"
  if [[ ! -s "$inventory" ]]; then
    log "SKIP ${role}: no nodes in Terraform output key ${tf_key}"
    return 0
  fi

  while IFS=$'\t' read -r ip name; do
    ( inspect_one_node "$ip" "$name" "$role" ) &
    pids+=("$!")
  done <"$inventory"
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
    print(nodes[0].get("private_ip") or nodes[0].get("floating_ip") or "")
PY
}

first_build_worker_ip() {
  python3 - "${TF_OUTPUT_JSON}" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)
nodes = data.get("build_worker_nodes", {}).get("value", [])
if nodes:
    print(nodes[0].get("private_ip") or nodes[0].get("floating_ip") or "")
PY
}

first_minio_upstream_ip() {
  local ip
  ip="$(first_build_worker_ip || true)"
  if [[ -z "${ip}" ]]; then
    ip="$(first_control_plane_ip || true)"
  fi
  printf '%s\n' "${ip}"
}

first_gitlab_ip() {
  python3 - "${TF_OUTPUT_JSON}" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)
nodes = data.get("gitlab_nodes", {}).get("value", [])
if nodes:
    print(nodes[0].get("private_ip") or nodes[0].get("floating_ip") or "")
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
    print(nodes[0].get("private_ip") or nodes[0].get("floating_ip") or "")
PY
}

internal_dns_records_from_inventory() {
  if [[ -n "${PRIVATE_CLOUD_INTERNAL_DNS_RECORDS:-}" ]]; then
    printf '%s\n' "${PRIVATE_CLOUD_INTERNAL_DNS_RECORDS}"
    return 0
  fi
  ensure_tf_output_json_available || return 0

  python3 - "${TF_OUTPUT_JSON}" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)

roles = (
    ("control", "control_plane_nodes"),
    ("build", "build_worker_nodes"),
    ("gpu", "gpu_worker_nodes"),
    ("gitlab", "gitlab_nodes"),
    ("harbor", "harbor_nodes"),
)

records = []
first_ips = {}
for label, key in roles:
    nodes = data.get(key, {}).get("value", [])
    if not nodes:
        continue
    ip = nodes[0].get("private_ip")
    if not ip:
        continue
    first_ips[label] = ip
    records.append(f"{label}={ip}")

if "control" in first_ips:
    records.append(f"k8s-api={first_ips['control']}")
    records.append(f"nfs={first_ips['control']}")
if "build" in first_ips:
    records.append(f"minio={first_ips['build']}")
    records.append(f"minio-console={first_ips['build']}")

print(",".join(records))
PY
}

start_kubectl_tunnel() {
  local first_cp_ip
  ensure_openstack_private_route
  first_cp_ip="$(first_control_plane_ip)"
  [[ -n "${first_cp_ip}" ]] || return 1
  pgrep -f "ssh .*127.0.0.1:${HA_KUBECTL_TUNNEL_PORT}:127.0.0.1:6443" | xargs -r kill || true
  ssh -F "${SSH_CONFIG}" -fN -o ExitOnForwardFailure=yes \
    -L "127.0.0.1:${HA_KUBECTL_TUNNEL_PORT}:127.0.0.1:6443" \
    "${first_cp_ip}" </dev/null >/dev/null 2>&1
}

bootstrap_k8s() {
  wait_nodes_ssh
  export HA_OPENSTACK_TF_OUTPUT_JSON="${TF_OUTPUT_JSON}"
  export HA_OPENSTACK_SSH_KEY="${SSH_KEY}"
  if [[ "${HA_OPENSTACK_PROVIDER}" == "kolla" ]]; then
    # Kolla: tenant VM은 qdhcp netns nc 래퍼 경유 (DevStack lxc 대체)
    export HA_OPENSTACK_SSH_PROXY_NETNS_NC="${HA_KOLLA_NETNS_NC}"
  else
    export HA_OPENSTACK_SSH_PROXY_CONTAINER="ha-openstack"
  fi
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
  apply_gpu_worker_resources
}

apply_gpu_worker_resources() {
  local gpu_node_count
  gpu_node_count="$(kubectl get nodes -l hybrid-ai.io/accelerator=nvidia --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')"
  if [[ "${gpu_node_count}" == "0" ]]; then
    log "skipping GPU worker resources; no NVIDIA GPU node labels found"
    return 0
  fi

  kubectl apply -k "${ROOT}/private/gpu-worker"
  kubectl -n kube-system rollout status daemonset/nvidia-device-plugin-daemonset --timeout=600s
  kubectl -n kube-system rollout status daemonset/gpu-image-prepuller --timeout=900s
  kubectl get nodes -l hybrid-ai.io/accelerator=nvidia \
    -o jsonpath='{range .items[*]}{.metadata.name}{" nvidia.com/gpu capacity="}{.status.capacity.nvidia\.com/gpu}{" allocatable="}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}'
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
nfs_ssh_ip = control_nodes[0].get("private_ip") or control_nodes[0].get("floating_ip")
print(f"NFS_SERVER_IP={nfs_server_ip}")
print(f"PRIVATE_NETWORK_CIDR={private_network_cidr}")
print(f"NFS_SSH_IP={nfs_ssh_ip}")
PY
}

prepare_nfs_server() {
  # shellcheck disable=SC1091
  source "${LOG_DIR}/storage.env"
  ssh -F "${SSH_CONFIG}" "${NFS_SSH_IP}" bash -s -- "${PRIVATE_NETWORK_CIDR}" <<'REMOTE'
set -euo pipefail
cidr="$1"
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
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
  ensure_openstack_private_route
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
  kubectl -n minio-operator patch deployment minio-operator --type=merge -p '{"spec":{"template":{"spec":{"dnsConfig":{"options":[{"name":"ndots","value":"1"}]}}}}}'
  kubectl wait --for=condition=Established crd/tenants.minio.min.io --timeout=300s
  kubectl -n minio-operator rollout status deployment/minio-operator --timeout=600s
  kubectl create namespace minio-tenant --dry-run=client -o yaml | kubectl apply -f -
  existing_minio_root_user="$(kubectl -n minio-tenant get secret minio-creds-secret -o jsonpath='{.data.accessKey}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  existing_minio_root_password="$(kubectl -n minio-tenant get secret minio-creds-secret -o jsonpath='{.data.secretKey}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  existing_minio_console_user="$(kubectl -n minio-tenant get secret model-admin -o jsonpath='{.data.CONSOLE_ACCESS_KEY}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  existing_minio_console_password="$(kubectl -n minio-tenant get secret model-admin -o jsonpath='{.data.CONSOLE_SECRET_KEY}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  minio_root_user="${MINIO_ROOT_USER:-${existing_minio_root_user:-3stacks}}"
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
  minio_console_user="${MINIO_CONSOLE_USER:-${existing_minio_console_user:-model-admin}}"
  minio_console_password="${MINIO_CONSOLE_PASSWORD:-${existing_minio_console_password:-}}"
  if [[ "${minio_console_user}" == "${minio_root_user}" ]]; then
    log "warning: MinIO console user matched root user; using model-admin to satisfy MinIO tenant user constraints"
    minio_console_user="model-admin"
    if [[ -z "${MINIO_CONSOLE_PASSWORD}" || "${minio_console_password}" == "${minio_root_password}" ]]; then
      minio_console_password=""
    fi
  fi
  if [[ -z "${minio_console_password}" || "${minio_console_password}" == "${minio_root_password}" ]]; then
    if [[ -z "${MINIO_CONSOLE_PASSWORD}" ]]; then
      log "warning: MINIO_CONSOLE_PASSWORD is not set or matches root; generating a separate console password"
    fi
    minio_console_password="$(python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
)"
  fi
  printf -v minio_config_env '%s\n%s\n%s\n%s\n%s' \
    "export MINIO_ROOT_USER=\"${minio_root_user}\"" \
    "export MINIO_ROOT_PASSWORD=\"${minio_root_password}\"" \
    'export MINIO_BROWSER="on"' \
    'export MINIO_SERVER_URL="http://127.0.0.1:9000"' \
    "export MINIO_BROWSER_REDIRECT_URL=\"https://${MINIO_CONSOLE_DOMAIN}\""
  kubectl -n minio-tenant create secret generic minio-creds-secret --from-literal=accessKey="${minio_root_user}" --from-literal=secretKey="${minio_root_password}" --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -f "${ROOT}/private/kubernetes/namespaces.yaml"
  kubectl -n model-build create secret generic minio-client-credentials --from-literal=accessKey="${minio_root_user}" --from-literal=secretKey="${minio_root_password}" --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n minio-tenant create secret generic model-admin --from-literal=CONSOLE_ACCESS_KEY="${minio_console_user}" --from-literal=CONSOLE_SECRET_KEY="${minio_console_password}" --dry-run=client -o yaml | kubectl apply -f -
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
  # shellcheck disable=SC1091
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
  local target registry_host gitlab_root_password_file
  ensure_openstack_private_route
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

  gitlab_root_password_file=""
  if [[ -n "${GITLAB_ROOT_PASSWORD}" ]]; then
    gitlab_root_password_file="/tmp/gitlab-root-password-${RUN_ID}"
    printf '%s' "${GITLAB_ROOT_PASSWORD}" | ssh -F "${SSH_CONFIG}" "${target}" "umask 077 && cat > ${gitlab_root_password_file}"
  elif [[ "${GITLAB_ADMIN_USERNAME}" != "root" ]]; then
    log "warning: GITLAB_ROOT_PASSWORD is not set; GitLab admin user ${GITLAB_ADMIN_USERNAME} cannot be provisioned until a password file exists on the VM"
  fi

  ssh -F "${SSH_CONFIG}" "${target}" bash -s -- \
    "${GITLAB_EXTERNAL_URL}" \
    "${GITLAB_DOMAIN}" \
    "${GITLAB_IMAGE}" \
    "${GITLAB_SIGNUP_ENABLED}" \
    "${GITLAB_ADMIN_USERNAME}" \
    "${GITLAB_GPU_RUNNER_NAME_PREFIX}" \
    "${GITLAB_GPU_RUNNER_TAGS}" \
    "5400" \
    "${GITLAB_LOGS_TMPFS}" \
    "${GITLAB_LOGS_TMPFS_SIZE}" \
    "${GITLAB_TMPFS_SIZE}" \
    "${GITLAB_RAILS_TMPFS_ENABLED}" \
    "${GITLAB_RAILS_TMPFS_SIZE}" \
    "${GITLAB_DOCKER_BLKIO_WEIGHT}" \
    "${GITLAB_RECREATE_FOR_IO_PROFILE}" \
    "${GITLAB_DOCKER_LOG_MAX_SIZE}" \
    "${GITLAB_DOCKER_LOG_MAX_FILE}" \
    "${gitlab_root_password_file}" <<'REMOTE'
set -euo pipefail
external_url="$1"
gitlab_domain="$2"
gitlab_image="$3"
gitlab_signup_enabled="$4"
gitlab_admin_username="${5:-root}"
runner_name_prefix="$6"
runner_tags="$7"
gitlab_bootstrap_wait_seconds="${8:-5400}"
gitlab_logs_tmpfs="${9:-true}"
gitlab_logs_tmpfs_size="${10:-512m}"
gitlab_tmpfs_size="${11:-1g}"
gitlab_rails_tmpfs_enabled="${12:-false}"
gitlab_rails_tmpfs_size="${13:-512m}"
gitlab_docker_blkio_weight="${14:-300}"
gitlab_recreate_for_io_profile="${15:-true}"
gitlab_docker_log_max_size="${16:-10m}"
gitlab_docker_log_max_file="${17:-3}"
gitlab_root_password_file="${18:-}"
cleanup() {
  if [[ -n "$gitlab_root_password_file" ]]; then
    sudo rm -f "$gitlab_root_password_file" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
sudo install -d -m 0700 /etc/hybrid-ai
sudo install -d -m 0755 /usr/local/sbin /var/lib/hybrid-ai/gitlab-bootstrap /var/cache/hybrid-ai/container-images
installed_root_password_file=""
if [[ -n "$gitlab_root_password_file" && -s "$gitlab_root_password_file" ]]; then
  installed_root_password_file="/etc/hybrid-ai/gitlab-root-password"
  sudo install -m 0600 -o root -g root "$gitlab_root_password_file" "$installed_root_password_file"
elif sudo test -s /etc/hybrid-ai/gitlab-root-password; then
  installed_root_password_file="/etc/hybrid-ai/gitlab-root-password"
fi
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
write_env_line GITLAB_ROOT_PASSWORD_FILE "$installed_root_password_file"
write_env_line GITLAB_GPU_RUNNER_NAME_PREFIX "$runner_name_prefix"
write_env_line GITLAB_GPU_RUNNER_TAGS "$runner_tags"
write_env_line GITLAB_BOOTSTRAP_WAIT_SECONDS "$gitlab_bootstrap_wait_seconds"
write_env_line GITLAB_LOGS_TMPFS "$gitlab_logs_tmpfs"
write_env_line GITLAB_LOGS_TMPFS_SIZE "$gitlab_logs_tmpfs_size"
write_env_line GITLAB_TMPFS_SIZE "$gitlab_tmpfs_size"
write_env_line GITLAB_RAILS_TMPFS_ENABLED "$gitlab_rails_tmpfs_enabled"
write_env_line GITLAB_RAILS_TMPFS_SIZE "$gitlab_rails_tmpfs_size"
write_env_line GITLAB_DOCKER_BLKIO_WEIGHT "$gitlab_docker_blkio_weight"
write_env_line GITLAB_RECREATE_FOR_IO_PROFILE "$gitlab_recreate_for_io_profile"
write_env_line GITLAB_DOCKER_LOG_MAX_SIZE "$gitlab_docker_log_max_size"
write_env_line GITLAB_DOCKER_LOG_MAX_FILE "$gitlab_docker_log_max_file"
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
  local wait_seconds="$gitlab_bootstrap_wait_seconds"
  if ! [[ "$wait_seconds" =~ ^[0-9]+$ ]] || (( wait_seconds < 60 )); then
    wait_seconds=5400
  fi
  local deadline=$((SECONDS + wait_seconds))
  while (( SECONDS < deadline )); do
    if curl -fsS http://127.0.0.1/-/readiness >/dev/null 2>&1 || curl -fsS http://127.0.0.1/users/sign_in >/dev/null 2>&1; then
      return 0
    fi
    sleep 10
  done
  return 1
}
if ! wait_gitlab_local_web; then
  sudo systemctl status hybrid-ai-gitlab-bootstrap.service --no-pager || true
  sudo journalctl -u hybrid-ai-gitlab-bootstrap.service -n 200 --no-pager || true
  sudo cat /var/lib/hybrid-ai/gitlab-bootstrap/status.env 2>/dev/null || true
  exit 1
fi
if sudo systemctl is-failed --quiet hybrid-ai-gitlab-bootstrap.service; then
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
echo "== gitlab bootstrap journal (tail) =="
sudo journalctl -u hybrid-ai-gitlab-bootstrap.service -n 100 --no-pager || true
sudo cat /var/lib/hybrid-ai/gitlab-bootstrap/status.env 2>/dev/null || true
REMOTE
  ensure_lxc_proxy_device gitlab-proxy "tcp:127.0.0.1:${GITLAB_UPSTREAM_PORT}" "tcp:${target}:80"
  local _gl_ep; _gl_ep="$(host_svc_ep "${target}" 80 "${GITLAB_UPSTREAM_PORT}")"
  curl -fsS "http://${_gl_ep}/users/sign_in" >/dev/null 2>&1 \
    || curl -fsS "http://${_gl_ep}/-/readiness" >/dev/null
}

setup_harbor() {
  [[ "${HARBOR_INSTALL_ENABLED}" == "true" ]] || return 0
  local target admin_password_file harbor_env_file harbor_env_payload

  ensure_openstack_private_route
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
  write_systemd_env_line "${harbor_env_file}" HARBOR_ADMIN_USERNAME "${HARBOR_ADMIN_USERNAME}"
  write_systemd_env_line "${harbor_env_file}" HARBOR_PROJECTS "${HARBOR_PROJECTS}"
  write_systemd_env_line "${harbor_env_file}" HARBOR_ROBOT_NAME "${HARBOR_ROBOT_NAME}"
  write_systemd_env_line "${harbor_env_file}" HARBOR_HTTP_PORT "${HARBOR_HTTP_PORT}"
  write_systemd_env_line "${harbor_env_file}" HARBOR_BOOTSTRAP_WAIT_SECONDS "${HARBOR_BOOTSTRAP_WAIT_SECONDS}"
  harbor_env_payload="$(base64 <"${harbor_env_file}" | tr -d '\n')"

  ssh -F "${SSH_CONFIG}" "${target}" bash -s -- \
    "${harbor_env_payload}" \
    "${admin_password_file}" \
    "${HARBOR_HTTP_PORT}" <<'REMOTE'
set -euo pipefail
harbor_env_payload="$1"
harbor_admin_password_file="${2:-}"
harbor_http_port="${3:-80}"

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

# HARBOR_HTTP_PORT comes from the heredoc argument (the env file lives under the
# root-only 0700 /etc/hybrid-ai and cannot be sourced as the SSH login user).
curl -fsS "http://127.0.0.1:${harbor_http_port}/api/v2.0/ping" >/dev/null 2>&1 \
  || curl -fsS "http://127.0.0.1:${harbor_http_port}/api/v2.0/health" >/dev/null
echo "== harbor bootstrap journal (tail) =="
sudo journalctl -u hybrid-ai-harbor-bootstrap.service -n 100 --no-pager || true
sudo cat /var/lib/hybrid-ai/harbor-bootstrap/status.env 2>/dev/null || true
REMOTE

  ensure_lxc_proxy_device harbor-proxy "tcp:127.0.0.1:${HARBOR_UPSTREAM_PORT}" "tcp:${target}:${HARBOR_HTTP_PORT}"
  local _hb_ep; _hb_ep="$(host_svc_ep "${target}" "${HARBOR_HTTP_PORT}" "${HARBOR_UPSTREAM_PORT}")"
  curl -fsS "http://${_hb_ep}/api/v2.0/ping" >/dev/null 2>&1 \
    || curl -fsS "http://${_hb_ep}/api/v2.0/health" >/dev/null

  # Persist the kaniko robot credentials to a run-independent path. The k8s pull
  # secret is created later by the platform phase (setup_model_build_platform),
  # NOT here: the registry phase runs in parallel with the k8s bootstrap, so it
  # must not touch the cluster (kubectl would hang waiting for an absent API).
  robot_json="$(ssh -F "${SSH_CONFIG}" "${target}" 'sudo cat /var/lib/hybrid-ai/harbor-bootstrap/kaniko-robot.json')"
  printf '%s\n' "${robot_json}" >"${ROOT}/.ha/openstack/harbor-kaniko-robot.json"
  python3 - "${ROOT}/.ha/openstack/harbor-kaniko-robot.json" "${HARBOR_EXTERNAL_URL}" >"${ROOT}/.ha/openstack/harbor-kaniko-robot.env" <<'PY'
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
}

apply_ca_secret() {
  local namespace="$1"
  local secret_name="$2"
  local cert_value="$3"
  [[ -n "${cert_value}" ]] || return 0

  local cert_file
  cert_file="$(mktemp)"
  if [[ -f "${cert_value}" ]]; then
    cp "${cert_value}" "${cert_file}"
  else
    printf '%s\n' "${cert_value}" >"${cert_file}"
  fi

  kubectl create namespace "${namespace}" --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "${namespace}" create secret generic "${secret_name}" \
    --from-file=ca.crt="${cert_file}" \
    --dry-run=client -o yaml | kubectl apply -f -
  rm -f "${cert_file}"
}

apply_literal_secret() {
  local namespace="$1"
  local secret_name="$2"
  local key="$3"
  local value="$4"
  [[ -n "${value}" ]] || return 0

  kubectl create namespace "${namespace}" --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "${namespace}" create secret generic "${secret_name}" \
    --from-literal="${key}=${value}" \
    --dry-run=client -o yaml | kubectl apply -f -
}

apply_harbor_registry_secret() {
  local namespace="$1"
  local secret_name="$2"

  kubectl create namespace "${namespace}" --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "${namespace}" create secret docker-registry "${secret_name}" \
    --docker-server="${HARBOR_REGISTRY_SERVER}" \
    --docker-username="${HARBOR_ROBOT_USERNAME}" \
    --docker-password="${HARBOR_ROBOT_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f -
}

setup_model_build_platform() {
  ensure_openstack_private_route
  start_kubectl_tunnel
  export KUBECONFIG="${KUBECONFIG_PATH}"
  kubectl apply -k "${ROOT}/private/kubernetes"
  apply_gpu_worker_resources

  # Create the Harbor kaniko pull/push secret from credentials saved by the
  # registry phase (setup_harbor). Done here because this is where the cluster
  # is guaranteed to exist; the registry phase runs in parallel and cannot.
  local robot_env="${ROOT}/.ha/openstack/harbor-kaniko-robot.env"
  if optional_apply_phase_enabled "${HA_PRIVATE_CLOUD_SETUP_REGISTRY}"; then
    # The registry phase runs in parallel with this one; wait up to ~10m for it
    # to publish the harbor robot credentials before creating the pull secret.
    local _i
    for _i in $(seq 1 60); do
      [[ -f "${robot_env}" ]] && break
      sleep 10
    done
  fi
  if [[ -f "${robot_env}" ]]; then
    # shellcheck disable=SC1090
    source "${robot_env}"
    apply_harbor_registry_secret model-build harbor-kaniko-push
    apply_harbor_registry_secret default harbor-docker-secret
    apply_harbor_registry_secret default harbor-secret
  else
    echo "warning: harbor robot credentials not found (${robot_env}); skipping harbor-kaniko-push secret" >&2
  fi
  apply_ca_secret model-build harbor-tls-ca "${HARBOR_CA_CERT}"
  apply_ca_secret model-build gitlab-tls-ca "${HARBOR_CA_CERT}"
  apply_ca_secret default harbor-tls-ca "${HARBOR_CA_CERT}"
  apply_ca_secret default gitlab-tls-ca "${HARBOR_CA_CERT}"
  apply_literal_secret model-build gitlab-pipeline-trigger token "${GITLAB_PIPELINE_TRIGGER_TOKEN}"
  apply_literal_secret default gitlab-pipeline-trigger token "${GITLAB_PIPELINE_TRIGGER_TOKEN}"
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
  ensure_openstack_private_route
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

# Terminate any stale private-cloud-apply.sh processes left over from a previous
# run (e.g. a GitHub Actions job that was cancelled — the SSH session dies but the
# remote bash process keeps running as an orphan and holds devstack/terraform).
# Excludes the current process tree (own PID, parent, and process group).
terminate_stale_apply_processes() {
  local self_pid self_ppid self_pgid pids pid victim_pgid
  self_pid="$$"
  self_ppid="$PPID"
  self_pgid="$(ps -o pgid= -p "$self_pid" 2>/dev/null | tr -d ' ' || true)"

  pids="$(pgrep -f "private-cloud-apply.sh" 2>/dev/null || true)"
  [[ -n "$pids" ]] || return 0

  local to_kill=()
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    [[ "$pid" == "$self_pid" || "$pid" == "$self_ppid" ]] && continue
    victim_pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
    [[ -n "$self_pgid" && "$victim_pgid" == "$self_pgid" ]] && continue
    to_kill+=("$pid")
  done <<<"$pids"

  [[ "${#to_kill[@]}" -gt 0 ]] || return 0
  log "terminating ${#to_kill[@]} stale private-cloud-apply process(es): ${to_kill[*]}"
  kill -TERM "${to_kill[@]}" 2>/dev/null || true
  sleep 3
  for pid in "${to_kill[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done
}

release_phase_lock() {
  local lock_path
  lock_path="${PHASE_LOCK_PATH:-}"
  [[ -n "$lock_path" ]] || return 0
  case "$lock_path" in
    "${ROOT}/.ha/ci/locks/"*.lockdir)
      rm -rf -- "$lock_path"
      PHASE_LOCK_PATH=""
      ;;
  esac
}

# Acquire a per-phase lock so the same phase cannot run twice concurrently on the
# host. Use a lock directory instead of an inherited FD lock: phase work is
# streamed through pipelines and long-lived children must not keep the lock alive.
acquire_phase_lock() {
  local phase_name="$1"
  local lock_dir lock_path owner_pid
  lock_dir="${ROOT}/.ha/ci/locks"
  mkdir -p "$lock_dir"
  lock_path="${lock_dir}/${phase_name}.lockdir"

  if mkdir "$lock_path" 2>/dev/null; then
    printf '%s\n' "$$" >"${lock_path}/pid"
    PHASE_LOCK_PATH="$lock_path"
    trap release_phase_lock EXIT
    return 0
  fi

  owner_pid="$(cat "${lock_path}/pid" 2>/dev/null || true)"
  if [[ "$owner_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$owner_pid" 2>/dev/null; then
    rm -rf -- "$lock_path"
    if mkdir "$lock_path" 2>/dev/null; then
      printf '%s\n' "$$" >"${lock_path}/pid"
      PHASE_LOCK_PATH="$lock_path"
      trap release_phase_lock EXIT
      return 0
    fi
  fi

  printf 'another "%s" phase is already running on this host (lock: %s owner_pid=%s)\n' \
    "$phase_name" "$lock_path" "${owner_pid:-unknown}" >&2
  exit 1
}

run_tools_phases() {
  phase require_tools require_tools
}

run_devstack_steps() {
  if [[ "${HA_OPENSTACK_PROVIDER}" == "kolla" ]]; then
    if [[ "${MODE}" == "reinstall" ]]; then
      phase kolla_reinstall kolla_reinstall
    else
      phase kolla_apply_check kolla_apply_check
    fi
    return
  fi
  if [[ "${MODE}" == "reinstall" ]]; then
    phase devstack_reinstall devstack_reinstall
  else
    phase devstack_apply_check devstack_apply_check
  fi
}

run_proxy_steps() {
  if [[ "${HA_OPENSTACK_PROVIDER}" == "kolla" ]]; then
    # Kolla: 외부 접속은 in-cluster cloudflared(private/cloudflared)가 담당 → 레거시 LXD 프록시/터널/DNS 불필요
    skip_phase setup_reverse_proxy "Kolla: 접속은 in-cluster cloudflared 담당 (레거시 프록시 스킵)"
    return
  fi
  phase ensure_openstack_private_route ensure_openstack_private_route
  phase setup_minio_entrypoints setup_minio_entrypoints
  phase setup_reverse_proxy setup_reverse_proxy
  phase setup_openstack_ssh_tunnels setup_openstack_ssh_tunnels
  phase sync_cloudflare_dns sync_cloudflare_dns
}

run_images_steps() {
  if [[ "${HA_OPENSTACK_PROVIDER}" == "kolla" ]]; then
    # Kolla: VM 이미지는 glance에서 직접 관리(*-restore) → DevStack 캐시 단계 불필요
    skip_phase prepare_cached_images "Kolla: 이미지는 glance에서 직접 관리 (캐시 스킵)"
    return
  fi
  phase prepare_cached_images prepare_cached_images
}

run_terraform_steps() {
  phase terraform_apply terraform_apply
}

run_k8s_steps() {
  phase bootstrap_k8s bootstrap_k8s
}

run_storage_steps() {
  if optional_apply_phase_enabled "${HA_PRIVATE_CLOUD_SETUP_STORAGE}"; then
    phase setup_storage setup_storage
  else
    skip_phase setup_storage "disabled for lightweight Actions stack"
  fi
}

run_model_build_steps() {
  if optional_apply_phase_enabled "${HA_PRIVATE_CLOUD_SETUP_MODEL_BUILD}"; then
    phase setup_model_build_platform setup_model_build_platform
  else
    skip_phase setup_model_build_platform "disabled for lightweight Actions stack"
  fi
}

run_devstack_phases() {
  run_tools_phases
  run_devstack_steps
}

run_proxy_phases() {
  run_tools_phases
  run_proxy_steps
}

run_images_phases() {
  run_tools_phases
  run_images_steps
}

run_terraform_phases() {
  run_tools_phases
  run_terraform_steps
}

run_control_plane_phases() {
  run_tools_phases
  phase wait_control_plane_vm wait_role_nodes_ssh control-plane control_plane_nodes
}

run_build_worker_phases() {
  run_tools_phases
  phase wait_build_worker_vm wait_role_nodes_ssh build-worker build_worker_nodes
}

run_gpu_worker_phases() {
  run_tools_phases
  phase wait_gpu_worker_vm wait_role_nodes_ssh gpu-worker gpu_worker_nodes
}

run_k8s_phases() {
  run_tools_phases
  run_k8s_steps
}

run_storage_phases() {
  run_tools_phases
  run_storage_steps
}

run_model_build_phases() {
  run_tools_phases
  run_model_build_steps
}

run_provision_phases() {
  run_tools_phases
  run_devstack_steps
  run_images_steps
  run_terraform_steps
  run_proxy_steps
}

run_platform_phases() {
  run_tools_phases
  run_k8s_steps
  run_storage_steps
  run_model_build_steps
}

run_gitlab_phases() {
  run_tools_phases
  if optional_apply_phase_enabled "${HA_PRIVATE_CLOUD_SETUP_REGISTRY}"; then
    phase setup_gitlab setup_gitlab
  else
    skip_phase setup_gitlab "disabled for lightweight Actions stack"
  fi
}

run_harbor_phases() {
  run_tools_phases
  if optional_apply_phase_enabled "${HA_PRIVATE_CLOUD_SETUP_REGISTRY}"; then
    phase setup_harbor setup_harbor
  else
    skip_phase setup_harbor "disabled for lightweight Actions stack"
  fi
}

run_registry_phases() {
  run_tools_phases
  if optional_apply_phase_enabled "${HA_PRIVATE_CLOUD_SETUP_REGISTRY}"; then
    phase setup_registry_services setup_registry_services_parallel
    run_proxy_steps
  else
    skip_phase setup_registry_services "disabled for lightweight Actions stack"
  fi
}

run_finalize_phases() {
  if [[ "${VALIDATE_GPU}" == "true" ]]; then
    phase validate_gpu_lightweight validate_gpu_lightweight
  fi
}

main() {
  case "${MODE}" in
    apply|reinstall) ;;
    *)
      printf 'usage: %s [reinstall|apply]\n' "$0" >&2
      return 64
      ;;
  esac

  # Only the entry phases clear stale orphans. Later jobs in a split GitHub run
  # must not kill the process tree from another active invocation.
  if [[ "${PHASES}" == "devstack" || "${PHASES}" == "provision" || "${PHASES}" == "all" ]]; then
    terminate_stale_apply_processes
  fi
  acquire_phase_lock "${PHASES}"

  case "${PHASES}" in
    tools)     run_tools_phases ;;
    devstack)  run_devstack_phases ;;
    proxy)     run_proxy_phases ;;
    images)    run_images_phases ;;
    terraform) run_terraform_phases ;;
    control-plane) run_control_plane_phases ;;
    build-worker) run_build_worker_phases ;;
    gpu-worker) run_gpu_worker_phases ;;
    k8s)       run_k8s_phases ;;
    storage)   run_storage_phases ;;
    model-build) run_model_build_phases ;;
    gitlab)    run_gitlab_phases ;;
    harbor)    run_harbor_phases ;;
    provision) run_provision_phases ;;
    platform)  run_platform_phases ;;
    registry)  run_registry_phases ;;
    finalize)  run_finalize_phases ;;
    all)
      run_tools_phases
      run_devstack_steps
      run_images_steps
      run_terraform_steps
      run_control_plane_phases
      run_build_worker_phases
      run_gpu_worker_phases
      run_registry_phases
      run_k8s_steps
      run_storage_steps
      run_model_build_steps
      run_finalize_phases
      ;;
  esac
  log "DONE ${MODE}/${PHASES}; timings: ${TIMINGS}"
}

main "$@"
