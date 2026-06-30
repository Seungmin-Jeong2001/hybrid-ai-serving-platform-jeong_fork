# VPN Provisioning Chain — 등록값 핸드오프

public → bastion(VPN) → private 재apply 자동 체인을 라이브로 돌리기 위한 GitHub 설정.
확정값은 이미 등록했고, **여기 남은 항목만 직접 채우면** 된다.

## 이미 등록한 variables (참고)

| repo | variable | value |
| --- | --- | --- |
| hybrid-ai-serving-platform | `BASTION_REPO` | `SGS-Strategy/bastion-host` |
| hybrid-ai-serving-platform | `BASTION_PROVISION_REF` | `feat/bastion-provision-actions` |
| bastion-host | `HYBRID_REPO_SLUG` | `SGS-Strategy/hybrid-ai-serving-platform` |
| bastion-host | `HYBRID_DISPATCH_REF` | `feat/airgap-mirror` |

## 1. 직접 채워야 하는 secret (cross-repo dispatch 토큰)

값이 PAT(또는 GitHub App 토큰)이라 자동 등록 불가. fine-grained PAT 권장.

| repo | secret | 필요 권한 | 용도 |
| --- | --- | --- | --- |
| hybrid-ai-serving-platform | `BASTION_DISPATCH_TOKEN` | bastion-host repo: **Actions: write + Secrets: write** | public apply 후 bastion에 TF output secret sync + provision 디스패치 |
| bastion-host | `HYBRID_DISPATCH_TOKEN` | hybrid repo: **Actions: write** | bastion VPN 후 private-cloud-controller 디스패치 |

```bash
# 예시 — PAT 발급(github.com/settings/personal-access-tokens) 후:
printf '%s' 'github_pat_xxxxxxxx_REPLACE_ME' \
  | gh secret set BASTION_DISPATCH_TOKEN --repo SGS-Strategy/hybrid-ai-serving-platform

printf '%s' 'github_pat_yyyyyyyy_REPLACE_ME' \
  | gh secret set HYBRID_DISPATCH_TOKEN --repo SGS-Strategy/bastion-host
```

> 대안: hybrid에 이미 있는 GitHub App(`GH_APP_ID`/`GH_APP_INSTALLATION_ID`/`GH_APP_PRIVATE_KEY`)을
> 두 repo에 설치하고 워크플로에서 installation 토큰을 발급해 쓸 수도 있다. 그 경우 위 secret 대신
> 디스패치 스텝을 App 토큰으로 바꾸면 된다.

## 2. (선택) airgap GPU 미러 — non-VPN egress 완전 차단용

미러 URL을 모르면 비워둬도 된다(빈 값 = upstream origin = 현행 동작). Bastion registry/file 미러를
세운 뒤 아래 var를 미러로 채우면 GPU 워커가 NVIDIA에 공인 인터넷으로 안 나간다.

| repo | variable | 예시 값(미러로 교체) | upstream 기본값 |
| --- | --- | --- | --- |
| hybrid | `GPU_NVIDIA_TOOLKIT_BASE_URL` | `https://mirror.internal.intp.me/nvidia/libnvidia-container` | `https://nvidia.github.io/libnvidia-container` |
| hybrid | `GPU_CUDA_REPO_BASE_URL` | `https://mirror.internal.intp.me/nvidia/cuda/repos` | `https://developer.download.nvidia.com/compute/cuda/repos` |

```bash
# 미러 준비되면:
gh variable set GPU_NVIDIA_TOOLKIT_BASE_URL --repo SGS-Strategy/hybrid-ai-serving-platform \
  --body 'https://mirror.internal.intp.me/nvidia/libnvidia-container'
gh variable set GPU_CUDA_REPO_BASE_URL --repo SGS-Strategy/hybrid-ai-serving-platform \
  --body 'https://mirror.internal.intp.me/nvidia/cuda/repos'
```

## 3. 라이브 전 1회 전제조건

- `gh workflow run`은 워크플로 파일이 **대상 repo 기본 브랜치(main)** 에 있어야 디스패치된다.
  - bastion `provision.yml` → bastion-host `main` 병합 필요 (현재 `feat/bastion-provision-actions`).
  - hybrid `private-cloud-controller.yml` → hybrid `main`에 있어야 함(확인).
  - 기본 브랜치에 존재하면 `--ref`로 위 *_REF 변수(feature 브랜치) 버전을 실행할 수 있다.

## 4. 전체 체인 한 번에 돌리기

위 1번(+ 3번 병합) 완료 후, **Public Terraform Deploy** 워크플로를:

```
action = apply
trigger_bastion_vpn = true
trigger_private = true
```

로 실행하면 public apply → bastion VPN render/apply → private 재apply(터널 UP, ECR/STS/S3는 IPsec 경유)까지 자동으로 흐른다.
