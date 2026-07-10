# OpenStack Implementation

이 문서는 repository 기준으로 OpenStack 쪽이 어떻게 구현되어 있는지 정리한다.
중요한 전제는 이 프로젝트가 Nova, Glance, Neutron 같은 OpenStack 서비스를 직접
구현하지 않는다는 점이다. OpenStack control plane은 DevStack 또는 기존
OpenStack이 제공하고, 이 repository는 그 위에서 필요한 설정, 이미지, 네트워크,
VM, Kubernetes bootstrap, proxy, CI workflow를 자동화한다.

## 구현 범위

OpenStack 관련 구현은 크게 네 계층으로 나뉜다.

1. Local OpenStack control plane

   `ha-openstack` LXD 컨테이너 안에 DevStack을 설치한다. 이 경로는 로컬 검증과
   GitHub Actions remote host에서 private cloud foundation을 만들 때 사용한다.

2. OpenStack tenant resource

   `private/openstack` Terraform module이 OpenStack provider를 사용해서 network,
   subnet, router, security group, key pair, port, server, floating IP를 만든다.

3. VM bootstrap

   `cloud-init/base.yaml.tftpl`가 VM 역할별 초기 패키지, kernel module, GPU,
   GitLab, Harbor 준비 작업을 수행한다.

4. Platform bootstrap

   Terraform output을 읽어서 OpenStack VM에 Kubernetes를 올리고, 이후 storage,
   model-build, registry, reverse proxy를 구성한다.

## 주요 파일

| 파일 | 역할 |
| --- | --- |
| `ha` | 로컬 CLI. DevStack 설치, OpenStack Terraform apply, Kubernetes bootstrap 진입점 |
| `private/openstack/main.tf` | OpenStack tenant resource 선언 |
| `private/openstack/variables.tf` | OpenStack resource, VM role, GPU, cloud-init 변수 |
| `private/openstack/outputs.tf` | VM inventory, network, security group, NFS IP output |
| `private/openstack/cloud-init/base.yaml.tftpl` | VM 역할별 cloud-init bootstrap |
| `private/openstack/scripts/cache-openstack-images.sh` | 역할별 Glance cache image 생성 |
| `private/kubernetes-bootstrap/bootstrap-k8s.sh` | OpenStack VM 위 kubeadm bootstrap |
| `private/ci/private-cloud-apply.sh` | DevStack, image cache, Terraform, VM, K8s, proxy phase 자동화 |
| `.github/workflows/private-cloud-controller.yml` | GitHub Actions private cloud DAG |
| `.github/workflows/private-cloud-remote.yml` | remote host SSH executor |

## Control Plane 구성

### 단순 로컬 경로

`ha up openstack-local --auto-approve`는 `ha-openstack` LXD 컨테이너를 만들고
DevStack을 설치한다.

구성 순서:

1. LXD 컨테이너 생성 또는 재사용
2. privileged/nesting 설정 적용
3. host kernel modules mount
4. `/dev/kvm`이 있으면 KVM device 연결
5. DevStack APT/cache directory mount
6. Glance image store, Nova instances directory persistent mount
7. DevStack clone
8. `local.conf` 작성
9. Open vSwitch kernel module load
10. `stack.sh` 실행
11. `.ha/openstack-local/openrc.sh` handoff 작성

단순 경로의 `local.conf`는 `ENABLE_VOLUME_BACKING_FILE=True`를 설정하고 Cinder를
명시적으로 끄지 않는다. readiness check도 `openstack volume service list`를
확인한다. 따라서 이 경로는 DevStack 기본 서비스 검증에 가깝다.

### Private Cloud Apply 경로

GitHub Actions와 실제 private cloud automation은 `private/ci/private-cloud-apply.sh`
를 중심으로 동작한다.

`devstack` phase는 다음을 수행한다.

1. 기존 DevStack container 재사용 또는 full reinstall
2. LXD raw config, kernel module, KVM, VFIO device 연결
3. DevStack root/stack cache, APT cache, persistent storage mount
4. GPU passthrough가 가능하면 host GPU를 VFIO로 bind
5. DevStack clone 및 `local.conf` 작성
6. `stack.sh` 실행
7. role별 flavor 생성
8. Nova PCI passthrough 설정
9. Horizon proxy 설정
10. OpenStack login user 동기화
11. public egress 설정

