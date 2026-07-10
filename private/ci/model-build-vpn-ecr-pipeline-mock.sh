#!/usr/bin/env bash
# Mock of the real model-build → Harbor → ECR(over VPN) delivery path.
#
# 실제 경로(private/kubernetes/model-build-workflows/workflowtemplates.yaml +
# private/handoff/model-build-delivery.md)를 그대로 미러링하되,
#   - train / package 단계는 mock (GPU 학습/Kaniko 빌드 없이 산출물만 흉내)
#   - promote:ecr 단계는 "실제" ECR-over-VPN 경로를 검증(DNS가 VPC 사설IP로 풀리는지 +
#     터널/STS/ECR 로그인). --push 를 줘야만 진짜 skopeo copy 를 시도한다.
#
# 10.42.0.0/24 노드(예: build-worker)에서 실행해야 IPsec selector 를 타서 VPN 으로 나간다.
# 일반 egress 는 절대 쓰지 않는다: ECR/STS/S3 호스트가 공인 IP 로 풀리면 즉시 실패 처리한다.
#
# usage:
#   ./model-build-vpn-ecr-pipeline-mock.sh            # train/package mock + promote readiness probe (no push)
#   ./model-build-vpn-ecr-pipeline-mock.sh --push     # readiness 통과 시 실제 Harbor→ECR skopeo copy
set -euo pipefail

# ── 실제 파이프라인과 동일한 파라미터 (workflowtemplates.yaml / .gitlab-ci.yml 기준) ──
AWS_REGION="${AWS_REGION:-ap-northeast-2}"
VPC_CIDR_PREFIX="${VPC_CIDR_PREFIX:-10.0.}"            # VPC 10.0.0.0/16 → 사설 해석 판정용
HARBOR_REGISTRY="${HARBOR_REGISTRY:-harbor.intp.me}"
HARBOR_PROJECT="${HARBOR_PROJECT:-models}"
IMAGE_NAME="${IMAGE_NAME:-predictive-model}"
ECR_REPOSITORY="${ECR_REPOSITORY:-${IMAGE_NAME}}"
IMAGE_TAG="${IMAGE_TAG:-mock-$(date -u +%Y%m%d%H%M%S)}"
MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://minio.minio-tenant.svc.cluster.local}"
ARTIFACT_BUCKET="${ARTIFACT_BUCKET:-artifacts}"
ARTIFACT_PREFIX="${ARTIFACT_PREFIX:-models/mock/${IMAGE_TAG}}"

# 실행 모드:
#   (기본)          : train/package mock + promote readiness 프로브만 (아무것도 push 안 함)
#   --manifest-only : 수정 없이 진짜 ECR-over-VPN. 이미 ECR에 있는 이미지(SRC_TAG)에
#                     새 태그(NEW_TAG)를 put-image 로 붙임 → ecr.api/STS 만 사용, S3 불필요
#   --push          : Harbor→ECR 풀 copy(skopeo). 레이어 업로드 발생 → S3 인터페이스 엔드포인트 필요
DO_PUSH=false
MANIFEST_ONLY=false
ECR_SRC_TAG="${ECR_SRC_TAG:-latest}"
ECR_NEW_TAG="${ECR_NEW_TAG:-vpn-test-$(date -u +%Y%m%d%H%M%S)}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --push) DO_PUSH=true; shift ;;
    --manifest-only) MANIFEST_ONLY=true; shift ;;
    --ecr-repo) ECR_REPOSITORY="$2"; shift 2 ;;
    --src-tag) ECR_SRC_TAG="$2"; shift 2 ;;
    --new-tag) ECR_NEW_TAG="$2"; shift 2 ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; exit 64 ;;
  esac
done

