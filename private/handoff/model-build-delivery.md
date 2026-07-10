# GitLab Runner Model Build Delivery Handoff

이 문서는 GitLab에 모델 코드를 올린 뒤 GitLab Runner가 모델 학습, 이미지 패키징, Harbor 저장, ECR 전달을 어떻게 실행해야 하는지 정리합니다. 현재 repository에 구현된 기준을 먼저 적고, 다음 handoff 담당자가 채워야 하는 부분은 별도로 표시합니다.

## 목표 흐름

```text
Developer push
  -> GitLab pipeline
  -> build-worker GitLab Runner
  -> Argo model-build-job
  -> MinIO/NFS model artifact
  -> Argo model-package-job
  -> Kaniko image build
  -> Harbor models/<image>:<tag>
  -> ECR promotion
  -> release manifest 저장
  -> public deploy가 ECR digest를 사용
```

GitLab Runner는 무거운 작업을 직접 하지 않습니다. Runner는 `kubectl`, `argo`, `skopeo` 또는 `crane`, `aws` CLI를 실행하는 orchestration host이고, 실제 GPU 학습과 Kaniko build는 Kubernetes pod에서 수행합니다.

## 현재 자동화가 준비하는 것

| 리소스 | 위치 | 설명 |
| --- | --- | --- |
| GitLab VM | `hybrid-ai-private-gitlab-01` | GitLab CE container, root/custom admin account, instance runner token 생성 |
| GitLab runner token | GitLab VM `/var/lib/hybrid-ai/gitlab-bootstrap/runner-token` | `hybrid-ai-gitlab-bootstrap`가 생성하는 instance runner auth token |
| Harbor VM | `hybrid-ai-private-harbor-01` | Harbor online installer 기반 registry |
| Harbor data | Harbor VM `/data/harbor` | registry image layer, OCI manifest, DB data의 영속 위치 |
| Harbor projects | `infra`, `models` | `infra`는 Kaniko cache, `models`는 predictor image 저장 |
| Harbor robot | system robot `kaniko` | `infra`, `models` project에 pull/push/list 권한 |
| Harbor robot credential | Harbor VM `/var/lib/hybrid-ai/harbor-bootstrap/kaniko-robot.json` | Harbor bootstrap 내부 원본 |
| Harbor robot host copy | host `.ha/openstack/harbor-kaniko-robot.{json,env}` | model-build phase가 Kubernetes secret을 만들 때 사용 |
| Kaniko docker secret | Kubernetes `model-build/harbor-kaniko-push` | Kaniko pod의 `/kaniko/.docker/config.json`으로 mount |
| StorageClass | `private-nfs-rwx` | RWX PVC backing |
| Build workspace PVC | `model-build/model-build-cache`, 200Gi | clone, dataset download, Kaniko context 같은 임시 workspace |
| Artifact PVC | `model-build/model-artifacts`, 500Gi | workflow 중간 artifact staging |
| MinIO tenant | `minio-tenant` namespace | dataset과 artifact object store |
| WorkflowTemplate | `model-build/model-build-job` | GitLab clone, dataset download, GPU train, artifact upload |
| WorkflowTemplate | `model-build/model-package-job` | GitLab clone, artifact download, Kaniko build, Harbor push |

## 아직 handoff에서 채워야 하는 것

현재 full init은 GitLab과 Harbor, Argo baseline을 올리지만 GitLab Runner 등록과 ECR promotion pipeline은 아직 자동화하지 않습니다. 다음 항목을 추가해야 end-to-end delivery가 닫힙니다.