Private Cloud Apply 경로의 `local.conf`는 운영 I/O를 줄이기 위해 다음 서비스를
명시적으로 끈다.

```text
disable_service tempest
disable_service swift
disable_service cinder
```

이 경로의 persistent path는 기본적으로 다음과 같다.

```text
.ha/openstack/persistent/glance-images  -> /opt/stack/data/glance/images
.ha/openstack/persistent/nova-instances -> /opt/stack/data/nova/instances
```

## Keystone

Keystone은 DevStack 또는 기존 OpenStack이 제공한다. repository가 Keystone API를
직접 구현하지는 않는다.

구현 방식:

- `OS_AUTH_URL`, `OS_USERNAME`, `OS_PASSWORD`, project/domain env를 사용한다.
- `ha up openstack`은 기존 OpenStack의 Keystone endpoint가 있어야 한다.
- local DevStack 경로는 `.ha/openstack-local/openrc.sh`를 작성해서 admin credential을
  handoff한다.
- private cloud apply는 `OS_*` 값을 remote workflow env로 전달하고, token 발급
  preflight를 수행한다.
- 필요하면 DevStack 내부에 login user/project를 만들고 `member`, `admin` role을
  부여한다.

주의점:

- `OS_AUTH_URL`은 이 repository가 만드는 값이 아니다. 기존 OpenStack provider를
  쓸 때는 외부 Keystone endpoint를 사용한다.
- local DevStack 경로에서는 컨테이너 IP 기반 `http://<ip>/identity/v3`를 사용한다.

## Nova

Nova는 VM 생성과 flavor, GPU passthrough의 중심이다.

### Terraform VM 선언

`private/openstack/main.tf`는 다음 role VM을 선언한다.

| Role | Terraform resource | 기본 수량 |
| --- | --- | --- |
| control-plane | `openstack_compute_instance_v2.control_plane` | 1 |
| build-worker | `openstack_compute_instance_v2.build_worker` | 1 |
| gpu-worker | `openstack_compute_instance_v2.gpu_worker` | 1 |
| gitlab | `openstack_compute_instance_v2.gitlab` | 1 |
| harbor | `openstack_compute_instance_v2.harbor` | 1 |

각 VM은 공통적으로 다음 값을 가진다.

- role별 `image_name`
- role별 `flavor_name`
- 공통 key pair
- role metadata
- role별 Neutron port
- `config_drive = true`
- `cloud-init/base.yaml.tftpl` user data
- 긴 create/update/delete timeout

Terraform lifecycle은 `flavor_name`, `image_name`, `user_data` 변경을 ignore한다.
이미 running VM이 있을 때 이미지나 cloud-init 변경만으로 불필요한 recreate가
발생하지 않도록 하기 위한 설정이다.

### Flavor

Private Cloud Apply 경로는 role별 flavor를 만든다.

| Flavor 용도 | 예시 이름 |
| --- | --- |
| control-plane | `ha.m1.control` |
| build-worker | `ha.m1.build` |
| gitlab | `ha.m1.gitlab` |
| harbor | `ha.m1.harbor` |
| gpu-worker | `g1.large` |

모든 flavor에는 `hw_rng:allowed=True`를 설정한다.

GPU flavor에는 다음 property를 추가한다.

```text
pci_passthrough:alias=nvidia-gpu:1
hw:pci_numa_affinity_policy=preferred
```

### GPU Passthrough

GPU passthrough는 두 단계다.

1. Host/LXD 단계

   `private-cloud-apply.sh`가 NVIDIA PCI device를 찾고 IOMMU group을 확인한다.
   설정에 따라 device를 `vfio-pci`로 bind하고, `ha-openstack` LXD 컨테이너에
   `/dev/vfio`와 필요한 group device를 연결한다.

2. Nova 단계

   DevStack 내부 `/etc/nova/nova.conf`, `/etc/nova/nova-cpu.conf`에 다음을 설정한다.

   - `pci.device_spec`
   - `pci.alias`
   - `filter_scheduler.available_filters`
   - `filter_scheduler.enabled_filters`에 `PciPassthroughFilter` 포함

   설정 후 Nova API, scheduler, conductor, compute service를 restart한다.

## Glance

Glance는 base image와 role별 cache image 저장소로 사용한다. repository가 Glance
API를 직접 구현하지는 않고, OpenStack CLI와 Terraform image name 참조를 사용한다.

