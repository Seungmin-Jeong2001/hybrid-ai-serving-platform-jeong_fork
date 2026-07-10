# OpenStack via Kolla-Ansible (운영 전환, Phase A)

현재 private cloud는 `private/ci/private-cloud-apply.sh`의 `devstack` 페이즈가 LXD 컨테이너
`ha-openstack` 안에서 DevStack(`stack.sh`)으로 OpenStack을 띄운다. 이 디렉터리는 그 DevStack을
**운영 등급 Kolla-Ansible 배포로 교체**하기 위한 스캐폴딩이다.

> 상태: **스캐폴딩만**. 기존 devstack 경로는 그대로 두고, Kolla 경로를 나란히 추가했다.
> 라이브 서버에서 검증 후 `devstack` 페이즈를 이 경로로 치환한다. (설계: `~/.claude/plans/ecr-resilient-ember.md`)

## DevStack과의 매핑 (값 동기화)

`private-cloud-apply.sh`에서 읽어 그대로 반영한 값:

| 항목 | DevStack(local.conf / 변수) | Kolla 반영 |
| --- | --- | --- |
| 활성 서비스 | tempest/swift/cinder **disable** | `enable_cinder/swift/heat: no` (`globals.yml`) |
| 인증 | admin/admin, `Default` 도메인, `RegionOne` | `globals.yml` + `kolla-genpwd` |
| 내부 CIDR | `10.42.0.0/24` (VM 고정 IP) | Neutron tenant net은 **Terraform 소유**(`private/openstack/`) |
| libvirt | `auto`(kvm/qemu) | `nova_compute_virt_type` |
| flavor | `ha.m1.control/build/gitlab/harbor`, `g1.large` | `post-deploy.sh` |
| image | `ubuntu-22.04` | `post-deploy.sh` (Jammy cloud image) |
| GPU PCI | vendor `10de`, alias `nvidia-gpu`, `type-PF`, numa `preferred` | `config/nova.conf` |

네트워크/서브넷/보안그룹/VM은 **여전히 `private/openstack/` Terraform 모듈이 생성**한다.
Kolla는 그 아래의 OpenStack 컨트롤/컴퓨트 플레인만 제공한다.

## 배포 순서

```bash
# 0) "우리 서버"(Linux)에서, 이 디렉터리 기준
cd private/openstack-kolla

# 1) kolla_internal_vip_address 만 채우면 됨 (관리망 미사용 IP).
#    network_interface / neutron_external_interface / GPU product_id 는
#    deploy-kolla.sh 가 autodetect.sh 로 배포 시 자동 채움(런타임 NIC/GPU 탐지).
$EDITOR globals.yml

# 2) 배포 (autodetect + venv + bootstrap-servers + prechecks + deploy + post-deploy)
./deploy-kolla.sh

# 3) 산출물: /etc/kolla/admin-openrc.sh (Keystone 자격증명)
#    flavor/image/외부망 시드
./post-deploy.sh

# 4) 기존 Terraform/HA 연동: .env.secret 의 OS_AUTH_URL 을 Kolla Keystone 으로,
#    HA_PROVIDER=openstack 로 지정 후
cd ../openstack && terraform plan
```

## `private-cloud-apply.sh` 통합 지점 (치환 시)

- `devstack` 페이즈(컨테이너 생성/캐시/`clone_and_configure_devstack`/`run_devstack`)를
  `deploy-kolla.sh` 호출로 대체.
- `ensure_flavors`/`ensure_images`/`configure_gpu_passthrough` → `post-deploy.sh` + `config/nova.conf`로 이전.
- 이후 `terraform`/`k8s`/`model-build` 등 후속 페이즈는 **변경 없음**(범용 OpenStack API 대상).

## 검증 게이트 (Phase A.4)

1. `source /etc/kolla/admin-openrc.sh && openstack service list && openstack endpoint list`
2. Horizon 접속 (`openstack.intp.me`)
3. `cd ../openstack && terraform plan` → 정상, `terraform apply` → 5-VM 생성
4. K8s 부트스트랩 / model-build 기존과 동일 동작
5. **재부팅 후에도 유지** (DevStack과의 핵심 차이)
