# ⑥ Reliability & Chaos Engineering — 개발 환경 및 구조

> 담당: 신민석 | 브랜치: `feature/monitoring`
> 최종 업데이트: 2026-05-18

---

## 1. 역할 개요

SRE 모니터링 스택 전체를 담당. 팀 서비스의 신뢰성 지표(SLO)를 수집·시각화하고, 장애 알림 및 Chaos 실험을 통해 서비스 회복 탄력성을 검증한다.

| 구성 요소 | 도구 | 역할 |
|---|---|---|
| 메트릭 수집 | Prometheus × 2 | Public(EKS) + Private(OpenStack) 이중화 |
| 시각화 | Grafana | 통합 SLO 대시보드 |
| 로그 수집 | Loki + Promtail | 전체 Pod 로그 → S3 |
| 장애 알림 | Alertmanager → Discord | critical / warning 채널 분리 |
| Chaos 실험 | Chaos Mesh | 4가지 장애 시나리오 |
| 부하 테스트 | k6 | SLO 검증 + 스트레스 테스트 |

---

## 2. 디렉토리 구조

```
├── public/
│   ├── terraform/                     # AWS 인프라 (EKS, MSK, VPC, DynamoDB 등) — ④ 최호성
│   └── ansible/
│       ├── site.yml                   # Ansible 플레이북 진입점
│       ├── requirements.yml
│       ├── examples/
│       │   └── monitoring.vars.yml.example
│       └── roles/monitoring/
│           ├── defaults/main.yml      # 기본 변수 (리소스, Discord 웹훅 등)
│           ├── tasks/main.yml         # 배포 태스크 (Helm + PrometheusRule 적용)
│           └── templates/values.yaml.j2  # kube-prometheus-stack Helm values 템플릿
├── private/
│   └── README.md                      # Private K8s 환경 문서 — ① 문경호
└── sre-monitoring/
    ├── prometheus/
    │   ├── prometheus-public-values.yaml   # kube-prometheus-stack (EKS, 수동 배포용)
    │   ├── prometheus-private-values.yaml  # Private K8s (팀원 협의 후 진행)
    │   └── rules/
    │       ├── slo-rules.yaml              # SLO Recording Rules
    │       └── alert-rules.yaml            # Alertmanager Alert Rules
    ├── grafana/
    │   ├── grafana-values.yaml             # 수동 배포용 (Ansible은 values.yaml.j2 사용)
    │   └── dashboards/sre-platform.json   # Grafana 대시보드 JSON
    ├── loki/
    │   ├── loki-values.yaml               # S3 백엔드, Single Binary
    │   └── promtail-values.yaml           # DaemonSet 로그 에이전트
    ├── chaos-mesh/
    │   ├── 01-pod-kill.yaml               # Pod 강제 종료
    │   ├── 02-network-delay.yaml          # 네트워크 지연 주입
    │   ├── 03-http-fault.yaml             # HTTP 오류 주입
    │   └── 04-bad-deploy.yaml             # 잘못된 이미지 배포 → 롤백 검증
    ├── k6/
    │   ├── load-test.js                   # 정상 부하 (SLO 검증)
    │   └── stress-test.js                 # 트래픽 폭주 (에러율 50% 조기종료)
    ├── scripts/install.sh                 # 단계별 설치 자동화 (수동 배포용)
    └── .gitattributes                     # LF 줄끝 고정 (sh/yaml/js)
```

---

## 3. SLO 목표

| 지표 | 목표값 | 비고 |
|---|---|---|
| 가용성 | 99.9% | 월 허용 다운타임 약 43분 |
| 추론 P99 레이턴시 | 5초 이내 | KServe timeout 기준 |
| DLQ 발생률 | 1% 미만 | ⑤ 김세원 Kafka 연동 후 측정 |

Error Budget 번 레이트 알림 기준 (Google SRE Book 기반):
- **Critical**: 1h 내 번 레이트 14.4× 이상 → 즉시 대응
- **Warning**: 6h 내 번 레이트 6× 이상 → 빠른 대응