### Base Image

지원하는 base image는 현재 다음 두 개다.

| 이름 | URL |
| --- | --- |
| `ubuntu-22.04` | Ubuntu Jammy cloud image |
| `ubuntu-24.04` | Ubuntu Noble cloud image |

image가 Glance에 없으면 다운로드 후 `openstack image create`로 등록한다.

### Role별 Cache Image

`private/openstack/scripts/cache-openstack-images.sh`가 cache image를 만든다.

이름 규칙:

```text
hybrid-ai-cache-<role>-<manifest-hash>
```

예:

```text
hybrid-ai-cache-control-plane-<hash>
hybrid-ai-cache-build-worker-<hash>
hybrid-ai-cache-gpu-worker-<hash>
hybrid-ai-cache-gitlab-<hash>
hybrid-ai-cache-harbor-<hash>
```

cache image 생성 흐름:

1. role manifest 생성
2. manifest hash 기반 image name과 deterministic UUID 생성
3. Glance에 같은 image가 있으면 cache hit
4. local `.ha/openstack/image-cache/*.qcow2`가 있으면 Glance로 upload
5. 없으면 builder VM 생성
6. builder VM에 SSH 접속
7. role별 package와 dependency 설치
8. builder VM shutdown
9. Nova instance disk를 qcow2로 변환
10. Glance image로 등록
11. local qcow2 cache와 manifest sidecar 저장
12. Terraform image override env 작성

role별 cache 내용:

| Role | 주요 cache 내용 |
| --- | --- |
| control-plane | common package, optional NFS server |
| build-worker | common package |
| gpu-worker | NVIDIA container toolkit, driver, CUDA, cuDNN, training Python packages |
| gitlab | Docker, GitLab container image pre-pull |
| harbor | Docker, docker compose, Harbor directory |

Glance upload 안정화를 위해 upload timeout과 registered limit도 조정한다.

## Neutron

Neutron은 private network, subnet, router, security group, port, floating IP를
담당한다.

Terraform resource:

- `openstack_networking_network_v2.private`
- `openstack_networking_subnet_v2.private`
- `openstack_networking_router_v2.private`
- `openstack_networking_router_interface_v2.private`
- `openstack_networking_secgroup_v2.private`
- `openstack_networking_secgroup_rule_v2.*`
- role별 `openstack_networking_port_v2.*`
- role별 `openstack_networking_floatingip_v2.*`
- role별 `openstack_networking_floatingip_associate_v2.*`

기본 private CIDR은 `10.42.0.0/24`이고, DNS nameserver는 Terraform 변수로 받는다.

Security group 정책:

- private CIDR 내부 TCP 허용
- private CIDR 내부 UDP 허용
- private CIDR 내부 ICMP 허용
- SSH 허용 CIDR은 변수로 제한
- GitLab HTTP 허용 CIDR은 별도 변수
- Harbor HTTP/HTTPS 허용 CIDR은 별도 변수
- MinIO NodePort `30900`, console NodePort `30990` 허용 CIDR은 별도 변수

Floating IP:

- `assign_floating_ips = true`일 때만 role별 floating IP를 생성하고 port에 associate한다.
- 현재 private network access 기준은 FIP를 쓰지 않고 private IP와 proxy/tunnel을 우선한다.

Private route와 SSH tunnel:

- DevStack container에서 OpenStack private CIDR로 가는 route를 `br-ex` gateway로 설정한다.
- LXD proxy device가 host TCP port를 VM private IP `:22`로 연결한다.
- 예시 포트는 control `2201`, build `2202`, gpu `2203`, gitlab `2204`, harbor `2205`다.

## Cinder

이 repo의 핵심 private cloud apply 경로는 Cinder를 사용하지 않는다.

- `private-cloud-apply.sh`의 DevStack `local.conf`에서 `disable_service cinder`를 설정한다.
- Storage는 Cinder volume이 아니라 Kubernetes 위 NFS/MinIO 중심으로 구성한다.
- 단순 `ha up openstack-local` 경로는 DevStack volume service readiness를 확인하므로
  DevStack 기본 Cinder 검증 성격이 남아 있다.

## Swift

Swift도 private cloud apply 경로에서는 사용하지 않는다.

