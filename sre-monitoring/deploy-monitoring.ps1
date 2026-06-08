# ============================================================
# SGS-HASP 모니터링 스택 자동 배포 스크립트
# 담당: 신민석 (⑥ Reliability & Chaos Engineering)
#
# 사용법:
#   cd C:\lastproject\sre-monitoring
#   .\deploy-monitoring.ps1
# ============================================================

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$CLUSTER_NAME = "sgs-hasp-eks"
$REGION       = "ap-northeast-2"
$NAMESPACE    = "monitoring"
$SCRIPT_DIR   = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host ""
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host " SGS-HASP 모니터링 스택 배포 시작" -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host ""

# 1. kubeconfig 업데이트
Write-Host "[1/7] kubeconfig 업데이트..." -ForegroundColor Yellow
aws eks update-kubeconfig --name $CLUSTER_NAME --region $REGION
Write-Host "      완료`n" -ForegroundColor Green

# 2. 네임스페이스 생성
Write-Host "[2/7] monitoring 네임스페이스 생성..." -ForegroundColor Yellow
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
Write-Host "      완료`n" -ForegroundColor Green

# 3. helm repo 추가
Write-Host "[3/7] helm repo 추가 및 업데이트..." -ForegroundColor Yellow
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>$null
helm repo add grafana https://grafana.github.io/helm-charts 2>$null
helm repo update | Out-Null
Write-Host "      완료`n" -ForegroundColor Green

# 4. Prometheus + Alertmanager
Write-Host "[4/7] Prometheus + Alertmanager 설치..." -ForegroundColor Yellow
helm upgrade --install prometheus-public prometheus-community/kube-prometheus-stack `
  -n $NAMESPACE `
  -f "$SCRIPT_DIR\prometheus\prometheus-public-values.yaml" `
  --set alertmanager.alertmanagerSpec.storage.volumeClaimTemplate.spec.storageClassName=gp2 `
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName=gp2 `
  --timeout 5m
Write-Host "      완료`n" -ForegroundColor Green

# 5. Grafana
Write-Host "[5/7] Grafana 설치..." -ForegroundColor Yellow
kubectl create configmap grafana-sre-dashboards -n $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install grafana grafana/grafana `
  -n $NAMESPACE `
  -f "$SCRIPT_DIR\grafana\grafana-values.yaml" `
  --timeout 3m
Write-Host "      완료`n" -ForegroundColor Green

# 6. Loki + Promtail
Write-Host "[6/7] Loki + Promtail 설치..." -ForegroundColor Yellow
helm upgrade --install loki grafana/loki `
  -n $NAMESPACE `
  -f "$SCRIPT_DIR\loki\loki-values.yaml" `
  --timeout 3m
helm upgrade --install promtail grafana/promtail `
  -n $NAMESPACE `
  -f "$SCRIPT_DIR\loki\promtail-values.yaml" `
  --timeout 3m
Write-Host "      완료`n" -ForegroundColor Green

# 7. Alert Rules
Write-Host "[7/7] Alert Rules 적용..." -ForegroundColor Yellow
kubectl apply -f "$SCRIPT_DIR\prometheus\rules\alert-rules.yaml"
kubectl apply -f "$SCRIPT_DIR\prometheus\rules\slo-rules.yaml"
Write-Host "      완료`n" -ForegroundColor Green

# 완료
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host " 배포 완료!" -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host ""
kubectl get pods -n $NAMESPACE
Write-Host ""
Write-Host "Grafana 접속 명령어:" -ForegroundColor White
Write-Host "  kubectl port-forward svc/grafana 3000:80 -n monitoring" -ForegroundColor Gray
Write-Host "  http://localhost:3000  (admin / admin)" -ForegroundColor Gray
Write-Host ""