---

## 4. 설치 방법

### 사전 조건

```bash
# 필수 도구
kubectl  # EKS kubeconfig 연결 완료
helm     # v3 이상
k6       # 부하 테스트용

# AWS 전제 조건
- gp3 StorageClass (EBS CSI 드라이버 설치 필요)
- S3 버킷 생성: sre-loki-logs-{ACCOUNT_ID}
- IRSA Role 생성 (S3 접근 권한)
```

### 방법 1 — Ansible 자동 배포 (권장, ④ 최호성 EKS 배포 후)

```bash
cd public/ansible

# 의존성 설치
ansible-galaxy install -r requirements.yml

# 배포 (SSM에서 Grafana 비밀번호 자동 주입)
ansible-playbook site.yml -e monitoring_aws_region=ap-northeast-2
```

### 방법 2 — install.sh 수동 배포

```bash
cd sre-monitoring/scripts
chmod +x install.sh

./install.sh 1   # Prometheus(Public) + Grafana + SLO/Alert Rules
./install.sh 2   # Loki + Promtail

# 팀원 서비스 완성 후
./install.sh 6   # Chaos Mesh 설치
./install.sh 7   # k6 트래픽 테스트
```

### 접속 확인

```bash
# Grafana (Ansible 배포 시)
kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring
# → http://localhost:3000  (admin / admin)

# Prometheus
kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n monitoring

# Chaos Mesh Dashboard
kubectl port-forward svc/chaos-dashboard 2333:2333 -n chaos-testing
```

---

## 5. 주요 설정

### Prometheus 이중화

| 인스턴스 | 대상 | 릴리즈명 |
|---|---|---|
| Prometheus-Public | EKS (KEDA, ArgoCD, BentoML, KServe, Kafka) | `kube-prometheus-stack` (Ansible) / `prometheus-public` (수동) |
| Prometheus-Private | Private K8s (etcd, controller-manager 등) | `prometheus-private` (팀원 협의 후 진행) |

두 인스턴스를 단일 Grafana에서 datasource로 통합.

### Alertmanager Discord 웹훅 구성

Discord 채널별 Incoming Webhook 연동 완료:
- `#sre-alerts-critical` → Critical 알림 전용 (즉시 대응)
- `#sre-alerts-warning` → Warning 알림 전용 (빠른 대응)

> Discord 웹훅 URL 끝에 `/slack`을 붙이면 Alertmanager `slack_configs`와 호환됨
> 형식: `https://discord.com/api/webhooks/{id}/{token}/slack`

### Loki S3 백엔드

```yaml
region: ap-northeast-2
bucket: sre-loki-logs-{ACCOUNT_ID}  # 교체 필요
retention: 168h (7일)
```

IRSA를 통해 EKS Pod → S3 접근 (AWS 콘솔에서 Role ARN 발급 후 입력 필요)

---

## 6. 팀원 서비스 통합 체크리스트

각 팀원 서비스 완성 시 아래 주석(`# TODO(통합)`) 처리된 부분을 해제하고 `helm upgrade` 실행.

| 팀원 | 완성 후 작업 |
|---|---|
| ① 문경호 (Private K8s) | 팀원 협의 후 진행 — `prometheus-private-values.yaml` 설치, Grafana에 Prometheus-Private datasource 추가 |
| ② 안예원 (BentoML) | `prometheus-public-values.yaml` BentoML scrape 주석 해제, `slo-rules.yaml` vector(0) → 실제 메트릭 교체 |
| ③ 정승민 (ArgoCD) | `alert-rules.yaml` argocd.alerts 주석 해제 |
| ④ 최호성 (KServe) | `prometheus-public-values.yaml` KServe scrape 주석 해제, chaos 시나리오 selector 교체 |
| ⑤ 김세원 (Kafka) | `prometheus-public-values.yaml` Kafka Exporter 주석 해제, `slo-rules.yaml` DLQ vector(0) 교체, `alert-rules.yaml` kafka.alerts 주석 해제 |

