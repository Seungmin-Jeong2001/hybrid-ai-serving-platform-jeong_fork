# Argo CD Image Updater Implementation

## 1. 변경 목적

이번 변경의 목적은 Argo CD Image Updater가 private ECR tag를 실제로 조회할 수 있도록 GitOps manifest를 보강하는 것입니다.

배경은 다음과 같습니다.

1. `argocd-image-updater-controller` 설치는 이미 완료되었습니다.
2. GitHub App secret과 IRSA도 정상입니다.
3. 하지만 ECR 조회 시 `no basic auth credentials` 오류가 발생했습니다.
4. 원인은 `registries.conf`와 `ecr-login.sh`를 ConfigMap에 넣더라도, Deployment의 `image-updater-conf` volume items에 `ecr-login.sh`가 없으면 Pod 안에 파일이 mount되지 않기 때문입니다.

이번 구현은 다음을 추가합니다.

1. `ImageUpdater` CR
2. `registries.conf`
3. `ecr-login.sh`
4. Deployment volume patch

기존 GitHub App write-back 구조와 IRSA 구조는 유지합니다.

## 2. 변경된 파일과 역할

### `public/k8s/argocd/addons/argocd-image-updater/kustomization.yaml`

- addon 리소스 목록에 `pdm-serving-image-updater.yaml` 추가
- Deployment patch `deployment-ecr-auth-patch.yaml` 추가

### `public/k8s/argocd/addons/argocd-image-updater/pdm-serving-image-updater.yaml`

- `ImageUpdater` CR 추가
- `spec.applicationRefs[]` 아래에 `images`, `commonUpdateSettings`, `manifestTargets`, `writeBackConfig` 정의
- `pdm-serving` Application을 대상으로 `predictive-model` 이미지를 관리

### `public/k8s/argocd/addons/argocd-image-updater/configmap-patch.yaml`

- controller 기본 namespace
- poll interval
- log level/format
- git commit metadata
- `registries.conf`
- `ecr-login.sh`

를 함께 정의

### `public/k8s/argocd/addons/argocd-image-updater/deployment-ecr-auth-patch.yaml`

- `argocd-image-updater-controller` Deployment의 `image-updater-conf` volume items를 patch
- 기존:
  - `registries.conf`
  - `git.commit-message-template`
- 추가:
  - `ecr-login.sh`
  - `mode: 0555`

### `public/k8s/argocd/addons/argocd-image-updater/README.md`

- 현재 구조가 `ImageUpdater` CR 기반임을 반영
- ECR 인증이 IRSA + external credential script임을 설명
- `HOME=/tmp` 이유 설명

### `public/k8s/argocd/addons/argocd-image-updater/IMPLEMENTATION.md`

- 이번 변경 내용을 구현 문서로 정리

## 3. ImageUpdater CR 구조

현재 클러스터의 `v1.2.1` CRD 스키마에 맞춰, `images`와 `manifestTargets`는 top-level이 아니라 `spec.applicationRefs[]` 아래에 둡니다.

적용된 핵심 구조는 다음과 같습니다.

```yaml
apiVersion: argocd-image-updater.argoproj.io/v1alpha1
kind: ImageUpdater
metadata:
  name: pdm-serving-image-updater
  namespace: argocd
spec:
  applicationRefs:
    - namePattern: pdm-serving
      useAnnotations: false
      images:
        - alias: predictive-model
          imageName: 808379768010.dkr.ecr.ap-northeast-2.amazonaws.com/predictive-model
          commonUpdateSettings:
            updateStrategy: newest-build
            allowTags: regexp:^v[0-9]+\.[0-9]+\.[0-9]+$
            forceUpdate: true
          manifestTargets:
            kustomize:
              name: 808379768010.dkr.ecr.ap-northeast-2.amazonaws.com/predictive-model
      writeBackConfig:
        method: git:secret:argocd/argocd-image-updater-github-app-creds
        gitConfig:
          branch: main
          writeBackTarget: kustomization
```

중요한 점:

1. 현재 흐름은 `ImageUpdater` CR을 사용합니다.
2. Application annotation만으로는 이 구성에서 ECR registry 설정과 write-back 구성이 완결되지 않습니다.
3. `useAnnotations: false` 이므로 관리 기준은 CR입니다.

