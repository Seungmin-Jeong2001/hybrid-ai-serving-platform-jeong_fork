#!/usr/bin/env bash
# CoreDNS 조건부 포워딩: amazonaws.com → Route53 resolver inbound (ECR-over-VPN turnkey).
# apply마다 resolver inbound IP가 바뀌므로, apply 후 이 스크립트를 재실행해 CoreDNS를 재패치한다.
# idempotent — 기존 amazonaws.com 블록을 교체.
#
# 사용:
#   KUBECONFIG=.ha/openstack/kubeconfig ./ecr-vpn-coredns.sh                 # tf output에서 resolver IP 자동
#   KUBECONFIG=.ha/openstack/kubeconfig ./ecr-vpn-coredns.sh 10.0.11.81 10.0.12.102
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${KUBECONFIG:?KUBECONFIG 필요 (예: .ha/openstack/kubeconfig)}"

# resolver inbound IP: 인자 우선, 없으면 terraform output에서
if [[ $# -ge 1 ]]; then
  IPS=("$@")
else
  mapfile -t IPS < <(cd "$ROOT/public/terraform" && terraform output -json resolver_inbound_ips 2>/dev/null \
    | python3 -c 'import sys,json;[print(x) for x in json.load(sys.stdin)]')
fi
[[ "${#IPS[@]}" -ge 1 ]] || { echo "resolver inbound IP를 못 구함 (인자로 넘기거나 terraform output 확인)" >&2; exit 1; }
echo "[coredns] resolver inbound: ${IPS[*]}"

CUR="$(kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}')"
# 기존 amazonaws.com 블록 제거(idempotent) 후 새 블록 prepend
STRIPPED="$(printf '%s' "$CUR" | awk '
  /^amazonaws\.com:53 \{/ {skip=1}
  skip && /^\}/ {skip=0; next}
  !skip {print}
')"
NEW="amazonaws.com:53 {
    errors
    cache 30
    forward . ${IPS[*]}
}
${STRIPPED}"

python3 -c "import json,sys;print(json.dumps({'data':{'Corefile':sys.argv[1]}}))" "$NEW" > /tmp/ecr-vpn-coredns-patch.json
kubectl -n kube-system patch cm coredns --type merge --patch-file /tmp/ecr-vpn-coredns-patch.json
rm -f /tmp/ecr-vpn-coredns-patch.json
kubectl -n kube-system rollout restart deploy coredns
kubectl -n kube-system rollout status deploy coredns --timeout=90s
echo "[coredns] amazonaws.com → ${IPS[*]} 포워딩 적용 완료"
