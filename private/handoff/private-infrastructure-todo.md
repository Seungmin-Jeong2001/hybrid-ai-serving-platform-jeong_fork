# Private Infrastructure TODO

현재 구현은 local/LXD 기반 검증 가능한 Private Cloud Foundation MVP입니다.
DevStack 기반 로컬 OpenStack control plane과 Terraform smoke provisioning까지 검증합니다.
아래 항목을 끝내야 `Private Cloud Infrastructure Engineer` 역할을 production 수준으로 말할 수 있습니다.

## 1. Production OpenStack 프로비저닝

- 운영용 OpenStack 배포 방식 선택: Kolla-Ansible, Sunbeam, OpenStack-Ansible 등
- 운영 Keystone endpoint, project, user credential로 `ha up openstack --auto-approve` 실행
- Terraform state를 원격 backend로 이전
- network, subnet, router, security group, key pair, VM 생성 결과 검증
- Terraform output 기반 node inventory handoff 파일 정리

## 2. Multi-node Kubernetes Bootstrap

- OpenStack VM 위에 control-plane/worker 역할 분리
- control-plane 3대 이상 HA 구성
- build-worker, gpu-worker node label/taint 기준 확정
- kubeconfig를 안전한 위치에 보관하고 `PRIVATE_KUBECONFIG_B64` 전달 방식 확정

현재 자동화된 범위:

- Terraform output 기반 k3s bootstrap script
- floating IP 또는 SSH proxy 기반 node 접속
- `.ha/openstack/kubeconfig`와 handoff env 생성

남은 범위:

- Ubuntu cloud image를 사용하는 multi-node 실환경 bootstrap 검증
- control-plane 3대 이상의 quorum/장애복구 검증
- production storage, ingress, monitoring, backup까지 포함한 `ha prod check` 통과

## 3. Storage

- NFS, Cinder/Ceph, 또는 외부 CSI 중 production 기본 storage 선택
- `local-path` default StorageClass 제거
- model artifact, build cache PVC가 실제 backing storage에 bound 되는지 검증
- backup/restore 절차와 snapshot 보존 정책 정리

## 4. GPU Worker

- GPU flavor/quota 확인
- NVIDIA driver, container runtime, device plugin 설치
- GPU node label/taint 적용
- `nvidia-smi-validation` Job 성공 결과 보관

## 5. 운영 기본 구성

- IngressClass와 ingress controller 구성
- cert-manager와 인증서 발급 방식 구성
- Prometheus/Grafana/Loki/Alertmanager 등 monitoring/logging baseline 구성
- `ha prod check` 실패 항목을 기준으로 production readiness 통과 범위 확대

## 6. 역할 간 인계

- Model Packaging 담당자에게 namespace, storage class, build service account, registry 접근 기준 전달
- Hybrid Delivery 담당자에게 runner 배치 namespace, ECR push credential 처리 방식, kubeconfig 전달 방식 전달
- Public Cloud 담당자에게 ECR image promotion, ArgoCD manifest 변경 규칙 전달