| 항목 | 필요한 이유 |
| --- | --- |
| build-worker에 GitLab Runner 설치/등록 | GitLab pipeline을 실제로 받을 executor가 필요 |
| Runner용 kubeconfig/RBAC | Runner가 Argo Workflow를 생성하고 상태를 watch해야 함 |
| `model-build/minio-client-credentials` secret | WorkflowTemplate이 MinIO dataset/artifact 접근에 사용 |
| Git private repo clone credential | private GitLab repo를 Argo pod가 clone해야 함 |
| ECR push credential 또는 AWS OIDC role | Harbor image를 ECR로 promotion해야 함 |
| release manifest 작성 | 어떤 코드, dataset, artifact, Harbor digest, ECR digest가 연결됐는지 추적 |

## 데이터 저장 기준

데이터는 "source of truth"와 "작업 캐시"를 분리합니다.

| 데이터 | 저장 위치 | 성격 |
| --- | --- | --- |
| raw dataset | MinIO `datasets/<dataset>/<version>/...` | 학습 입력의 source of truth |
| training output | MinIO `artifacts/models/<project>/<ref>/<pipeline-id>/...` | 모델 artifact의 source of truth |
| workflow workspace | PVC `model-build-cache` | Git clone, dataset download, Kaniko context. 재실행 시 지워도 됨 |
| staged model files | PVC `model-artifacts` | workflow 내부 전달용 staging. MinIO 업로드 후 source of truth가 아님 |
| private image | Harbor `models/<image-name>:<tag>` | private cloud에서 검증하고 ECR로 넘길 image |
| Kaniko cache | Harbor `infra/kaniko-cache` | build layer cache. 삭제 가능하지만 build가 느려짐 |
| public image | ECR `<account>.dkr.ecr.<region>.amazonaws.com/<repo>:<tag>` | public/EKS 배포가 가져가는 image |
| release manifest | MinIO `artifacts/manifests/<project>/<image-tag>/release.json` | code, artifact, image digest 연결 정보 |

권장 prefix는 아래처럼 고정합니다.

```text
datasets/<dataset-name>/<dataset-version>/
artifacts/models/<gitlab-project-slug>/<git-ref-slug>/<gitlab-pipeline-id>/
artifacts/manifests/<gitlab-project-slug>/<image-tag>/release.json
```

`model-build-cache`와 `model-artifacts` PVC는 workflow 실행을 빠르게 하기 위한 cluster 내부 저장소입니다. 운영 추적과 재현성은 MinIO object path와 image digest를 기준으로 잡아야 합니다.

## MinIO credential 준비

WorkflowTemplate은 `model-build` namespace의 `minio-client-credentials` secret을 참조합니다. 현재 storage bootstrap은 `minio-tenant/minio-creds-secret`을 만들기 때문에, handoff 단계에서 아래처럼 model-build namespace에 복제해야 합니다.

```bash
MINIO_ACCESS_KEY="$(
  kubectl -n minio-tenant get secret minio-creds-secret \
    -o jsonpath='{.data.accessKey}' | base64 -d
)"
MINIO_SECRET_KEY="$(
  kubectl -n minio-tenant get secret minio-creds-secret \
    -o jsonpath='{.data.secretKey}' | base64 -d
)"

kubectl -n model-build create secret generic minio-client-credentials \
  --from-literal=accessKey="${MINIO_ACCESS_KEY}" \
  --from-literal=secretKey="${MINIO_SECRET_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -
```

장기적으로는 `setup_storage` 또는 `setup_model_build_platform`에서 이 secret 생성을 자동화하는 것이 맞습니다.

## Runner 배치 기준

권장 배치는 build-worker VM의 shell executor입니다.

```text
GitLab VM
  -> pipeline scheduling, runner token

build-worker VM
  -> gitlab-runner shell executor
  -> kubectl/argo/aws/skopeo or crane/mc installed
  -> Kubernetes API, GitLab, Harbor, ECR 접근

Kubernetes model-build namespace
  -> Argo Workflow 생성
  -> GPU training pod와 Kaniko pod 실행
```

Docker-in-Docker runner는 기본 선택이 아닙니다. image build는 Kaniko pod가 수행하고, Runner는 workflow submit과 promotion만 담당합니다.

