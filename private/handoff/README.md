# Private Cloud Handoff

이 디렉터리는 Private Cloud Foundation에서 다음 담당자에게 넘길 운영 기준을 정리합니다.

## 문서

| 항목 | 전달 대상 |
| --- | --- |
| `github-actions-env.md` | GitHub Actions controller, reusable executor, 변수와 secret 기준 |
| `private-network-access.md` | FIP 제거 후 내부망, DNS, VM/K8s 통신 기준 |
| `model-build-delivery.md` | GitLab Runner, Argo model build/package, Harbor, ECR 전달 흐름 |

## 현재 인프라 기준

| 영역 | 기준 |
| --- | --- |
| OpenStack | `control-plane`, `build-worker`, `gpu-worker`, `gitlab`, `harbor` VM 1대씩 |
| Kubernetes | `private-infra`, `private-storage`, `model-build`, `gpu-workload`, `argo` namespace |
| Storage | NFS RWX StorageClass `private-nfs-rwx`, MinIO tenant, `model-build-cache`, `model-artifacts` PVC |
| GitLab | 코드 저장소와 CI/CD 제어면. Runner token은 GitLab VM bootstrap이 생성 |
| Harbor | private registry. `infra`, `models` project와 Kaniko robot account를 bootstrap |
| Argo Workflows | `model-build-job`, `model-package-job` WorkflowTemplate 기준 |
| Public cloud | ECR repository는 `public/terraform`의 `ecr_repositories` 기준으로 생성 |

## Codex 작업 규칙

Codex가 이 private cloud 작업을 이어서 할 때는 커밋 메시지를 `git.intp.me` 가이드라인에 맞춰 작성해야 합니다.

```text
Type: English title

- 한국어 본문 항목
- 한국어 본문 항목
```

- Type은 `Feat`, `Fix`, `Refactor`, `Perf`, `Docs`, `Style`, `Test`, `Build`, `CI`, `Chore`, `Revert`, `Rename`, `Remove`, `Security` 중 하나를 사용합니다.
- 제목은 영어로 작성하고 첫 단어를 대문자로 시작하며, 마침표 없이 25~30자 내외로 작성합니다.
- 본문은 한국어 `- ` bullet로 작성하고, 무엇을 왜 바꿨는지 설명합니다.
- 본문 항목은 `추가`, `수정`, `제거`, `제한`, `적용` 같은 명사형으로 끝내고, `~함`, `~됨`, `~했습니다` 같은 서술형 종결을 사용하지 않습니다.
- 규칙을 확인할 수 없으면 포맷을 추측해서 커밋하지 말고 사용자에게 확인받은 뒤 커밋합니다.

## 관리자 진입점

관리자 UI는 reverse proxy/DNS를 통해 노출합니다. 주소와 credential은 공개 handoff 문서에 직접 쓰지 않습니다.

| 대상 | 역할 |
| --- | --- |
| OpenStack Horizon | VM, network, image, flavor 관리 |
| GitLab | 코드 저장소, pipeline, runner 관리 |
| Harbor | private image registry, robot account, image retention 관리 |
| Argo Workflows | model build/package workflow 조회와 재실행 |
| Grafana | monitoring UI |
| Kubernetes UI | cluster 상태 확인 |
