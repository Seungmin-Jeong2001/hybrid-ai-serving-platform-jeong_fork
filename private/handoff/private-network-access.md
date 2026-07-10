# Private Network Access

## 현재 기준

| 항목 | 값 |
| --- | --- |
| Floating IP | VM별 FIP 미사용 |
| 외부 진입점 | `ssh.intp.me` / reverse proxy |
| AWS VPN 진입점 | MacMini Bastion Linux gateway |
| 내부 VM 주소 | 문서에는 DNS만 고정, 실제 IP는 조회 명령으로 확인 |
| 내부 DNS zone | `internal.intp.me` |
| K8s Service DNS | `*.svc.cluster.local` |

## VM 내부 DNS

| 대상 | DNS |
| --- | --- |
| control | `control.internal.intp.me` |
| build | `build.internal.intp.me` |
| gpu | `gpu.internal.intp.me` |
| GitLab VM | `gitlab.internal.intp.me` |
| Harbor VM | `harbor.internal.intp.me` |
| K8s API VM endpoint | `k8s-api.internal.intp.me` |
| NFS | `nfs.internal.intp.me` |
| MinIO NodePort | `minio.internal.intp.me` |
| MinIO console NodePort | `minio-console.internal.intp.me` |

## K8s Service DNS

| 대상 | DNS | Port |
| --- | --- | --- |
| Kubernetes API | `kubernetes.default.svc.cluster.local` | `443` |
| CoreDNS | `kube-dns.kube-system.svc.cluster.local` | `53` |
| Argo Server | `argo-server.argo.svc.cluster.local` | `2746` |
| Argo Events EventBus | `eventbus-default-stan-svc.argo-events.svc.cluster.local` | `4222`, `6222`, `8222` |
| MinIO S3 API, portless | `minio.minio-tenant.svc.cluster.local` | `80` |
| MinIO S3 API, direct | `minio-api.minio-tenant.svc.cluster.local` | `9000` |
| MinIO console | `minio-console.minio-tenant.svc.cluster.local` | `9090` |
| MinIO tenant console | `hybrid-ai-console.minio-tenant.svc.cluster.local` | `9090` |
| MinIO headless | `hybrid-ai-hl.minio-tenant.svc.cluster.local` | `9000` |
| MinIO Operator | `operator.minio-operator.svc.cluster.local` | `4221` |
| MinIO Operator STS | `sts.minio-operator.svc.cluster.local` | `4223` |

## 통신 원칙

| 구간 | 사용할 주소 |
| --- | --- |
| K8s Pod/Workflow/Runner -> K8s service | `*.svc.cluster.local` |
| K8s Pod -> 등록된 VM node | `*.internal.intp.me` |
| VM -> VM | `*.internal.intp.me` |
| VM/Pod -> AWS ECR/STS | Bastion Site-to-Site VPN + Route53 Inbound Resolver |
| 외부 사용자 -> 관리 UI | 기존 public URL, reverse proxy 경유 |
| 등록 안 된 standalone VM | FIP 대신 private IP 사용 후 internal DNS 등록 |

## 자주 쓰는 주소

| 용도 | 주소 |
| --- | --- |
| MinIO, K8s 내부 | `http://minio.minio-tenant.svc.cluster.local` |
| MinIO, K8s API service 직접 | `http://minio-api.minio-tenant.svc.cluster.local:9000` |
| MinIO, 외부/Tailscale/reverse proxy | `https://minio.intp.me` |
| MinIO, VM 내부망 디버깅용 | `http://minio.internal.intp.me:30900` |
| GitLab, 외부 관리 | `https://gitlab.intp.me` |
| Harbor, 외부 관리 | `https://harbor.intp.me` |
| OpenStack Horizon | `https://openstack.intp.me` |

## 예시 명령어

`.ha/openstack/ssh_config`는 private cloud host 안에서 DevStack/LXC를 경유해 VM private address로 붙기 위한 로컬 자동화용 설정이다. 명령에는 `*.internal.intp.me`를 사용한다.

```text
local host -> lxc exec ha-openstack -- nc -> VM private IP:22
```

Tailscale에 접속된 외부 클라이언트에서는 `ssh_config` 없이 아래 포트별 tunnel로 접속한다.

```text
client -> control-ssh.intp.me:2201 -> control VM:22
client -> build-ssh.intp.me:2202 -> build VM:22
client -> gpu-ssh.intp.me:2203 -> gpu VM:22
client -> gitlab-ssh.intp.me:2204 -> gitlab VM:22
client -> harbor-ssh.intp.me:2205 -> harbor VM:22
```

Tailscale 접속 상태에서 VM으로 직접 SSH:

```bash
ssh -i ~/.ssh/hybrid-ai-private-admin -p 2201 ubuntu@control-ssh.intp.me
ssh -i ~/.ssh/hybrid-ai-private-admin -p 2202 ubuntu@build-ssh.intp.me
ssh -i ~/.ssh/hybrid-ai-private-admin -p 2203 ubuntu@gpu-ssh.intp.me
ssh -i ~/.ssh/hybrid-ai-private-admin -p 2204 ubuntu@gitlab-ssh.intp.me
ssh -i ~/.ssh/hybrid-ai-private-admin -p 2205 ubuntu@harbor-ssh.intp.me
```