log() { printf '[%s] %s\n' "$1" "$2"; }
have() { command -v "$1" >/dev/null 2>&1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── stage 1: train (mock) — 실제 model-build-job 의 GPU 학습 대체 ──────────────
mock_train() {
  log mock-train "GPU 학습 대신 더미 산출물 생성 (model_weights.pt, scaler.pkl)"
  head -c 1024 /dev/urandom > "${WORK}/model_weights.pt"
  printf 'mock-scaler\n' > "${WORK}/scaler.pkl"
  if have mc; then
    mc alias set mockminio "${MINIO_ENDPOINT}" "${MINIO_ACCESS_KEY:-}" "${MINIO_SECRET_KEY:-}" >/dev/null 2>&1 || true
    mc cp "${WORK}/model_weights.pt" "mockminio/${ARTIFACT_BUCKET}/${ARTIFACT_PREFIX}/model_weights.pt" 2>/dev/null \
      && log mock-train "artifact 업로드 OK: ${ARTIFACT_BUCKET}/${ARTIFACT_PREFIX}/" \
      || log mock-train "MinIO 업로드 건너뜀(자격증명/엔드포인트 미설정) — mock 계속"
  else
    log mock-train "mc 없음 — MinIO 업로드 단계 흉내만 (로컬 산출물 유지)"
  fi
}

# ── stage 2: package (mock) — 실제 model-package(kaniko) 대체 ────────────────
HARBOR_IMAGE=""
HARBOR_DIGEST="mock-sha256-$(date -u +%s)"
mock_package() {
  HARBOR_IMAGE="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${IMAGE_NAME}:${IMAGE_TAG}"
  log mock-package "Kaniko 빌드 대신 Harbor 이미지 레퍼런스만 확정: ${HARBOR_IMAGE}"
  log mock-package "harbor_digest(mock)=${HARBOR_DIGEST}"
}

# ── stage 3: promote:ecr — 실제 ECR-over-VPN 경로 (핵심) ─────────────────────
resolve_ip() {
  if have getent; then getent ahostsv4 "$1" | awk 'NR==1{print $1}'
  else python3 -c "import socket,sys;print(socket.gethostbyname(sys.argv[1]))" "$1" 2>/dev/null
  fi
}

assert_vpc_private() {
  local host="$1" ip; ip="$(resolve_ip "$host" || true)"
  if [[ -z "$ip" ]]; then
    log promote "FAIL: ${host} 해석 실패 (온프렘 DNS 포워딩 미설정?)"; return 1
  fi
  if [[ "$ip" == ${VPC_CIDR_PREFIX}* ]]; then
    log promote "OK  : ${host} → ${ip} (VPC 사설 = VPN 경로)"; return 0
  fi
  log promote "FAIL: ${host} → ${ip} (공인 IP = 일반 egress! VPN/DNS 경로 아님)"; return 1
}

promote_ecr() {
  local registry="${AWS_ACCOUNT_ID:-<ACCOUNT>}.dkr.ecr.${AWS_REGION}.amazonaws.com"
  log promote "ECR-over-VPN readiness 프로브 시작 (region=${AWS_REGION})"

  local ready=true
  assert_vpc_private "api.ecr.${AWS_REGION}.amazonaws.com"  || ready=false
  # DKR 엔드포인트는 와일드카드(*.dkr.ecr...)라 account-prefixed 호스트로만 해석된다.
  if [[ -n "${AWS_ACCOUNT_ID:-}" ]]; then
    assert_vpc_private "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com" || ready=false
  else
    log promote "SKIP: dkr.ecr 프로브 (AWS_ACCOUNT_ID 미설정 → <account>.dkr.ecr... 호스트 불명)"
  fi
  assert_vpc_private "sts.${AWS_REGION}.amazonaws.com"      || ready=false
  # S3 인터페이스 엔드포인트는 레이어 업로드(=풀 push)에만 필요. manifest-only/probe엔 무관.
  if [[ "$DO_PUSH" == true ]]; then
    assert_vpc_private "s3.${AWS_REGION}.amazonaws.com"     || ready=false
  else
    assert_vpc_private "s3.${AWS_REGION}.amazonaws.com" \
      || log promote "NOTE: s3 사설 아님 — 풀 push엔 enable_s3_interface_endpoint 필요(지금 모드엔 무관)"
  fi

  if [[ "$ready" != true ]]; then
    log promote "BLOCKED: 위 FAIL 항목 때문에 실 push 불가. (특히 s3.* 공인이면 enable_s3_interface_endpoint=true + 2차 apply 필요)"
    log promote "→ mock 종료. 일반 egress 로는 절대 push 하지 않음."
    return 2
  fi

  # 수정 없이 진짜 VPN 검증: 기존 ECR 이미지에 새 태그만 put (레이어 업로드=S3 없음)
  if [[ "$MANIFEST_ONLY" == true ]]; then
    have aws || { log promote "aws CLI 필요"; return 1; }
    log promote "manifest-only: ${ECR_REPOSITORY}:${ECR_SRC_TAG} → :${ECR_NEW_TAG} (S3 미사용, ecr.api/STS=VPN)"
    local manifest
    manifest="$(aws ecr batch-get-image --region "${AWS_REGION}" \
      --repository-name "${ECR_REPOSITORY}" --image-ids imageTag="${ECR_SRC_TAG}" \
      --query 'images[0].imageManifest' --output text)"
    [[ -n "$manifest" && "$manifest" != "None" ]] || {
      log promote "FAIL: ${ECR_REPOSITORY}:${ECR_SRC_TAG} 매니페스트 없음 (기존 이미지가 있어야 retag 가능)"; return 1; }
    aws ecr put-image --region "${AWS_REGION}" \
      --repository-name "${ECR_REPOSITORY}" --image-tag "${ECR_NEW_TAG}" \
      --image-manifest "$manifest" >/dev/null
    log promote "manifest-only push 완료: ${ECR_REPOSITORY}:${ECR_NEW_TAG} (VPN으로 ECR 컨트롤플레인 호출 성공)"
    return 0
  fi

  if [[ "$DO_PUSH" != true ]]; then
    log promote "readiness GREEN. --push/--manifest-only 없으므로 실제 호출 생략 (mock)."
    return 0
  fi

  have aws skopeo || { log promote "aws/skopeo 필요"; return 1; }
  local ecr_image="${registry}/${ECR_REPOSITORY}:${IMAGE_TAG}"
  log promote "실 push: ${HARBOR_IMAGE} → ${ecr_image}"
  aws ecr get-login-password --region "${AWS_REGION}" \
    | skopeo login "${registry}" --username AWS --password-stdin
  skopeo copy --all "docker://${HARBOR_IMAGE}" "docker://${ecr_image}"
  log promote "push 완료: ${ecr_image}"
}

# ── release manifest (실제 promote:ecr 의 release.json 미러) ──────────────────
write_release() {
  cat > "${WORK}/release.json" <<JSON
{
  "schemaVersion": 1,
  "mock": true,
  "image_tag": "${IMAGE_TAG}",
  "harbor": { "image": "${HARBOR_IMAGE}", "digest": "${HARBOR_DIGEST}" },
  "ecr": { "repository": "${ECR_REPOSITORY}", "region": "${AWS_REGION}", "full_push": ${DO_PUSH}, "manifest_only": ${MANIFEST_ONLY} }
}
JSON
  log release "release.json 생성: $(tr -d '\n' < "${WORK}/release.json")"
  if have mc; then
    mc cp "${WORK}/release.json" \
      "mockminio/${ARTIFACT_BUCKET}/manifests/mock/${IMAGE_TAG}/release.json" 2>/dev/null \
      && log release "release.json 업로드 OK" || log release "release.json 업로드 건너뜀"
  fi
}

main() {
  log pipeline "model-build → Harbor → ECR(VPN) mock 시작 (push=${DO_PUSH})"
  mock_train
  mock_package
  set +e; promote_ecr; rc=$?; set -e
  write_release
  log pipeline "완료 (promote rc=${rc})"
  return "$rc"
}
main "$@"
