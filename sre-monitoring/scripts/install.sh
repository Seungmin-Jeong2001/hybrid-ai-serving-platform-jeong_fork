#!/bin/bash
# ============================================================
# SRE 모니터링 스택 설치 스크립트
# 담당: 신민석 (⑥ Reliability & Chaos Engineering)
#
# 개발 순서 (SRE 역할 세부 계획서 §8 기준):
#   1단계: Prometheus (Public) + Grafana  ← 현재 스크립트
#   2단계: Loki + Promtail
#   3단계: Alertmanager Slack 설정
#   4단계: Prometheus (Private) — ① 문경호 완성 후
#   5단계: SLO Rules 배포
#   6단계: Chaos Mesh 설치
#   7단계: k6 트래픽 테스트
#
# 사전 조건:
#   - kubectl, helm 설치
#   - EKS 클러스터 kubeconfig 설정 완료
#   - AWS CLI 설정 (S3 버킷, ECR 접근)
#
# 실행:
#   chmod +x install.sh
#   ./install.sh [단계번호]   예: ./install.sh 1
# ============================================================

set -euo pipefail

NAMESPACE="monitoring"
CHAOS_NAMESPACE="chaos-testing"

# 컬러 출력
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ============================================================
# Helm 레포지토리 추가
# ============================================================
add_helm_repos() {
  info "Helm 레포지토리 추가 중..."
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
  helm repo add grafana https://grafana.github.io/helm-charts
  helm repo add chaos-mesh https://charts.chaos-mesh.org
  helm repo update
  success "Helm 레포지토리 추가 완료"
}

# ============================================================
# 1단계: Prometheus (Public) + Grafana 기본 설치
# ============================================================
step1_prometheus_grafana() {
  info "=== 1단계: Prometheus (Public) + Grafana 설치 ==="

  kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

  # kube-prometheus-stack 설치
  info "kube-prometheus-stack 설치 중..."
  helm upgrade --install prometheus-public prometheus-community/kube-prometheus-stack \
    --namespace "${NAMESPACE}" \
    --values ../prometheus/prometheus-public-values.yaml \
    --wait --timeout 10m

  success "Prometheus (Public) 설치 완료"

  # Grafana 대시보드 ConfigMap 먼저 생성 (Grafana 시작 전 존재해야 volume mount 가능)
  info "Grafana 대시보드 ConfigMap 생성 중..."
  kubectl create configmap grafana-sre-dashboards \
    --from-file=../grafana/dashboards/sre-platform.json \
    -n "${NAMESPACE}" \
    --dry-run=client -o yaml | kubectl apply -f -

  # Grafana 설치 (ConfigMap이 이미 존재하므로 정상 시작)
  info "Grafana 설치 중..."
  helm upgrade --install grafana grafana/grafana \
    --namespace "${NAMESPACE}" \
    --values ../grafana/grafana-values.yaml \
    --wait --timeout 5m

  success "Grafana 설치 완료"

  info "SLO / Alert Rules 배포 중..."
  kubectl apply -f ../prometheus/rules/slo-rules.yaml
  kubectl apply -f ../prometheus/rules/alert-rules.yaml
  success "Rules 배포 완료"

  # 접속 정보 출력
  echo ""
  echo "=== Grafana 접속 방법 ==="
  echo "kubectl port-forward svc/grafana 3000:80 -n ${NAMESPACE}"
  echo "URL: http://localhost:3000"
  GRAFANA_PWD=$(kubectl get secret grafana -n "${NAMESPACE}" \
    -o jsonpath="{.data.admin-password}" 2>/dev/null | base64 -d)
  echo "계정: admin / ${GRAFANA_PWD:-<secret 생성 후 확인>}"
  echo ""
  echo "=== Prometheus 접속 방법 ==="
  echo "kubectl port-forward svc/prometheus-public-kube-prometheus-prometheus 9090:9090 -n ${NAMESPACE}"
}

# ============================================================
# 2단계: Loki + Promtail 설치
# ============================================================
step2_loki_promtail() {
  info "=== 2단계: Loki + Promtail 설치 ==="

  warn "S3 버킷이 생성되어 있는지 확인하세요: sre-loki-logs-ACCOUNT_ID"
  warn "loki-values.yaml의 S3 버킷명을 실제 값으로 교체했는지 확인하세요."
  read -p "계속하시겠습니까? (y/N): " confirm
  [[ "$confirm" == "y" || "$confirm" == "Y" ]] || { warn "2단계 건너뜀"; return; }

  helm upgrade --install loki grafana/loki \
    --namespace "${NAMESPACE}" \
    --values ../loki/loki-values.yaml \
    --wait --timeout 10m

  helm upgrade --install promtail grafana/promtail \
    --namespace "${NAMESPACE}" \
    --values ../loki/promtail-values.yaml \
    --wait --timeout 5m

  success "Loki + Promtail 설치 완료"
  info "Grafana에서 Loki 데이터소스 연결을 확인하세요."
}

