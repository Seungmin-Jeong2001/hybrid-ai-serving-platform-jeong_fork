#!/usr/bin/env bash
# 배포 시점 FILL 자동 채움 — "우리 서버"(Linux) 런타임 introspection
# 대상: /etc/kolla/globals.yml(network_interface), /etc/kolla/config/nova.conf(GPU product_id)
# 토폴로지 선택값(neutron_external_interface, kolla_internal_vip_address)은 후보 제시
set -euo pipefail

GLOBALS="${1:?usage: autodetect.sh <globals.yml> [nova.conf]}"
NOVA="${2:-}"
GPU_VENDOR_ID="${HA_OPENSTACK_GPU_PCI_VENDOR_ID:-10de}"

info() { printf '[autodetect] %s\n' "$*"; }

# network_interface = 기본 라우트 NIC
nic="$(ip -o route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n1)"
if [[ -n "$nic" ]]; then
  sed -i "s|network_interface: \"<FILL[^\"]*>\"|network_interface: \"$nic\"|" "$GLOBALS"
  info "network_interface=$nic"
fi

# neutron_external_interface 후보: IP 없는 물리 NIC (mgmt NIC 제외)
ext=""
for path in /sys/class/net/*; do
  cand="$(basename "$path")"
  case "$cand" in lo|docker*|veth*|br-*|virbr*|tap*|cni*|flannel*|kube*|ovs*) continue ;; esac
  [[ "$cand" == "$nic" ]] && continue
  ip -4 addr show "$cand" 2>/dev/null | grep -q 'inet ' && continue
  ext="$cand"; break
done
if [[ -n "$ext" ]]; then
  sed -i "s|neutron_external_interface: \"<FILL[^\"]*>\"|neutron_external_interface: \"$ext\"|" "$GLOBALS"
  info "neutron_external_interface=$ext (후보 — 확인 권장)"
fi

# GPU product_id (sysfs 스캔, class 03=display) — detect_gpu_product 동일 로직
if [[ -n "$NOVA" && -f "$NOVA" ]]; then
  vendor="$(printf '%s' "$GPU_VENDOR_ID" | tr '[:upper:]' '[:lower:]' | sed 's/^0x//')"
  pid=""
  for d in /sys/bus/pci/devices/*; do
    v="$(cat "$d/vendor" 2>/dev/null || true)"; p="$(cat "$d/device" 2>/dev/null || true)"; c="$(cat "$d/class" 2>/dev/null || true)"
    v="$(printf '%s' "${v#0x}" | tr '[:upper:]' '[:lower:]')"
    p="$(printf '%s' "${p#0x}" | tr '[:upper:]' '[:lower:]')"
    c="$(printf '%s' "${c#0x}" | tr '[:upper:]' '[:lower:]')"
    if [[ "$v" == "$vendor" && "$c" == 03* && -n "$p" ]]; then pid="$p"; break; fi
  done
  if [[ -n "$pid" ]]; then
    sed -i "s|\"product_id\":\"<FILL>\"|\"product_id\":\"$pid\"|g" "$NOVA"
    info "GPU product_id=$pid"
  else
    info "GPU 미탐지 — nova.conf product_id 수동 확인 (GPU 미보유 서버면 무시)"
  fi
fi

# 남은 FILL 보고 (주석 줄 제외 — kolla_internal_vip_address 등 토폴로지 선택값)
remaining="$(grep -nH '<FILL' "$GLOBALS" ${NOVA:+"$NOVA"} 2>/dev/null | grep -vE ':[0-9]+:[[:space:]]*#' || true)"
if [[ -n "$remaining" ]]; then
  info "수동 입력 필요 (자동 도출 불가):"
  printf '%s\n' "$remaining"
fi