---

## 7. Chaos Engineering 시나리오

| 파일 | 시나리오 | 검증 목표 |
|---|---|---|
| `01-pod-kill.yaml` | Pod 강제 종료 | Kubernetes Self-healing, Discord 알람 |
| `02-network-delay.yaml` | 네트워크 200ms 지연 | Kafka Consumer Lag 변화, KEDA 스케일링 |
| `03-http-fault.yaml` | HTTP 500 오류 5% 주입 | 에러율 SLO 위반, Error Budget 소진 속도 |
| `04-bad-deploy.yaml` | 잘못된 이미지 배포 | ArgoCD 롤백 동작, MTTR 측정 |

실행 순서: `kubectl apply -f chaos-mesh/0X-*.yaml` → Grafana 관찰 → `kubectl delete -f` 복구

---

## 8. 진행 현황

| 단계 | 항목 | 상태 |
|---|---|---|
| 코드 | Prometheus Public values | ✅ 완료 |
| 코드 | Prometheus Private values | ✅ 완료 (보류) |
| 코드 | SLO / Alert Rules | ✅ 완료 |
| 코드 | Grafana + 대시보드 JSON | ✅ 완료 |
| 코드 | Loki + Promtail | ✅ 완료 |
| 코드 | Chaos Mesh 4가지 시나리오 | ✅ 완료 |
| 코드 | k6 부하/스트레스 테스트 | ✅ 완료 |
| 코드 | install.sh 자동화 스크립트 | ✅ 완료 |
| 코드 | Ansible 모니터링 롤 조율 (main 통합) | ✅ 완료 |
| 배포 | Prometheus + Grafana 실제 설치 | ❌ 미완 |
| 배포 | Loki + Promtail 실제 설치 | ❌ 미완 |
| 배포 | Alertmanager Discord 웹훅 연동 | ✅ 완료 |
| 배포 | Chaos Mesh 설치 | ❌ 미완 |
| 연동 | BentoML 메트릭 연동 (② 안예원) | ⏳ 대기 |
| 연동 | KServe 메트릭 연동 (④ 최호성) | ⏳ 대기 |
| 연동 | Kafka Exporter 연동 (⑤ 김세원) | ⏳ 대기 |
| 연동 | Private Prometheus 추가 (① 문경호) | ⏳ 대기 |
| 검증 | SLO Rules 실측 튜닝 | ⏳ 대기 |
| 검증 | Chaos 시나리오 실행 + 결과 기록 | ⏳ 대기 |
| 검증 | k6 최종 부하 테스트 | ⏳ 대기 |

---

## 9. 주요 이슈 사항

| 이슈 | 원인 | 해결 방법 |
|---|---|---|
| Grafana 시작 실패 | `dashboardsConfigMaps` 참조 ConfigMap이 없을 때 volume mount 불가 | install.sh에서 ConfigMap을 Grafana 설치 전에 먼저 생성하도록 순서 수정 |
| k6 P99 SLO 검증 누락 | JavaScript 객체 중복 키 → 나중 값이 앞을 덮어씀 | 두 threshold를 배열 하나로 합침 `["p(99)<5000", "p(95)<3000"]` |
| 알림 채널 분리 | Slack Incoming Webhook은 채널 override 불가, Discord로 전환 | receiver별 `api_url` 직접 지정 + Discord 웹훅 URL에 `/slack` suffix 적용 |
| ClusterRole 과도한 권한 | `04-bad-deploy.yaml`이 전체 클러스터 Deployment 수정 가능 | namespace-scoped `Role`로 교체 |
| PodNotReady 알림 노이즈 | 시스템 namespace (kube-system, monitoring 등) Pod 포함 | namespace 필터 추가 (`namespace!~"kube-system|..."`) |
| LF/CRLF 문제 | Windows 개발 환경에서 sh 파일이 CRLF로 변환 시 Linux 실행 불가 | `.gitattributes`로 sh/yaml/js 파일 LF 강제 고정 |
