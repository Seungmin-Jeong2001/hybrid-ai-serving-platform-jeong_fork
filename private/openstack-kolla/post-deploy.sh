#!/usr/bin/env bash
# Kolla 배포 후 시드: flavor + image (네트워크/서브넷/VM 은 Terraform 소유)
# DevStack ensure_flavors()/ensure_images() 와 동일 값
# 선행: source /etc/kolla/admin-openrc.sh (또는 openrc admin admin)
set -euo pipefail

info() { printf '[post-deploy] %s\n' "$*"; }
die() { printf '[post-deploy] error: %s\n' "$*" >&2; exit 1; }

command -v openstack >/dev/null 2>&1 || die "openstack client required (pip install python-openstackclient)"
[[ -n "${OS_AUTH_URL:-}" ]] || die "OS_* 미설정 — source admin-openrc.sh 선행"

# --- flavor (name ram vcpus disk) : private-cloud-apply.sh 기본값 동일 ---
ensure_flavor() {
  local name="$1" ram="$2" vcpus="$3" disk="$4"
  if ! openstack flavor show "$name" >/dev/null 2>&1; then
    openstack flavor create --ram "$ram" --vcpus "$vcpus" --disk "$disk" "$name" >/dev/null
    info "flavor 생성: $name"
  fi
  openstack flavor set --property "hw_rng:allowed=True" "$name"
}

ensure_flavor "${HA_DEVSTACK_CONTROL_FLAVOR_NAME:-ha.m1.control}" 8192 3 80
ensure_flavor "${HA_DEVSTACK_WORKER_FLAVOR_NAME:-ha.m1.build}"    6144 2 80
ensure_flavor "${HA_DEVSTACK_GITLAB_FLAVOR_NAME:-ha.m1.gitlab}"   12288 3 80
ensure_flavor "${HA_DEVSTACK_HARBOR_FLAVOR_NAME:-ha.m1.harbor}"   4096 2 80
ensure_flavor "${HA_OPENSTACK_GPU_FLAVOR_NAME:-g1.large}"         8192 4 80

# GPU flavor 에 PCI alias (config/nova.conf alias 이름과 일치)
openstack flavor set \
  --property "pci_passthrough:alias=${HA_OPENSTACK_GPU_PCI_ALIAS:-nvidia-gpu}:1" \
  --property "hw:pci_numa_affinity_policy=${HA_OPENSTACK_GPU_PCI_NUMA_POLICY:-preferred}" \
  "${HA_OPENSTACK_GPU_FLAVOR_NAME:-g1.large}" || true

# --- image: ubuntu-22.04 (Jammy cloud image) ---
IMAGE_NAME="${TF_VAR_control_plane_image_name:-ubuntu-22.04}"
IMAGE_URL="${HA_KOLLA_UBUNTU_IMAGE_URL:-https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img}"
if ! openstack image show "$IMAGE_NAME" >/dev/null 2>&1; then
  tmp="$(mktemp --suffix=.img)"
  trap 'rm -f "$tmp"' EXIT
  info "이미지 다운로드: $IMAGE_URL"
  curl -fsSL "$IMAGE_URL" -o "$tmp"
  openstack image create --disk-format qcow2 --container-format bare --file "$tmp" "$IMAGE_NAME" >/dev/null
  info "image 생성: $IMAGE_NAME"
fi

info "완료. 네트워크/서브넷/VM 은 'cd ../openstack && terraform apply' 로 생성"
