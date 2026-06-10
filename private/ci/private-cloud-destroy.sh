#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OPENSTACK_DIR="${ROOT}/private/openstack"
PATH="${ROOT}/.ha/bin:${PATH}"
export TF_IN_AUTOMATION="${TF_IN_AUTOMATION:-true}"
export TF_INPUT="${TF_INPUT:-false}"

cleanup_devstack="${HA_PRIVATE_CLOUD_CLEANUP_DEVSTACK:-false}"
require_backend_config=false

usage() {
  cat >&2 <<'EOF'
usage: ha destroy [--cleanup-devstack] [--require-backend-config]
EOF
}

log() {
  printf '[private-cloud-destroy] %s\n' "$*"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cleanup-devstack)
      cleanup_devstack="true"
      shift
      ;;
    --require-backend-config)
      require_backend_config=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      echo "unknown option: $1" >&2
      exit 64
      ;;
  esac
done

require_tool() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "required command not found: $1" >&2
    exit 1
  }
}

write_tfvars_if_present() {
  rm -f "${OPENSTACK_DIR}/backend.generated.tf" "${OPENSTACK_DIR}/backend.hcl" "${OPENSTACK_DIR}/private-cloud.auto.tfvars"
  if [[ -n "${PRIVATE_CLOUD_TFVARS:-}" ]]; then
    printf '%s' "$PRIVATE_CLOUD_TFVARS" > "${OPENSTACK_DIR}/private-cloud.auto.tfvars"
  fi
}

devstack_openrc_password() {
  command -v lxc >/dev/null 2>&1 || return 0
  local result
  # shellcheck disable=SC2016
  result="$(lxc exec ha-openstack -- sudo -u stack -H bash -lc 'cd /opt/stack/devstack && set +u && source openrc admin admin >/dev/null && printf "%s" "${OS_PASSWORD:-}"' 2>/dev/null || true)"
  if [[ -z "$result" ]]; then
    printf '[private-cloud-destroy] warning: could not read DevStack admin password from openrc; falling back to HA_DEVSTACK_PASSWORD\n' >&2
  fi
  printf '%s' "$result"
}

ensure_horizon_proxy_if_available() {
  command -v lxc >/dev/null 2>&1 || return 0
  lxc info ha-openstack >/dev/null 2>&1 || return 0
  lxc config device remove ha-openstack horizon-proxy >/dev/null 2>&1 || true
  lxc config device add ha-openstack horizon-proxy proxy \
    listen=tcp:127.0.0.1:18081 connect=tcp:127.0.0.1:80 >/dev/null 2>&1 || true
}

