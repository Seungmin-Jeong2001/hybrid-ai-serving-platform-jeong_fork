# Foundation 체크리스트

Private Cloud Foundation 첫 프로비저닝 실행 전에 확인할 항목입니다.

## Plan 전 확인

- OpenStack 인증용 GitHub Secrets를 등록합니다.
- OpenStack image/flavor 이름을 GitHub Variables에 등록합니다.
- `PRIVATE_CLOUD_SSH_PUBLIC_KEY`에는 public key만 넣습니다.
- `TF_BACKEND_CONFIG`는 Terraform 원격 state backend를 바라보게 설정합니다.
- 기본 CIDR, node count, router 설정을 바꿔야 하면 `PRIVATE_CLOUD_TFVARS`를 준비합니다.

## Terraform

- `Private Cloud Foundation` workflow를 `terraform_action=plan`으로 실행합니다.
- network, subnet, security group, key pair, VM resource 계획을 확인합니다.
- 문제가 없으면 `terraform_action=apply`로 다시 실행합니다.
- Terraform output은 repository가 아닌 별도 보안 위치에 저장합니다.
- Actions에서 `PRIVATE_CLOUD_SSH_PRIVATE_KEY`가 등록되어 있으면 VM cloud-init 완료와
  `/usr/local/sbin/hybrid-ai-dependency-check`까지 자동 검증합니다.

## Kubernetes Bootstrap

- 생성된 control-plane, worker node에 Kubernetes를 bootstrap합니다.
- build-worker node는 `model-build` 작업 기준에 맞게 등록합니다.
- GPU-worker node는 NVIDIA runtime 지원 상태로 등록합니다.
- GPU-worker VM은 cloud-init에서 host dependency, NVIDIA Container Toolkit, PCIe performance policy를 준비합니다.
- `PRIVATE_KUBECONFIG_B64`를 GitHub Secrets에 등록합니다.

## Cluster 기본 리소스

- `apply_kubernetes=true`로 namespace, quota, RBAC, network policy를 적용합니다.
- Storage는 NFS 예시 값을 실제 값으로 치환한 뒤 적용합니다.
- GPU는 node label/taint와 device plugin 설치가 끝난 뒤 적용합니다.
- `nvidia-smi-validation` Job 결과는 repository 밖에 기록합니다.