## Runner 등록 절차

GitLab bootstrap이 만든 runner token을 GitLab VM에서 읽어 build-worker runner 등록에 사용합니다.

```bash
# GitLab VM에서 token 확인
sudo cat /var/lib/hybrid-ai/gitlab-bootstrap/runner-token

# build-worker VM에서 실행
export GITLAB_URL="https://gitlab.intp.me"
export GITLAB_RUNNER_AUTH_TOKEN="<runner-token-from-gitlab-vm>"

sudo gitlab-runner register \
  --non-interactive \
  --url "${GITLAB_URL}" \
  --token "${GITLAB_RUNNER_AUTH_TOKEN}" \
  --executor "shell" \
  --description "hybrid-ai-build-worker-01" \
  --tag-list "model-build,private-cloud" \
  --run-untagged="false" \
  --locked="false"
```

Runner host에는 최소한 아래 도구가 있어야 합니다.

```text
gitlab-runner
kubectl
argo
aws
skopeo 또는 crane
mc
jq
```

Runner는 `model-build` tag가 붙은 job만 받게 둡니다. GPU 작업 자체는 runner host에서 실행하지 않고 Argo workflow pod가 `hybrid-ai.io/node-role: gpu-worker` nodeSelector로 GPU worker에 배치됩니다.

## Runner RBAC

기존 `private/kubernetes/rbac.yaml`의 `model-build-runner`는 pod/job 중심 권한입니다. GitLab Runner가 Argo Workflow를 submit하려면 `argoproj.io` workflow 권한이 추가로 필요합니다.

권장 Role 추가:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: model-build-runner-argo
  namespace: model-build