prepare_local_devstack_env() {
  export OS_AUTH_URL="${HA_DEVSTACK_AUTH_URL:-http://127.0.0.1:18081/identity/v3}"
  local login_username="${HA_OPENSTACK_LOGIN_USERNAME:-${OS_USERNAME:-${HA_DEVSTACK_USERNAME:-admin}}}"
  local login_project="${HA_OPENSTACK_LOGIN_PROJECT_NAME:-${OS_PROJECT_NAME:-${HA_DEVSTACK_PROJECT_NAME:-admin}}}"
  local login_user_domain="${HA_OPENSTACK_LOGIN_USER_DOMAIN_NAME:-${OS_USER_DOMAIN_NAME:-${HA_DEVSTACK_USER_DOMAIN_NAME:-Default}}}"
  local login_project_domain="${HA_OPENSTACK_LOGIN_PROJECT_DOMAIN_NAME:-${OS_PROJECT_DOMAIN_NAME:-${HA_DEVSTACK_PROJECT_DOMAIN_NAME:-Default}}}"
  local login_password="${HA_OPENSTACK_LOGIN_PASSWORD:-${OS_PASSWORD:-}}"
  export OS_USERNAME="$login_username"
  local devstack_password
  local openrc_password

  devstack_password="${HA_DEVSTACK_PASSWORD:-hybrid-ai-devstack}"
  openrc_password="$(devstack_openrc_password)"
  if [[ -n "$openrc_password" ]]; then
    devstack_password="$openrc_password"
  fi
  if [[ -n "$login_password" ]]; then
    devstack_password="$login_password"
  fi
  export OS_PASSWORD="$devstack_password"
  export OS_PROJECT_NAME="$login_project"
  export OS_USER_DOMAIN_NAME="$login_user_domain"
  export OS_PROJECT_DOMAIN_NAME="$login_project_domain"
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

prepare_ssh_public_key() {
  if [[ -n "${TF_VAR_ssh_public_key:-}" ]]; then
    return
  fi
  if [[ -n "${PRIVATE_CLOUD_SSH_PUBLIC_KEY:-}" ]]; then
    export TF_VAR_ssh_public_key="$PRIVATE_CLOUD_SSH_PUBLIC_KEY"
    return
  fi
  local key="${ROOT}/.ha/ssh/hybrid-ai-private-admin"
  if [[ -f "${key}.pub" ]]; then
    export TF_VAR_ssh_public_key
    TF_VAR_ssh_public_key="$(cat "${key}.pub")"
    return
  fi
  install -d -m 0700 "${ROOT}/.ha/ssh"
  ssh-keygen -t ed25519 -N '' -f "$key" >/dev/null
  export TF_VAR_ssh_public_key
  TF_VAR_ssh_public_key="$(cat "${key}.pub")"
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

terraform_init() {
  local backend_config="${TF_BACKEND_CONFIG:-}"
  local backend_config_compact="${backend_config//[[:space:]]/}"

  if [[ "$require_backend_config" == "true" && -z "$backend_config_compact" ]]; then
    echo "TF_BACKEND_CONFIG is required when --require-backend-config is set" >&2
    exit 1
  fi

  if [[ -n "$backend_config_compact" ]]; then
    printf 'terraform {\n  backend "%s" {}\n}\n' "${TF_BACKEND_TYPE:-local}" > "${OPENSTACK_DIR}/backend.generated.tf"
    printf '%s' "$backend_config" > "${OPENSTACK_DIR}/backend.hcl"
    if prepare_noninteractive_backend_init "$OPENSTACK_DIR" "${OPENSTACK_DIR}/backend.hcl"; then
      terraform -chdir="$OPENSTACK_DIR" init -input=false -reconfigure -backend-config=backend.hcl
    else
      terraform -chdir="$OPENSTACK_DIR" init -input=false -migrate-state -force-copy -backend-config=backend.hcl
    fi
  else
    rm -f "${OPENSTACK_DIR}/.terraform/terraform.tfstate"
    terraform -chdir="$OPENSTACK_DIR" init -input=false -reconfigure
  fi
}

cleanup_kubernetes_best_effort() {
  local kubeconfig="${ROOT}/.ha/openstack/kubeconfig"

  command -v kubectl >/dev/null 2>&1 || return 0
  [[ -f "$kubeconfig" ]] || return 0
  export KUBECONFIG="$kubeconfig"
  if ! kubectl --request-timeout=20s get nodes >/dev/null 2>&1; then
    log "Kubernetes API is not reachable; skipping Kubernetes cleanup"
    return 0
  fi

  log "cleaning Kubernetes workloads before Terraform destroy"
  kubectl delete jobs --all --all-namespaces --ignore-not-found=true --timeout=60s || true
  kubectl delete deployments --all --all-namespaces --ignore-not-found=true --timeout=120s || true
  kubectl delete statefulsets --all --all-namespaces --ignore-not-found=true --timeout=120s || true
  kubectl delete daemonsets --all --all-namespaces --ignore-not-found=true --timeout=120s || true
  kubectl delete pvc --all --all-namespaces --ignore-not-found=true --timeout=120s || true
  kubectl delete pv --all --ignore-not-found=true --timeout=120s || true
}

cleanup_openstack_orphans_best_effort() {
  local prefix="${HA_PRIVATE_CLOUD_RESOURCE_PREFIX:-${TF_VAR_project_name:-hybrid-ai-private}}"

  command -v lxc >/dev/null 2>&1 || return 0
  lxc info ha-openstack >/dev/null 2>&1 || return 0

  log "cleaning orphan OpenStack resources with prefix ${prefix}"
  lxc exec ha-openstack -- sudo -u stack -H bash -s -- "$prefix" <<'CLEANUP_OPENSTACK_ORPHANS'
set -euo pipefail
prefix="$1"
cd /opt/stack/devstack
set +u
source openrc admin admin >/dev/null
set -u

network_id="$(openstack network list -f value -c ID -c Name | awk -v n="${prefix}-net" '$2 == n {print $1; exit}')"
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

server_ids="$(openstack server list --all-projects -f value -c ID -c Name | awk -v p="$prefix" '$2 ~ "^" p {print $1}')"
if [[ -n "$server_ids" ]]; then
  while IFS= read -r id; do
    [[ -n "$id" ]] && openstack server delete "$id" || true
  done <<<"$server_ids"
  for _ in {1..60}; do
    remaining="$(openstack server list --all-projects -f value -c ID -c Name | awk -v p="$prefix" '$2 ~ "^" p {print $1}' | wc -l)"
    [[ "$remaining" -eq 0 ]] && break
    sleep 5
  done
fi

router_id="$(openstack router list -f value -c ID -c Name | awk -v n="${prefix}-router" '$2 == n {print $1; exit}')"
subnet_id="$(openstack subnet list -f value -c ID -c Name | awk -v n="${prefix}-subnet" '$2 == n {print $1; exit}')"
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

sg_id="$(openstack security group list -f value -c ID -c Name | awk -v n="${prefix}-sg" '$2 == n {print $1; exit}')"
if [[ -n "$sg_id" ]]; then
  openstack security group delete "$sg_id" || true
fi

cache_sg_id="$(openstack security group list -f value -c ID -c Name | awk '$2 == "hybrid-ai-image-cache-sg" {print $1; exit}')"
if [[ -n "$cache_sg_id" ]]; then
  openstack security group delete "$cache_sg_id" || true
fi

cache_keypair="$(openstack keypair list -f value -c Name | awk '$1 == "hybrid-ai-image-cache-builder" {print $1; exit}')"
if [[ -n "$cache_keypair" ]]; then
  openstack keypair delete "$cache_keypair" || true
fi

for key_name in "${prefix}-admin" hybrid-ai-actions-admin; do
  if openstack keypair show "$key_name" >/dev/null 2>&1; then
    openstack keypair delete "$key_name" || true
  fi
done
CLEANUP_OPENSTACK_ORPHANS
}

prefixed_openstack_servers_exist() {
  local prefix="${HA_PRIVATE_CLOUD_RESOURCE_PREFIX:-${TF_VAR_project_name:-hybrid-ai-private}}"

  command -v lxc >/dev/null 2>&1 || return 1
  lxc info ha-openstack >/dev/null 2>&1 || return 1

  lxc exec ha-openstack -- sudo -u stack -H bash -s -- "$prefix" <<'CHECK_OPENSTACK_SERVERS'
set -euo pipefail
prefix="$1"
cd /opt/stack/devstack
set +u
source openrc admin admin >/dev/null
set -u
openstack server list --all-projects -f value -c Name \
  | awk -v p="$prefix" '$1 ~ "^" p {found=1} END {exit found ? 0 : 1}'
CHECK_OPENSTACK_SERVERS
}

main() {
  require_tool terraform
  require_tool python3
  local destroy_rc
  ensure_horizon_proxy_if_available
  prepare_local_devstack_env
  check_openstack_auth
  prepare_ssh_public_key
  write_tfvars_if_present
  cleanup_kubernetes_best_effort

  log "terraform init"
  terraform_init

  log "terraform destroy"
  destroy_rc=0
  terraform -chdir="$OPENSTACK_DIR" destroy -input=false -auto-approve || destroy_rc="$?"
  cleanup_openstack_orphans_best_effort
  if [[ "$destroy_rc" -ne 0 ]]; then
    if ! prefixed_openstack_servers_exist; then
      log "terraform destroy returned ${destroy_rc}, but no prefixed OpenStack servers remain after cleanup; continuing"
      destroy_rc=0
    fi
  fi
  if [[ "$destroy_rc" -ne 0 ]]; then
    exit "$destroy_rc"
  fi

  if [[ "$cleanup_devstack" == "true" ]]; then
    require_tool lxc
    log "removing ha-openstack LXD container"
    lxc stop ha-openstack --force 2>/dev/null || true
    lxc delete ha-openstack --force 2>/dev/null || true
  fi

  rm -f "${OPENSTACK_DIR}/backend.generated.tf" "${OPENSTACK_DIR}/backend.hcl" "${OPENSTACK_DIR}/private-cloud.auto.tfvars"
  log "complete"
}

main "$@"
