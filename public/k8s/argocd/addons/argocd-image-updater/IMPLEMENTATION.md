# Argo CD Image Updater Implementation

## 1. 변경 목적

이번 변경의 목적은 Argo CD Image Updater를 현재 레포의 provisioning/GitOps 경로에 편입시키고, Git write-back 인증을 GitHub App + SSM Parameter Store SecureString 방식으로 연결하는 것입니다.

배경은 다음과 같습니다.

1. `pdm-serving`의 수동 GitOps 배포는 이미 검증되었습니다.
2. `public/k8s/serving/predictive-model/kustomization.yaml`의 `images[].newTag`를 바꾸면 Argo CD가 이를 감지하고 `pdm-predictor`를 정상 롤링 업데이트합니다.
3. 따라서 자동화에 필요한 핵심은:
   - Image Updater controller 설치
   - private ECR 조회 권한
   - GitHub App 기반 Git write-back 자격증명 경로

이번 구현은 KServe ingress/gateway 이슈를 해결하는 작업이 아닙니다. `InferenceService Ready=False`는 여전히 별도 범위입니다.

## 2. 변경된 파일과 역할

### `public/k8s/argocd/apps/argocd-image-updater-app.yaml`

- Argo CD `Application`
- `platform-addons`가 읽는 `public/k8s/argocd/apps` 아래에 등록
- source path:
  - `public/k8s/argocd/addons/argocd-image-updater`
- destination namespace:
  - `argocd`
- sync-wave:
  - `1`

### `public/k8s/argocd/apps/kustomization.yaml`

- 새 `argocd-image-updater-app.yaml` 등록
- 기존 app-of-apps 구조 유지

### `public/k8s/argocd/apps/pdm-serving-app.yaml`

- `write-back-method`를 GitHub App secret 참조 형태로 변경
- 변경값:
  - `git:secret:argocd/argocd-image-updater-github-app-creds`

### `public/k8s/argocd/addons/argocd-image-updater/install-v1.2.1.yaml`

- upstream `argocd-image-updater` 공식 `v1.2.1` install manifest vendoring
- runtime 시 외부 raw URL 의존 제거

### `public/k8s/argocd/addons/argocd-image-updater/kustomization.yaml`

- vendored install manifest를 resource로 포함
- IRSA annotation patch와 최소 config patch를 적용

### `public/k8s/argocd/addons/argocd-image-updater/serviceaccount-irsa-patch.yaml`

- `argocd-image-updater-controller` ServiceAccount에:
  - `eks.amazonaws.com/role-arn`
  annotation 부여

### `public/k8s/argocd/addons/argocd-image-updater/configmap-patch.yaml`

- controller 기본 namespace
- poll interval
- log level/format
- git commit metadata
를 최소 설정으로 추가

### `public/terraform/argocd_image_updater_irsa.tf`

- Image Updater controller용 IAM Role 추가
- trust policy:
  - `system:serviceaccount:argocd:argocd-image-updater-controller`
- ECR 최소 권한:
  - `ecr:GetAuthorizationToken`
  - `ecr:DescribeImages`
  - `ecr:DescribeRepositories`
  - `ecr:ListImages`
  - `ecr:BatchGetImage`

### `public/terraform/eks_bootstrap_admin.tf`

- `eks-bootstrap-admin` role에 GitHub App parameter 읽기 권한 추가
- 허용 권한:
  - `ssm:GetParameter`
  - `ssm:GetParameters`
- 대상:
  - `arn:aws:ssm:ap-northeast-2:808379768010:parameter/hasp/argocd/image-updater/github-app/*`

### `public/terraform/outputs.tf`

- `argocd_image_updater_role_arn` output 유지

### `.github/workflows/setup-argocd.yml`

- `workflow_dispatch` input `rotate_github_app_secret` 추가
- GitHub Secrets의 GitHub App 값을 SSM Parameter Store SecureString에 저장
- SSM Run Command payload에는 parameter 이름만 전달
- 대상 인스턴스가 parameter를 조회해 Kubernetes Secret을 생성

## 3. 설치 구조

