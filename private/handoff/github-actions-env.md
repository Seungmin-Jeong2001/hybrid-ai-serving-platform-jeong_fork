# GitHub Actions Environment Handoff

이 문서는 GitHub Actions 환경의 공개 가능한 인계 범위만 정리합니다.

## Workflow 범위

```text
private-cloud-controller # apply/destroy 선택, OpenStack lifecycle 선택, VM별 apply job DAG
private-cloud-remote     # controller에서만 호출하는 reusable SSH executor workflow
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
- DevStack full init 캐시는 `.ha/openstack/devstack-cache`에 남기며, APT archives와 root/stack pip cache를 LXD disk device로 재사용합니다.
- 캐시를 끄려면 `HA_DEVSTACK_CACHE_ENABLED=false`를 Actions 환경에 지정합니다.

## GitLab bootstrap 변수

- `GITLAB_ROOT_PASSWORD`: GitHub Actions secret입니다. root password와 custom admin user password를 같이 설정합니다.
- `GITLAB_ADMIN_USERNAME`: GitHub Actions variable입니다. 비워두면 `root`만 사용하고, `root`가 아닌 값이면 GitLab bootstrap이 해당 admin user를 생성하거나 갱신합니다.

## 단일 host Actions 기준

- 현재 단일 DevStack host에서는 `PRIVATE_CLOUD_TFVARS`가 기존 `hybrid-ai-private` stack을 가리켜야 합니다.
- `hybrid-ai-actions`처럼 별도 stack을 동시에 올리는 테스트는 기존 stack을 destroy하거나 host capacity budget을 명시적으로 늘린 뒤에만 실행합니다.