rules:
  - apiGroups: ["argoproj.io"]
    resources: ["workflows", "workflowtemplates", "workflowtaskresults"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: [""]
    resources: ["pods", "pods/log", "secrets", "configmaps", "persistentvolumeclaims"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: model-build-runner-argo
  namespace: model-build
subjects:
  - kind: ServiceAccount
    name: model-build-runner
    namespace: model-build
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: model-build-runner-argo
```

Runner host에는 이 service account로 만든 kubeconfig를 배치합니다. 초기 PoC에서는 admin kubeconfig로도 검증할 수 있지만, 운영 handoff 기준은 namespace-scoped kubeconfig입니다.

## GitLab repository 기준

모델 repo는 최소 아래 파일을 포함해야 합니다.

```text
.
├── .gitlab-ci.yml
├── model_build.py
├── Dockerfile.predictor
├── predictor/
└── requirements.txt
```

`model_build.py`는 workflow의 기본 command와 맞아야 합니다.

```bash
python model_build.py --data ../data --output ../output
```

`Dockerfile.predictor`는 `model-artifacts/` 디렉터리에 복사된 산출물을 image 안으로 포함해야 합니다.

```dockerfile
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY predictor/ ./predictor/
COPY model-artifacts/ ./model-artifacts/
CMD ["python", "-m", "predictor.serve"]
```

현재 WorkflowTemplate의 `git_ref`는 branch/tag를 `git clone --branch`에 넘깁니다. commit SHA를 정확히 checkout하려면 template에 `git checkout <sha>` 단계를 추가해야 합니다. PoC에서는 protected branch 또는 release tag를 `git_ref`로 넘기는 방식이 단순합니다.

Private GitLab repo를 Argo pod가 clone하려면 읽기 전용 deploy token이 필요합니다. 초기 PoC에서는 `https://<user>:<token>@gitlab.intp.me/group/project.git` 형태를 parameter로 넘길 수 있지만, parameter와 workflow log에 URL이 남을 수 있습니다. 운영 기준은 Git credential secret을 mount하고 URL에는 token을 넣지 않는 방식입니다.

## GitLab CI 예시

아래 pipeline은 runner가 Argo Workflow를 submit하고, Harbor image를 ECR로 복사한 뒤 release manifest를 MinIO에 저장하는 기준입니다.

```yaml
stages:
  - train
  - package
  - promote

variables:
  ARGO_NAMESPACE: model-build
  HARBOR_REGISTRY: harbor.intp.me
  HARBOR_PROJECT: models
  IMAGE_NAME: predictor-image
  AWS_REGION: ap-northeast-2
  DATASET_BUCKET: datasets
  DATASET_PREFIX: raw-data
  ARTIFACT_BUCKET: artifacts
  ARTIFACT_PREFIX: "models/${CI_PROJECT_PATH_SLUG}/${CI_COMMIT_REF_SLUG}/${CI_PIPELINE_ID}"
  IMAGE_TAG: "${CI_COMMIT_SHORT_SHA}"

train:
  stage: train
  tags: [model-build]
  script:
    - >
      argo submit -n "${ARGO_NAMESPACE}" --from workflowtemplate/model-build-job
      --name "train-${CI_PIPELINE_ID}"
      -p git_repo_url="${MODEL_GIT_CLONE_URL}"
      -p git_ref="${CI_COMMIT_REF_NAME}"
      -p dataset_bucket="${DATASET_BUCKET}"
      -p dataset_prefix="${DATASET_PREFIX}"
      -p artifact_bucket="${ARTIFACT_BUCKET}"
      -p artifact_prefix="${ARTIFACT_PREFIX}"
      --wait --log

package:
  stage: package
  tags: [model-build]
  needs: [train]
  script:
    - >
      argo submit -n "${ARGO_NAMESPACE}" --from workflowtemplate/model-package-job
      --name "package-${CI_PIPELINE_ID}"
      -p git_repo_url="${MODEL_GIT_CLONE_URL}"
      -p git_ref="${CI_COMMIT_REF_NAME}"
      -p artifact_bucket="${ARTIFACT_BUCKET}"
      -p artifact_prefix="${ARTIFACT_PREFIX}"
      -p harbor_registry="${HARBOR_REGISTRY}"
      -p harbor_project="${HARBOR_PROJECT}"
      -p image_name="${IMAGE_NAME}"
      -p image_tag="${IMAGE_TAG}"
      -p dockerfile_path="Dockerfile.predictor"
      -p context_subdir="."
      --wait --log

promote:ecr:
  stage: promote
  tags: [model-build]
  needs: [package]
  script:
    - export HARBOR_IMAGE="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${IMAGE_NAME}:${IMAGE_TAG}"
    - export ECR_IMAGE="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPOSITORY}:${IMAGE_TAG}"
    - echo "${HARBOR_ROBOT_TOKEN}" | skopeo login "${HARBOR_REGISTRY}" --username "${HARBOR_ROBOT_USERNAME}" --password-stdin
    - aws ecr get-login-password --region "${AWS_REGION}" | skopeo login "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com" --username AWS --password-stdin
    - skopeo copy --all "docker://${HARBOR_IMAGE}" "docker://${ECR_IMAGE}"
    - export HARBOR_DIGEST="$(skopeo inspect --format '{{.Digest}}' "docker://${HARBOR_IMAGE}")"
    - export ECR_DIGEST="$(skopeo inspect --format '{{.Digest}}' "docker://${ECR_IMAGE}")"
    - mkdir -p release
    - |
      jq -n \
        --arg project "${CI_PROJECT_PATH}" \
        --arg pipeline_id "${CI_PIPELINE_ID}" \
        --arg git_ref "${CI_COMMIT_REF_NAME}" \
        --arg git_sha "${CI_COMMIT_SHA}" \
        --arg dataset_bucket "${DATASET_BUCKET}" \
        --arg dataset_prefix "${DATASET_PREFIX}" \
        --arg artifact_bucket "${ARTIFACT_BUCKET}" \
        --arg artifact_prefix "${ARTIFACT_PREFIX}" \
        --arg harbor_image "${HARBOR_IMAGE}" \
        --arg harbor_digest "${HARBOR_DIGEST}" \
        --arg ecr_image "${ECR_IMAGE}" \
        --arg ecr_digest "${ECR_DIGEST}" \
        '{
          schemaVersion: 1,
          project: $project,
          pipelineId: $pipeline_id,
          git: { ref: $git_ref, sha: $git_sha },
          dataset: { bucket: $dataset_bucket, prefix: $dataset_prefix },
          artifact: { bucket: $artifact_bucket, prefix: $artifact_prefix },
          harbor: { image: $harbor_image, digest: $harbor_digest },
          ecr: { image: $ecr_image, digest: $ecr_digest }
        }' > release/release.json
    - mc alias set minio "${MINIO_ENDPOINT}" "${MINIO_ACCESS_KEY}" "${MINIO_SECRET_KEY}"
    - mc cp release/release.json "minio/${ARTIFACT_BUCKET}/manifests/${CI_PROJECT_PATH_SLUG}/${IMAGE_TAG}/release.json"
  artifacts:
    when: always
    paths:
      - release/release.json
```

GitLab CI variable 기준:

| 변수 | 성격 |
| --- | --- |
| `MODEL_GIT_CLONE_URL` | Argo pod가 clone할 repo URL. private repo면 read-only deploy token 사용 |
| `HARBOR_ROBOT_USERNAME`, `HARBOR_ROBOT_TOKEN` | Harbor pull source credential. masked/protected variable |
| `AWS_ACCOUNT_ID`, `AWS_REGION`, `ECR_REPOSITORY` | ECR 대상 |
| `AWS_ROLE_ARN` 또는 AWS access key | ECR push 권한. 가능하면 OIDC assume-role 사용 |
| `MINIO_ENDPOINT`, `MINIO_ACCESS_KEY`, `MINIO_SECRET_KEY` | release manifest 업로드용 |

Harbor credential은 이미 Kubernetes secret `model-build/harbor-kaniko-push`에도 들어 있습니다. GitLab CI의 `promote:ecr` job은 Harbor에서 image를 pull해야 하므로 Runner 쪽에도 별도의 masked variable 또는 root-only credential file이 필요합니다.

## Workflow 내부 동작

`model-build-job`:

```text
clone-code
  -> /workspace/<workflow>/src

download-dataset
  -> MinIO datasets/<dataset_prefix>
  -> /workspace/<workflow>/data

train
  -> gpu-worker node
  -> /workspace/<workflow>/src 에서 train_command 실행
  -> /workspace/<workflow>/output
  -> /artifacts/<workflow>

upload-artifacts
  -> /artifacts/<workflow>
  -> MinIO artifacts/<artifact_prefix>
```

`model-package-job`:

```text
clone-code
  -> /workspace/<workflow>/src

download-artifacts
  -> MinIO artifacts/<artifact_prefix>
  -> /workspace/<workflow>/artifacts

prepare-context
  -> repo context 복사
  -> artifact를 context/model-artifacts 로 복사

kaniko-build
  -> gcr.io/kaniko-project/executor:v1.23.2
  -> /kaniko/.docker/config.json 에 harbor-kaniko-push secret mount
  -> Harbor models/<image_name>:<image_tag> push
  -> Harbor infra/kaniko-cache 사용
```

Kaniko가 Harbor에 push하면 Harbor는 OCI image manifest와 layer를 `/data/harbor` 아래 registry storage에 보관합니다. 이 registry manifest는 image pull에 필요한 표준 OCI manifest이고, 운영 추적용 release manifest는 별도로 `release.json`으로 남깁니다.

## Harbor에서 ECR로 전달

ECR 전달은 rebuild가 아니라 digest-preserving promotion으로 처리합니다.

```text
Harbor image
  -> skopeo copy --all
  -> ECR image
  -> digest 확인
  -> release manifest 기록
```

`skopeo copy --all` 또는 `crane copy`를 쓰면 image layer와 OCI manifest를 registry 간 복사합니다. 이렇게 하면 Kaniko build 결과와 ECR 배포 image가 같은 content digest 계열로 추적됩니다. ECR repository는 `public/terraform/ecr.tf`가 `var.ecr_repositories` 기준으로 생성하고, URL은 `terraform output -json ecr_repository_urls`에서 확인합니다.

Public EKS 배포는 tag보다 digest를 우선해야 합니다.

```text
image: <account>.dkr.ecr.<region>.amazonaws.com/<repo>@sha256:<digest>
```

Tag는 사람이 보기 위한 release label이고, 실제 rollout 재현성은 digest가 보장합니다.

## 운영 검증 명령

GitLab:

```bash
curl -fsS https://gitlab.intp.me/-/readiness
sudo cat /var/lib/hybrid-ai/gitlab-bootstrap/status.env
sudo test -s /var/lib/hybrid-ai/gitlab-bootstrap/runner-token
```

Harbor:

```bash
curl -fsS https://harbor.intp.me/api/v2.0/ping
sudo cat /var/lib/hybrid-ai/harbor-bootstrap/status.env
sudo test -s /var/lib/hybrid-ai/harbor-bootstrap/kaniko-robot.json
```

Kubernetes:

```bash
kubectl get ns model-build argo minio-tenant
kubectl -n model-build get pvc model-build-cache model-artifacts
kubectl -n model-build get secret harbor-kaniko-push minio-client-credentials
kubectl -n model-build get workflowtemplate model-build-job model-package-job
kubectl -n argo get deploy workflow-controller
```

Runner:

```bash
sudo gitlab-runner verify
sudo gitlab-runner list
kubectl auth can-i create workflows.argoproj.io -n model-build
kubectl auth can-i get workflowtemplates.argoproj.io -n model-build
```

Image promotion:

```bash
skopeo inspect "docker://harbor.intp.me/models/predictor-image:<tag>" | jq '.Digest'
skopeo inspect "docker://<account>.dkr.ecr.<region>.amazonaws.com/<repo>:<tag>" | jq '.Digest'
mc cat "minio/artifacts/manifests/<project>/<tag>/release.json" | jq .
```

## 장애 지점과 판단 기준

| 증상 | 확인할 곳 | 판단 |
| --- | --- | --- |
| Pipeline이 pending | GitLab UI runner 상태, `gitlab-runner verify` | Runner 미등록, tag mismatch, runner offline |
| Argo submit 실패 | Runner kubeconfig, RBAC | `model-build-runner`에 workflow create/watch 권한 필요 |
| Dataset download 실패 | `model-build/minio-client-credentials`, MinIO bucket/prefix | secret 누락 또는 prefix 오타 |
| Train pod pending | GPU node label/taint, quota | `hybrid-ai.io/node-role=gpu-worker`, GPU resource 확인 |
| Kaniko push 실패 | `harbor-kaniko-push` secret, Harbor robot 권한 | robot credential, Harbor project 확인 |
| ECR copy 실패 | AWS credential, ECR repo, network egress | ECR login, repo 존재, Bastion VPN route, Route53 Resolver DNS 확인 |
| Release manifest 누락 | `promote:ecr` job log, MinIO path | image copy 이후 manifest upload 단계 실패 |

## 다음 구현 권장 순서

1. build-worker GitLab Runner 설치와 등록을 `private-cloud-apply.sh` phase로 자동화.
2. model repo `.gitlab-ci.yml`에서 runtime internet download를 Bastion cache 또는 Harbor mirror image로 대체.
3. ECR promotion credential 방식을 확정. 운영 기준은 AWS OIDC assume-role.
4. release manifest를 MinIO와 GitLab artifact에 모두 남기고, public deploy는 ECR digest만 읽게 변경.
