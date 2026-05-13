# Hybrid AI Serving Platform

하이브리드 AI 서빙 플랫폼 프로젝트의 Repository 구조와 작업 기준을 정리한 가이드라인입니다.

## Repository Structure

```txt
hybrid-ai-serving-platform/
├─ README.md
├─ .github/
│  └─ workflows/           # GitHub Actions CI/CD
├─ apps/
│  ├─ public/              # Public API / 외부 요청 진입점
│  ├─ hybrid/              # Public-Private 연동 / routing
│  └─ worker/              # 비동기 처리 worker
├─ services/
│  └─ model/               # 모델 serving / packaging
├─ infra/
│  ├─ private-cloud/       # OpenStack, Private K8s, GPU Worker, Storage
│  ├─ public-cloud/        # AWS EKS, ECR, KServe, ALB
│  ├─ kafka/               # Kafka topic, broker, async pipeline
│  └─ monitoring/          # Prometheus, Loki, Grafana, Alert
├─ gitops/
│  └─ kserve/              # ArgoCD가 동기화할 serving manifest
├─ packages/
│  └─ common/              # 공통 schema, config, utility
└─ docs/
   └─ architecture/        # 공개 가능한 구조 설명 문서
```

## Branch Scope

| Branch | Scope |
| --- | --- |
| `feature/private` | Private Cloud Infrastructure |
| `feature/model` | Model Serving / Packaging |
| `feature/hybrid` | GitHub Actions / GitOps Delivery |
| `feature/public` | Public Cloud Serving |
| `feature/kafka` | Event-driven Async Scaling |
| `feature/monitoring` | Reliability / Observability |

## 작성 기준

- 실제 secret, token, access key, kubeconfig, 내부 endpoint는 커밋하지 않습니다.
- 각 역할은 담당 폴더에 README를 먼저 작성한 뒤 구현 파일을 추가합니다.

## 현재 작업 기준

`feature/private` 브랜치에서는 Private Cloud Foundation을 먼저 잡습니다.
목표는 실제 운영값을 노출하지 않으면서, GitHub Actions에서 OpenStack 자원 생성부터
Kubernetes 기본 리소스 적용까지 이어갈 수 있는 프로비저닝 골격을 만드는 것입니다.

| 구분 | 경로 |
| --- | --- |
| GitHub Actions 실행 파일 | `.github/workflows/private-cloud-foundation.yml` |
| OpenStack Terraform | `infra/private-cloud/openstack` |
| Kubernetes 기본 리소스 | `infra/private-cloud/kubernetes` |
| Storage 기본 리소스 | `infra/private-cloud/storage` |
| GPU Worker 검증 리소스 | `infra/private-cloud/gpu-worker` |
| 역할 간 인계 문서 | `infra/private-cloud/handoff` |