- `disable_service swift`로 비활성화한다.
- Object storage는 Swift 대신 Kubernetes 위 MinIO tenant를 사용한다.

## Horizon

Horizon은 DevStack dashboard를 reverse proxy로 노출한다.

구현 방식:

1. LXD proxy device `horizon-proxy` 생성
2. host `127.0.0.1:18081`을 container `127.0.0.1:80`으로 연결
3. Horizon local settings에 proxy 관련 설정 추가
4. Caddy가 `openstack.<base-domain>` 요청을 Horizon upstream으로 전달

추가되는 Horizon 설정:

- `USE_X_FORWARDED_HOST = True`
- `SECURE_PROXY_SSL_HEADER`
- `CSRF_TRUSTED_ORIGINS`

## Placement

Placement는 DevStack/Nova 내부 scheduling path로 사용된다. repository에서 Placement
resource를 직접 선언하거나 별도 API를 호출하지는 않는다.

GPU scheduling은 Placement를 직접 다루는 대신 Nova PCI alias, scheduler filter,
flavor property로 연결한다.

## 사용하지 않는 OpenStack 기능

아래 기능은 현재 repository 기준으로 구현되어 있지 않다.

| 기능 | 상태 |
| --- | --- |
| Heat | Terraform을 사용하므로 Heat stack 구현 없음 |
| Ironic | bare metal provisioning 구현 없음 |
| Magnum | Kubernetes는 kubeadm script로 직접 bootstrap |
| Octavia | load balancer resource 없음 |
| Designate | DNS는 Cloudflare automation과 internal DNS record로 처리 |
| Manila | shared filesystem은 NFS 기반 Kubernetes StorageClass로 처리 |
| Barbican | secret storage 구현 없음 |
| Trove | database service 구현 없음 |
| Sahara | data processing service 구현 없음 |

## Cloud-init VM Bootstrap

`cloud-init/base.yaml.tftpl`는 모든 VM에 공통 bootstrap을 적용하고 role별 분기를 둔다.

공통 처리:

- 기본 패키지 설치
- `/etc/hybrid-ai-node-role` 기록
- `/etc/hybrid-ai-foundation.env` 기록
- Kubernetes/storage kernel module 설정
- sysctl 설정
- qemu guest agent 시작
- iSCSI, multipath, NVMe/TCP 준비
- CPU governor performance 적용
- dependency check 실행

Role별 처리:

| Role | 처리 |
| --- | --- |
| control-plane | NFS server package 포함 |
| gpu-worker | NVIDIA driver, NVIDIA container runtime, CUDA, cuDNN, training venv, PCIe tune |
| gitlab | Docker 설치, GitLab image pull 또는 archive load |
| harbor | Docker, compose, Harbor directory 준비 |
| build-worker | 공통 build/runtime dependency 중심 |

GPU worker는 `hybrid-ai-training-run` helper도 제공한다. 이 helper는 GitLab/CI job에서
venv, pip cache, checkpoint, artifact directory를 준비한 뒤 training command를 실행한다.

## Kubernetes Bootstrap

OpenStack VM 생성 후 `private/kubernetes-bootstrap/bootstrap-k8s.sh`가 Terraform
output을 읽어 Kubernetes cluster를 구성한다.

Inventory source:

- `terraform output -json`
- optional local Terraform state
- optional pre-generated output JSON

Bootstrap 순서:

1. Terraform output에서 control-plane, build-worker, gpu-worker, harbor node 추출
2. SSH target 선택: floating IP 우선 또는 private IP
3. 첫 control-plane에 kubeadm init 실행
4. CNI manifest 적용
5. control-plane taint 제거
6. worker join command 생성
7. build-worker, gpu-worker, harbor를 worker로 join
8. node label과 GPU taint 적용
9. kubeconfig를 `.ha/openstack/kubeconfig`로 저장
10. `.ha/handoff/openstack-kubernetes.env` handoff 작성

Node label 기준:

| Role | Label/Taint |
| --- | --- |
| all | `hybrid-ai.io/provider=openstack` |
| control-plane | `hybrid-ai.io/node-role=control-plane` |
| build-worker | `hybrid-ai.io/node-role=build-worker`, `node-role.kubernetes.io/build-worker=true` |
| gpu-worker | `hybrid-ai.io/node-role=gpu-worker`, `hybrid-ai.io/accelerator=nvidia`, GPU taint |
| harbor | `hybrid-ai.io/node-role=harbor`, `node-role.kubernetes.io/harbor=true` |

