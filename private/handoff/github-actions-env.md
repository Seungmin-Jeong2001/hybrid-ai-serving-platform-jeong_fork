# GitHub Actions Environment Handoff

이 문서는 GitHub Actions 환경의 공개 가능한 인계 범위만 정리합니다.

## Workflow 범위

```text
private-cloud-plan      # 변경 검토, Terraform plan, DNS dry-run
private-cloud-controller # apply/destroy 선택, OpenStack lifecycle 선택, VM별 apply job DAG
private-cloud-remote     # reusable SSH executor workflow
```

## 환경 구분 계획

```text
Workflow inputs
  -> 실행 모드와 검증 옵션

Repository settings
  -> 환경별 공개 설정과 비공개 설정

Terraform variables
  -> VM count, image, flavor, GPU dependency, GitLab image, Harbor image
```

## 기본 계획

- GPU worker 기본 count는 1입니다.
- Harbor 기본 count는 1입니다.
- Build-worker는 GitLab SSH runner host입니다.
- GPU worker는 SSH execution target입니다.
- Harbor는 별도 영속 registry VM입니다.
- Argo Workflows와 Kaniko는 Kubernetes 내부 실행 구성입니다.
- OpenStack image cache는 dependency manifest hash 기반으로 재빌드합니다.

## GitLab bootstrap 변수

- `GITLAB_ROOT_PASSWORD`: GitHub Actions secret입니다. root password와 custom admin user password를 같이 설정합니다.
- `GITLAB_ADMIN_USERNAME`: GitHub Actions variable입니다. 비워두면 `root`만 사용하고, `root`가 아닌 값이면 GitLab bootstrap이 해당 admin user를 생성하거나 갱신합니다.
