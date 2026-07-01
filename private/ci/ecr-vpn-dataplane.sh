#!/usr/bin/env bash
# ECR-over-VPN 데이터플레인 설정 (kt-cloud 호스트에서 root로 실행).
#
# 목적: 10.42 노드 → AWS VPC(10.0.0.0/16) 트래픽이 MacMini IPsec 터널을 타게 한다.
#   1) 호스트 라우트: VPC_CIDR → MacMini(BASTION_IP)
#   2) net.ipv4.ip_forward=1
#   3) qrouter netns no-SNAT: dest VPC_CIDR 는 SNAT 하지 말 것(소스 10.42 유지 → IPsec selector 매칭)
#
# qrouter는 Neutron이 재생성하면 규칙이 사라지므로 systemd timer로 주기 재적용한다.
#
# 사용:
#   sudo VPC_CIDR=10.0.0.0/16 BASTION_IP=192.168.0.30 ./ecr-vpn-dataplane.sh apply     # 1회 적용
#   sudo VPC_CIDR=10.0.0.0/16 BASTION_IP=192.168.0.30 ./ecr-vpn-dataplane.sh install   # systemd 영구화
#   ./ecr-vpn-dataplane.sh status
#
# 노드 DNS 포워딩(*.amazonaws.com → resolver inbound IP)은 별도(노드측). 런북 참조.
set -euo pipefail

VPC_CIDR="${VPC_CIDR:-10.0.0.0/16}"
BASTION_IP="${BASTION_IP:-192.168.0.30}"
UNIT_NAME="ecr-vpn-dataplane"
SELF_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

log() { printf '[ecr-vpn-dp] %s\n' "$*"; }
need_root() { [[ "$(id -u)" -eq 0 ]] || { echo "root 권한 필요 (sudo)" >&2; exit 1; }; }

qrouter_netns() {
  ip netns list 2>/dev/null | grep -oE 'qrouter-[0-9a-f-]+' | head -n1
}

apply_route() {
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  # VPC_CIDR → MacMini. 이미 같으면 no-op.
  if ! ip route show "$VPC_CIDR" 2>/dev/null | grep -q "via $BASTION_IP"; then
    ip route replace "$VPC_CIDR" via "$BASTION_IP"
    log "route set: $VPC_CIDR via $BASTION_IP"
  else
    log "route ok: $VPC_CIDR via $BASTION_IP"
  fi
}

apply_no_snat() {
  local ns; ns="$(qrouter_netns)"
  if [[ -z "$ns" ]]; then
    log "qrouter netns 없음 — no-SNAT 건너뜀(라우터 미생성?)"; return 0
  fi
  # POSTROUTING nat 최상단에 dest VPC_CIDR ACCEPT → 이후 SNAT/MASQUERADE 미적용(소스 보존).
  if ip netns exec "$ns" iptables -t nat -C POSTROUTING -d "$VPC_CIDR" -j ACCEPT 2>/dev/null; then
    log "no-SNAT ok ($ns): -d $VPC_CIDR ACCEPT"
  else
    ip netns exec "$ns" iptables -t nat -I POSTROUTING 1 -d "$VPC_CIDR" -j ACCEPT
    log "no-SNAT added ($ns): -d $VPC_CIDR ACCEPT"
  fi
}

do_apply() {
  need_root
  apply_route
  apply_no_snat
}

do_status() {
  echo "VPC_CIDR=$VPC_CIDR BASTION_IP=$BASTION_IP"
  echo "[route]"; ip route show "$VPC_CIDR" 2>/dev/null || echo "  (없음)"
  echo "[ip_forward] $(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)"
  local ns; ns="$(qrouter_netns)"
  echo "[qrouter] ${ns:-none}"
  [[ -n "$ns" ]] && ip netns exec "$ns" iptables -t nat -S POSTROUTING 2>/dev/null | grep -F "$VPC_CIDR" || true
}

do_install() {
  need_root
  cat > "/etc/systemd/system/${UNIT_NAME}.service" <<UNIT
[Unit]
Description=ECR-over-VPN dataplane (route + qrouter no-SNAT)
After=network-online.target openvswitch-switch.service
Wants=network-online.target

[Service]
Type=oneshot
Environment=VPC_CIDR=${VPC_CIDR}
Environment=BASTION_IP=${BASTION_IP}
ExecStart=${SELF_PATH} apply
UNIT
  cat > "/etc/systemd/system/${UNIT_NAME}.timer" <<TIMER
[Unit]
Description=Reapply ECR-over-VPN dataplane periodically (qrouter 재생성 대비)

[Timer]
OnBootSec=30s
OnUnitActiveSec=2min
AccuracySec=15s

[Install]
WantedBy=timers.target
TIMER
  systemctl daemon-reload
  systemctl enable --now "${UNIT_NAME}.timer"
  systemctl start "${UNIT_NAME}.service" || true
  log "installed + enabled: ${UNIT_NAME}.timer (2분 주기 재적용)"
}

case "${1:-apply}" in
  apply)   do_apply ;;
  install) do_install ;;
  status)  do_status ;;
  *) echo "usage: $0 [apply|install|status]" >&2; exit 64 ;;
esac