## Reverse Proxy와 DNS

관리 UI와 VM SSH는 OpenStack floating IP에 직접 의존하지 않고 host/LXD proxy와 DNS를
사용한다.

HTTP/S entrypoint:

- `openstack.<base-domain>` -> Horizon
- `gitlab.<base-domain>` -> GitLab VM
- `harbor.<base-domain>` -> Harbor VM
- `minio.<base-domain>` -> Kubernetes NodePort
- `minio-console.<base-domain>` -> Kubernetes NodePort
- `k8s`, `grafana`, `argocd` entrypoint 자리도 준비

SSH entrypoint:

- `control-ssh.<base-domain>:2201`
- `build-ssh.<base-domain>:2202`
- `gpu-ssh.<base-domain>:2203`
- `gitlab-ssh.<base-domain>:2204`
- `harbor-ssh.<base-domain>:2205`

DNS automation:

- Cloudflare token과 zone ID가 있으면 workflow가 record를 upsert한다.
- public service는 `ssh.<base-domain>`으로 CNAME을 둔다.
- internal DNS를 켜면 Terraform output private IP 기준으로 internal A record를 만든다.

## Terraform Apply

`ha up openstack --auto-approve`는 기존 OpenStack provider를 대상으로 Terraform을
실행하는 일반 경로다.

흐름:

1. Terraform 필요 도구 확인
2. SSH public key 생성 또는 env 사용
3. OpenStack auth env 검증
4. Terraform init
5. Terraform fmt check
6. Terraform validate
7. Terraform plan
8. Terraform apply
9. `.ha/handoff/openstack-output.json` 작성

`private-cloud-apply.sh`의 Terraform phase는 local DevStack에 특화된 값을 추가로
생성한다.

- public network ID 조회
- public subnet CIDR 조회
- role별 count/flavor/image/private IP override 작성
- generated `zz-local-devstack.auto.tfvars` 작성
- orphan resource cleanup
- host capacity preflight
- OpenStack quota preflight
- backend config 처리
- keypair import best effort
- destructive plan guard
- Terraform apply
- `.ha/openstack/terraform-output.json` 작성

## CI/CD Flow

GitHub Actions private cloud controller는 phase를 나눠 실행한다.

```text
devstack
  -> images
  -> terraform
  -> control-plane / build-worker / gpu-worker / gitlab / harbor
  -> k8s
  -> storage
  -> model-build
  -> proxy
  -> finalize
```

동시성 제어:

- workflow concurrency group: `private-cloud-foundation-v2`
- remote host의 phase lock: `.ha/ci/locks/<phase>.lockdir`
- `devstack`, `images`, `terraform`은 직렬 실행
- Terraform 이후 role별 VM phase는 분리 실행
- `k8s`는 control-plane, build-worker, gpu-worker, harbor 준비 후 실행
- `model-build`는 storage와 Harbor 준비 후 실행
- `proxy`는 GitLab과 Harbor 준비 후 실행

## Destroy와 Cleanup

`private/ci/private-cloud-destroy.sh`는 Terraform destroy 전후 cleanup을 수행한다.

주요 처리:

- local DevStack auth env 준비
- OpenStack auth preflight
- Kubernetes workload best-effort cleanup
- Terraform init
- Terraform destroy
- orphan OpenStack resource cleanup
- optional DevStack container cleanup

orphan cleanup은 prefix 기반으로 server, floating IP, router, subnet, port, network,
security group을 정리한다.

## 운영 관점 요약

- OpenStack control plane은 DevStack 또는 외부 OpenStack에 의존한다.
- Terraform은 tenant resource만 관리한다.
- Nova VM은 role별로 나뉘고, cloud-init이 VM 내부 dependency를 준비한다.
- Glance cache image로 반복 apply 시간을 줄인다.
- Neutron private network와 LXD proxy를 조합해 FIP 없는 접근 경로를 만든다.
- Cinder/Swift는 full private cloud apply 경로에서 사용하지 않는다.
- Kubernetes는 Magnum이 아니라 kubeadm script로 직접 구성한다.
- DNS와 reverse proxy는 OpenStack이 아니라 Cloudflare/Caddy/LXD proxy로 처리한다.