private cloud host 로컬에서 VM으로 접속:

```bash
ssh -F .ha/openstack/ssh_config gpu.internal.intp.me
ssh -F .ha/openstack/ssh_config control.internal.intp.me
```

GPU VM에서 다른 VM으로 ping:

```bash
ssh -F .ha/openstack/ssh_config gpu.internal.intp.me \
  'ping -c 3 control.internal.intp.me'

ssh -F .ha/openstack/ssh_config gpu.internal.intp.me \
  'ping -c 3 build.internal.intp.me'

ssh -F .ha/openstack/ssh_config gpu.internal.intp.me \
  'ping -c 3 gitlab.internal.intp.me'
```

control VM에서 GPU VM으로 ping:

```bash
ssh -F .ha/openstack/ssh_config control.internal.intp.me \
  'ping -c 3 gpu.internal.intp.me'
```

VM 내부 DNS 확인:

```bash
ssh -F .ha/openstack/ssh_config gpu.internal.intp.me \
  'getent hosts control.internal.intp.me minio.internal.intp.me'
```

VM에서 MinIO NodePort health 확인:

```bash
ssh -F .ha/openstack/ssh_config gpu.internal.intp.me \
  'curl -fsS http://minio.internal.intp.me:30900/minio/health/live'
```

K8s Service DNS 확인:

```bash
KUBECONFIG=.ha/openstack/kubeconfig kubectl -n model-build run dns-check \
  --rm -i --restart=Never \
  --image=busybox:1.36 \
  --command -- nslookup minio.minio-tenant.svc.cluster.local
```

K8s Pod에서 MinIO service health 확인:

```bash
KUBECONFIG=.ha/openstack/kubeconfig kubectl -n model-build run minio-health-check \
  --rm -i --restart=Never \
  --image=curlimages/curl:8.11.1 \
  --command -- curl -fsS \
  http://minio.minio-tenant.svc.cluster.local/minio/health/live
```

K8s Pod에서 VM internal DNS ping:

```bash
KUBECONFIG=.ha/openstack/kubeconfig kubectl -n model-build run node-ping-check \
  --rm -i --restart=Never \
  --image=busybox:1.36 \
  --command -- sh -c 'ping -c 3 control.internal.intp.me && ping -c 3 build.internal.intp.me && ping -c 3 gpu.internal.intp.me'
```

K8s 내부에서 MinIO client 사용:

```bash
mc alias set minio \
  http://minio-api.minio-tenant.svc.cluster.local:9000 \
  "$MINIO_ACCESS_KEY" \
  "$MINIO_SECRET_KEY"

mc ls minio
```

OpenStack FIP 제거 상태 확인:

```bash
lxc exec ha-openstack -- bash -lc '
  source /opt/stack/devstack/openrc admin admin >/dev/null
  openstack floating ip list
'
```

VM private IP 상태 확인:

```bash
lxc exec ha-openstack -- bash -lc '
  source /opt/stack/devstack/openrc admin admin >/dev/null
  openstack server list --all-projects
'
```

K8s Service DNS와 port 확인:

```bash
KUBECONFIG=.ha/openstack/kubeconfig kubectl get svc -A
```

AWS private endpoint DNS 확인:

```bash
KUBECONFIG=.ha/openstack/kubeconfig kubectl -n model-build run ecr-dns-check \
  --rm -i --restart=Never \
  --image=busybox:1.36 \
  --command -- nslookup api.ecr.ap-northeast-2.amazonaws.com
```

이 결과가 public IP로 나오면 ECR push는 아직 VPN/VPCE 경로가 아니다. `private/bastion/configure-private-dns.sh`로 CoreDNS 조건부 forwarding을 적용하고, AWS VPC CIDR route가 Bastion gateway를 향하는지 확인한다.

K8s node/pod IP가 필요할 때만 조회:

```bash
KUBECONFIG=.ha/openstack/kubeconfig kubectl get nodes -o wide
KUBECONFIG=.ha/openstack/kubeconfig kubectl get pods -A -o wide
```

Terraform 재-apply 전 no-op 확인:

```bash
cd private/openstack
terraform plan -input=false -refresh=true -parallelism=2 -no-color
```

## 검증 결과

| 검증 | 결과 |
| --- | --- |
| GPU VM -> control/build/gitlab/harbor/minio/nfs ICMP | `0% packet loss` |
| control VM -> gpu/build/gitlab/harbor/minio ICMP | `0% packet loss` |
| K8s Pod -> VM internal DNS ICMP | `0% packet loss` |
| K8s Service DNS `minio.minio-tenant.svc.cluster.local` | 해석 성공 |
| K8s Pod -> MinIO health | HTTP `200` |
| GPU VM -> MinIO object read via internal DNS | HTTP `206`, 1024 bytes read |

## 주의

Kubernetes `ClusterIP` service는 ICMP ping 검증 대상이 아니다. Service는 `curl`, `mc`, application protocol로 확인한다.

Private IP와 ClusterIP는 credential은 아니지만 내부 토폴로지 정보다. handoff 문서에는 DNS와 조회 명령을 우선 기록하고, 고정 IP 값은 장애 분석이나 변경 작업에서만 별도로 확인한다.
