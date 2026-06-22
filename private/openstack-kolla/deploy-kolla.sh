#!/usr/bin/env bash
# Kolla-Ansible 배포 (Phase A) — "우리 서버"(Linux)에서 실행
# DevStack run_devstack() 대체, 운영 OpenStack 부트스트랩
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 조정 가능한 입력
KOLLA_VENV="${KOLLA_VENV:-${HOME}/.ha/kolla-venv}"
KOLLA_ANSIBLE_VERSION="${KOLLA_ANSIBLE_VERSION:-}" # 비움 시 openstack_release 호환 최신
KOLLA_ETC="${KOLLA_ETC:-/etc/kolla}"
KOLLA_INVENTORY="${KOLLA_INVENTORY:-${SCRIPT_DIR}/inventory/all-in-one}"

info() { printf '[kolla] %s\n' "$*"; }
die() { printf '[kolla] error: %s\n' "$*" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || die "python3 required"

info "venv 준비: ${KOLLA_VENV}"
python3 -m venv "${KOLLA_VENV}"
# shellcheck disable=SC1091
source "${KOLLA_VENV}/bin/activate"
pip install --upgrade pip
if [[ -n "${KOLLA_ANSIBLE_VERSION}" ]]; then
  pip install "kolla-ansible==${KOLLA_ANSIBLE_VERSION}"
else
  pip install kolla-ansible
fi
kolla-ansible install-deps

info "${KOLLA_ETC} 구성 (globals.yml / passwords.yml)"
sudo mkdir -p "${KOLLA_ETC}/config/nova"
sudo cp "${SCRIPT_DIR}/globals.yml" "${KOLLA_ETC}/globals.yml"
sudo cp "${SCRIPT_DIR}/config/nova.conf" "${KOLLA_ETC}/config/nova.conf"

if [[ ! -f "${KOLLA_ETC}/passwords.yml" ]]; then
  # kolla-ansible 패키지 passwords.yml 시드 후 genpwd
  sudo cp "${KOLLA_VENV}/share/kolla-ansible/etc_examples/kolla/passwords.yml" "${KOLLA_ETC}/passwords.yml"
  sudo "${KOLLA_VENV}/bin/kolla-genpwd" -p "${KOLLA_ETC}/passwords.yml"
else
  info "passwords.yml 존재 — 유지"
fi

info "FILL 자동 채움 (NIC/GPU 런타임 탐지)"
sudo "${SCRIPT_DIR}/autodetect.sh" "${KOLLA_ETC}/globals.yml" "${KOLLA_ETC}/config/nova.conf"

if grep -vE '^[[:space:]]*#' "${KOLLA_ETC}/globals.yml" | grep -q '<FILL'; then
  die "자동 도출 불가 FILL 잔존 (위 목록 참고) — ${KOLLA_ETC}/globals.yml 입력 후 재실행"
fi

info "bootstrap-servers"
kolla-ansible -i "${KOLLA_INVENTORY}" bootstrap-servers
info "prechecks"
kolla-ansible -i "${KOLLA_INVENTORY}" prechecks
info "deploy"
kolla-ansible -i "${KOLLA_INVENTORY}" deploy
info "post-deploy (admin-openrc 생성)"
kolla-ansible -i "${KOLLA_INVENTORY}" post-deploy

info "완료. 자격증명: ${KOLLA_ETC}/admin-openrc.sh"
info "다음: source ${KOLLA_ETC}/admin-openrc.sh && ${SCRIPT_DIR}/post-deploy.sh"
