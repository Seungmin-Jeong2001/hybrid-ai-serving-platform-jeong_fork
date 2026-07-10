# Cloudflare Tunnel (in-cluster) — `*.intp.me` 정식 접속

사용자 → Cloudflare 엣지(글로벌 HA, 단일 진입점) → cloudflared Deployment(클러스터 내, replicas=2 노드 분산) → 서비스.

표준 + 무SPOF + 확장. MacMini 같은 단일 박스 경유 없음.

## 노출 도메인
| 도메인 | 백엔드 |
|---|---|
| minio.intp.me | `minio.minio-tenant.svc:80` → 9000 (**S3 API**, mc/SDK용) |
| minio-console.intp.me | `minio-console.minio-tenant.svc:9090` (**웹 콘솔**) |
| gitlab.intp.me | `10.42.0.61:80` (GitLab VM) |
| harbor.intp.me | `10.42.0.127:80` (Harbor VM) |
| openstack.intp.me | `192.168.0.250:80` (Kolla Horizon VIP) |

## 사전조건 (DNS)
intp.me Cloudflare 존에 CNAME(Proxied) → `<TUNNEL_ID>.cfargotunnel.com`:
`minio`, `gitlab`, `harbor`, `openstack`. (CLOUDFLARE_API_TOKEN으로 생성됨)

## 시크릿 (git에 없음 — 별도 생성)
터널 자격증명은 MacMini의 `~/.cloudflared/<TUNNEL_ID>.json`. 클러스터에 주입:
```
kubectl -n cloudflared create secret generic tunnel-creds \
  --from-file=credentials.json=<TUNNEL_ID>.json
```

## 배포
```
kubectl apply -f cloudflared.yaml
```

## 함정 메모
- **hostNetwork 필수**: Pod CIDR `192.168.0.0/16`이 LAN `192.168.0.0/24`와 겹쳐, 일반 파드는 호스트 VIP(192.168.0.250 = Horizon)에 i/o timeout. hostNetwork + `ClusterFirstWithHostNet`로 해결.
- **Horizon CSRF**: Cloudflare(HTTPS 종단) 뒤 Horizon은 `/etc/kolla/config/horizon/_9999-proxy.py`에 `CSRF_TRUSTED_ORIGINS`/`SECURE_PROXY_SSL_HEADER` 필요.