# ============================================================
# 3단계: Alertmanager Slack 웹훅 설정
# ============================================================
step3_alertmanager_slack() {
  info "=== 3단계: Alertmanager Slack 웹훅 설정 ==="

  warn "prometheus-public-values.yaml의 slack_api_url을 실제 Slack 웹훅으로 교체하세요."
  echo "  위치: alertmanager.config.global.slack_api_url"
  echo "  Slack 웹훅 생성: https://api.slack.com/messaging/webhooks"
  read -p "웹훅 설정 후 계속하시겠습니까? (y/N): " confirm
  [[ "$confirm" == "y" || "$confirm" == "Y" ]] || { warn "3단계 건너뜀"; return; }

  helm upgrade prometheus-public prometheus-community/kube-prometheus-stack \
    --namespace "${NAMESPACE}" \
    --values ../prometheus/prometheus-public-values.yaml \
    --reuse-values \
    --wait --timeout 5m

  success "Alertmanager Slack 설정 완료"
  info "테스트 알람 발송:"
  echo "  kubectl exec -it -n ${NAMESPACE} \$(kubectl get pod -n ${NAMESPACE} -l app.kubernetes.io/name=alertmanager -o jsonpath='{.items[0].metadata.name}') -- amtool alert add alertname=TestAlert severity=warning"
}

# ============================================================
# 6단계: Chaos Mesh 설치
# ============================================================
step6_chaos_mesh() {
  info "=== 6단계: Chaos Mesh 설치 ==="

  kubectl create namespace "${CHAOS_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

  helm upgrade --install chaos-mesh chaos-mesh/chaos-mesh \
    --namespace "${CHAOS_NAMESPACE}" \
    --set controllerManager.replicaCount=1 \
    --set chaosDaemon.runtime=containerd \
    --set chaosDaemon.socketPath=/run/containerd/containerd.sock \
    --wait --timeout 5m

  success "Chaos Mesh 설치 완료"
  echo ""
  echo "=== Chaos Mesh Dashboard ==="
  echo "kubectl port-forward svc/chaos-dashboard 2333:2333 -n ${CHAOS_NAMESPACE}"
  echo "URL: http://localhost:2333"
  echo ""
  echo "=== Chaos 시나리오 실행 순서 ==="
  echo "  1. kubectl apply -f ../chaos-mesh/01-pod-kill.yaml"
  echo "  2. kubectl apply -f ../chaos-mesh/02-network-delay.yaml"
  echo "  3. kubectl apply -f ../chaos-mesh/03-http-fault.yaml && k6 run ../k6/stress-test.js"
  echo "  4. kubectl apply -f ../chaos-mesh/04-bad-deploy.yaml  (ArgoCD 롤백 확인)"
}

# ============================================================
# 7단계: k6 트래픽 테스트
# ============================================================
step7_k6_test() {
  info "=== 7단계: k6 트래픽 테스트 ==="

  if ! command -v k6 &> /dev/null; then
    warn "k6가 설치되지 않았습니다."
    echo "설치: https://k6.io/docs/getting-started/installation/"
    echo "  또는: brew install k6  /  choco install k6"
    return
  fi

  echo ""
  echo "테스트 선택:"
  echo "  1) 정상 부하 테스트 (SLO 검증)"
  echo "  2) 스트레스 테스트 (트래픽 폭주)"
  read -p "선택 (1/2): " choice

  BASE_URL="${K6_BASE_URL:-http://localhost:8080}"
  warn "BASE_URL: ${BASE_URL} (K6_BASE_URL 환경변수로 변경 가능)"

  case "$choice" in
    1) k6 run -e BASE_URL="${BASE_URL}" ../k6/load-test.js ;;
    2) k6 run -e BASE_URL="${BASE_URL}" ../k6/stress-test.js ;;
    *) warn "잘못된 선택" ;;
  esac
}

# ============================================================
# 전체 상태 확인
# ============================================================
check_status() {
  info "=== SRE 모니터링 스택 상태 확인 ==="
  kubectl get pods -n "${NAMESPACE}" 2>/dev/null || warn "monitoring namespace 없음"
  echo ""
  kubectl get pods -n "${CHAOS_NAMESPACE}" 2>/dev/null || warn "chaos-testing namespace 없음"
  echo ""
  kubectl get prometheusrule -n "${NAMESPACE}" 2>/dev/null || warn "PrometheusRule 없음"
}

# ============================================================
# 메인 실행
# ============================================================
main() {
  local step="${1:-status}"

  add_helm_repos

  case "$step" in
    1) step1_prometheus_grafana ;;
    2) step2_loki_promtail ;;
    3) step3_alertmanager_slack ;;
    6) step6_chaos_mesh ;;
    7) step7_k6_test ;;
    status) check_status ;;
    all)
      step1_prometheus_grafana
      step2_loki_promtail
      step3_alertmanager_slack
      ;;
    *)
      echo "사용법: $0 [1|2|3|6|7|all|status]"
      echo "  1: Prometheus (Public) + Grafana + SLO Rules"
      echo "  2: Loki + Promtail"
      echo "  3: Alertmanager Slack 설정"
      echo "  6: Chaos Mesh 설치"
      echo "  7: k6 트래픽 테스트"
      echo "  all: 1~3 순차 실행"
      echo "  status: 현재 상태 확인"
      ;;
  esac
}

main "$@"
