# Private Cloud Foundation 인계 문서

이 디렉터리는 Private Cloud Foundation 프로비저닝 이후 다른 역할에 넘겨야 하는 값을
정리하는 공간입니다.

실제 내부 IP, kubeconfig 본문, access key, password, token, private endpoint는 이
repository에 기록하지 않습니다.

## 인계 대상

| 항목 | 출처 | 전달 대상 |
| --- | --- | --- |
| Private network ID | Terraform output `private_network_id` | Kubernetes bootstrap, hybrid routing |
| Private subnet ID | Terraform output `private_subnet_id` | Kubernetes bootstrap, storage |
| Security group ID | Terraform output `security_group_id` | Kubernetes bootstrap, 운영 담당 |
| Control-plane node inventory | Terraform output `control_plane_nodes` | Kubernetes bootstrap |
| Build-worker node inventory | Terraform output `build_worker_nodes` | Model packaging, worker runtime |
| GPU-worker node inventory | Terraform output `gpu_worker_nodes` | Model serving, GPU 검증 |
| Namespace 기준 | `kubernetes/` manifest | Model, worker, monitoring |
| Storage 기준 | `storage/` manifest | Model build, artifact 관리 |
| GPU 검증 기준 | `gpu-worker/` manifest | Model serving, reliability |

## 담당 범위

Private Cloud Foundation에서 담당하는 것:

- OpenStack network, subnet, router attachment, security group, key pair, VM group
- Kubernetes namespace, quota, RBAC, network policy 기준
- private build cache와 model artifact용 StorageClass/PVC 예시
- GPU RuntimeClass와 `nvidia-smi` 검증 Job 골격

Private Cloud Foundation에서 담당하지 않는 것:

- application source code
- model image build pipeline
- public cloud ingress와 ALB 구성
- Kafka topic contract
- monitoring dashboard와 alert rule

## 전달 방식

프로비저닝 완료 후 아래 값은 별도 보안 채널로 전달합니다.

- Cluster API endpoint
- 자동화에 사용할 read-only 또는 scoped kubeconfig
- private IP를 포함한 node role inventory
- StorageClass 이름: `private-nfs-rwx`
- model build PVC 이름: `model-build-cache`
- model artifact PVC 이름: `model-artifacts`
- GPU RuntimeClass 이름: `nvidia`
- GPU 검증 Job 이름: `nvidia-smi-validation`