전체 구조는 아래와 같습니다.

```text
GitHub Actions setup-argocd.yml
  -> EKS access + kubectl bootstrap
  -> GitHub App values -> SSM Parameter Store SecureString
  -> Argo CD repo credential Secret 생성
  -> platform-addons Application apply
    -> argocd-image-updater Application sync
      -> argocd-image-updater-controller 설치
      -> IRSA를 통해 ECR 조회
      -> GitHub App secret 기반 write-back 수행
```

## 4. `pdm-serving`과의 연결 방식

`pdm-serving`은 기존 annotation 구조를 유지하면서 write-back credential 참조만 GitHub App secret 방식으로 변경합니다.

확인한 핵심 annotation:

- `argocd-image-updater.argoproj.io/image-list`
- `argocd-image-updater.argoproj.io/predictive-model.update-strategy`
- `argocd-image-updater.argoproj.io/predictive-model.allow-tags`
- `argocd-image-updater.argoproj.io/predictive-model.force-update`
- `argocd-image-updater.argoproj.io/predictive-model.kustomize.image-name`
- `argocd-image-updater.argoproj.io/write-back-method: git:secret:argocd/argocd-image-updater-github-app-creds`
- `argocd-image-updater.argoproj.io/write-back-target: kustomization`
- `argocd-image-updater.argoproj.io/git-branch: main`

이번 구현에서는 별도 `ImageUpdater` CR을 추가하지 않습니다.

## 5. 실제 배포 기준 파일

중요한 점은 `pdm-isvc.yaml`의 literal image tag가 최종 기준이 아니라는 점입니다.

실제 기준:

- `public/k8s/serving/predictive-model/kustomization.yaml`

즉 Image Updater가 성공적으로 동작하면:

1. `kustomization.yaml`의 `images[].newTag` 변경
2. Argo CD sync
3. `pdm-predictor` 교체

이 흐름으로 반영됩니다.

## 6. ECR 인증 방식

운영 기본값은 IRSA입니다.

이유:

1. private ECR tag 조회는 장기적으로 static docker-registry secret보다 IRSA가 안전합니다.
2. ECR login password는 만료됩니다.
3. 현재 레포는 이미 Terraform 기반 IRSA 패턴을 사용 중입니다.

이번 구현에서 controller는 `argocd-image-updater-controller` ServiceAccount에 연결된 IAM Role을 통해 `predictive-model` repository의 tag를 조회합니다.

## 7. Git write-back 인증 방식

Git write-back은 GitHub App + SSM Parameter Store SecureString 방식을 사용합니다.

GitHub App 정보를 저장하는 parameter 이름은 다음과 같습니다.

- `/hasp/argocd/image-updater/github-app/id`
- `/hasp/argocd/image-updater/github-app/installation-id`
- `/hasp/argocd/image-updater/github-app/private-key`

모두 `SecureString`입니다.

기본 동작은 다음과 같습니다.

1. parameter가 없으면 생성
2. parameter가 있으면 기존 값 유지
3. `rotate_github_app_secret=true`일 때만 overwrite

SSM 대상 인스턴스는 위 parameter를 조회해 아래 Kubernetes Secret을 생성합니다.

- namespace: `argocd`
- secret name: `argocd-image-updater-github-app-creds`

Secret keys:

- `githubAppID`
- `githubAppInstallationID`
- `githubAppPrivateKey`

## 8. setup-argocd.yml 변경 상세

workflow에는 다음 변경이 들어갑니다.

1. `workflow_dispatch` input:
   - `rotate_github_app_secret`
2. GitHub Secrets:
   - `GH_APP_ID`
   - `GH_APP_INSTALLATION_ID`
   - `GH_APP_PRIVATE_KEY`
3. GitHub Actions가 AWS API로 SSM Parameter Store SecureString 생성/갱신
4. SSM Run Command payload에는 parameter 이름만 포함
5. 대상 인스턴스는 parameter를 조회해서 Kubernetes Secret 생성

SSM 대상 인스턴스 내부 조회 흐름:

```bash
GITHUB_APP_ID="$(aws ssm get-parameter \
  --name "/hasp/argocd/image-updater/github-app/id" \
  --with-decryption \
  --query Parameter.Value \
  --output text)"

GITHUB_APP_INSTALLATION_ID="$(aws ssm get-parameter \
  --name "/hasp/argocd/image-updater/github-app/installation-id" \
  --with-decryption \
  --query Parameter.Value \
  --output text)"

GITHUB_APP_PRIVATE_KEY="$(aws ssm get-parameter \
  --name "/hasp/argocd/image-updater/github-app/private-key" \
  --with-decryption \
  --query Parameter.Value \
  --output text)"
```

그 다음 Kubernetes Secret을 idempotent하게 생성/갱신합니다.

```bash
kubectl -n argocd create secret generic argocd-image-updater-github-app-creds \
  --from-literal=githubAppID="${GITHUB_APP_ID}" \
  --from-literal=githubAppInstallationID="${GITHUB_APP_INSTALLATION_ID}" \
  --from-literal=githubAppPrivateKey="${GITHUB_APP_PRIVATE_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -
```

그리고 사용 후 변수는 unset 합니다.

```bash
unset GITHUB_APP_ID GITHUB_APP_INSTALLATION_ID GITHUB_APP_PRIVATE_KEY
```

이 구조의 중요한 보안 포인트는:

- private key가 `commands.json`에 들어가지 않음
- private key가 SSM Run Command payload에 들어가지 않음
- private key가 Terraform state에 들어가지 않음

## 9. ECR IAM User fallback에 대한 판단

GitHub Secrets에는 아래 값도 존재합니다.

- `AWS_ECR_IAM_ID`
- `AWS_ECR_IAM_PASS`

이 값들은 ECR docker-registry secret fallback을 만드는 데 사용할 수는 있습니다.

하지만 이번 구현에서는 workflow에 기본 반영하지 않았고, 운영 자동화 경로에도 포함하지 않았습니다.

이유:

1. 운영 기본값이 IRSA이기 때문
2. ECR login password는 만료되기 때문
3. fallback secret까지 bootstrap에 넣으면 운영 경로가 이중화되어 오히려 진단이 복잡해질 수 있기 때문

## 10. 보안 주의

이번 변경에서 커밋하지 않은 항목:

- `GH_APP_ID` 실제 값
- `GH_APP_INSTALLATION_ID` 실제 값
- `GH_APP_PRIVATE_KEY` 실제 값
- `AWS_ECR_IAM_ID` 실제 값
- `AWS_ECR_IAM_PASS` 실제 값
- ECR login password
- 어떤 private key 또는 access token의 실값

레포에는 IAM 정책, patch, workflow 구조, parameter 이름, Secret 이름만 들어갑니다.

## 11. 향후 검증 절차

```bash
kubectl -n argocd get application argocd-image-updater
kubectl -n argocd get deploy,pod | grep -i image
kubectl -n argocd get sa argocd-image-updater-controller -o yaml | grep -A5 eks.amazonaws.com/role-arn
kubectl -n argocd get secret argocd-image-updater-github-app-creds
kubectl -n argocd logs deploy/argocd-image-updater-controller --tail=300
kubectl -n argocd logs deploy/argocd-image-updater-controller --tail=500 | egrep -i "pdm-serving|predictive-model|ecr|error|warn|git|commit|push|tag|updated|credentials|auth"
kubectl -n inference get deploy pdm-predictor -o wide
kubectl -n inference get pods -o jsonpath='{range .items[*]}{.metadata.name}{" => "}{.spec.containers[*].image}{"\n"}{end}' | grep pdm-predictor
kubectl -n inference get isvc pdm
```

## 12. 남은 TODO

1. GitHub Actions가 사용하는 AWS role에 `ssm:PutParameter`와 `ssm:GetParameter` 권한이 실제로 부여되어 있는지 확인
2. Terraform apply 후 IRSA role ARN과 ServiceAccount annotation 일치 여부 확인
3. Image Updater 로그에서 ECR auth / GitHub App write-back 성공 여부 확인
4. customer-managed KMS key 도입이 필요한지 검토