## 4. ECR registry auth 설정

`configmap-patch.yaml`에 아래 두 항목을 추가합니다.

### `registries.conf`

```yaml
registries.conf: |
  registries:
    - name: AWS ECR
      api_url: https://808379768010.dkr.ecr.ap-northeast-2.amazonaws.com
      prefix: 808379768010.dkr.ecr.ap-northeast-2.amazonaws.com
      credentials: ext:/app/config/ecr-login.sh
      credsexpire: 12h
```

핵심:

- static basic auth secret이 아니라 `ext:/app/config/ecr-login.sh` 사용

### `ecr-login.sh`

```sh
#!/bin/sh
set -eu
export HOME=/tmp
echo "AWS:$(aws ecr get-login-password --region ap-northeast-2)"
```

핵심:

1. AWS access key 또는 secret key를 넣지 않음
2. IRSA로 `aws ecr get-login-password` 실행
3. `readOnlyRootFilesystem: true` 환경에서 AWS CLI가 실패하지 않도록 `HOME=/tmp` 설정

## 5. Deployment mount patch

`install-v1.2.1.yaml`의 base Deployment는 `image-updater-conf` volume에서 ConfigMap items를 명시적으로 나열합니다.

기존 항목:

- `registries.conf`
- `git.commit-message-template`

이번 patch는 여기에 아래 항목을 추가합니다.

```yaml
- key: ecr-login.sh
  path: ecr-login.sh
  mode: 0555
```

이렇게 해야 Pod 내부에 실제로:

- `/app/config/registries.conf`
- `/app/config/ecr-login.sh`

가 함께 mount됩니다.

## 6. GitHub App write-back 유지

기존 GitHub App write-back 구조는 유지합니다.

사용하는 Kubernetes Secret:

- namespace: `argocd`
- secret name: `argocd-image-updater-github-app-creds`

사용하는 방식:

- `git:secret:argocd/argocd-image-updater-github-app-creds`

즉 이번 변경은 ECR 조회 인증만 보강하고, Git write-back 자격증명 경로는 건드리지 않습니다.

## 7. IRSA 유지

기존 IRSA 구조도 유지합니다.

ServiceAccount:

- `argocd-image-updater-controller`

IRSA trust subject:

- `system:serviceaccount:argocd:argocd-image-updater-controller`

ECR 권한:

- `ecr:GetAuthorizationToken`
- `ecr:DescribeImages`
- `ecr:DescribeRepositories`
- `ecr:ListImages`
- `ecr:BatchGetImage`

## 8. 보안 주의

이번 변경에서 Git에 커밋하지 않는 항목:

- AWS access key
- AWS secret access key
- ECR login password
- GitHub App private key
- Kubernetes Secret 실값

Git에는 다음만 들어갑니다.

- registry URL
- script path
- Secret name
- IRSA role ARN
- non-secret ConfigMap data

## 9. 정적 검증

다음 명령으로 렌더링 확인을 수행합니다.

```bash
kubectl kustomize public/k8s/argocd/addons/argocd-image-updater
```

렌더링 결과에서 확인해야 할 핵심:

1. `kind: ImageUpdater`
2. `name: pdm-serving-image-updater`
3. `registries.conf`
4. `ecr-login.sh`
5. `mode: 0555`

## 10. 실제 반영 후 확인 명령어

```bash
kubectl -n argocd get imageupdater pdm-serving-image-updater -o yaml
kubectl -n argocd get configmap argocd-image-updater-config -o yaml
kubectl -n argocd get deploy argocd-image-updater-controller -o yaml | grep -A20 ecr-login.sh
kubectl -n argocd exec deploy/argocd-image-updater-controller -- ls -l /app/config
kubectl -n argocd exec deploy/argocd-image-updater-controller -- sh -c 'HOME=/tmp /app/config/ecr-login.sh | cut -c1-20'
kubectl -n argocd logs deploy/argocd-image-updater-controller --tail=500 | egrep -i "pdm-serving|predictive-model|ecr|error|warn|auth|updated|tag"
```
