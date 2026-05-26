/**
 * k6 스트레스 테스트 — 트래픽 폭주 시나리오
 * 담당: 신민석 (⑥ Reliability & Chaos Engineering)
 *
 * 검증 목표:
 *   - 트래픽 폭주 시 HPA / KEDA 오토스케일링 동작 확인
 *   - 에러율 50% 초과 시 조기 종료 조건 검증 (SRE 계획서 기준)
 *   - Chaos Mesh 03-http-fault.yaml 과 동시 실행하여 결합 효과 측정
 *   - Error Budget 소진 속도 측정
 *
 * 실행:
 *   k6 run -e BASE_URL=http://your-endpoint stress-test.js
 *
 *   # Chaos와 동시 실행:
 *   kubectl apply -f ../chaos-mesh/03-http-fault.yaml &
 *   k6 run -e BASE_URL=http://your-endpoint stress-test.js
 */

import http from "k6/http";
import { sleep, check, group } from "k6";
import { Rate, Trend } from "k6/metrics";

// ============================================================
// 커스텀 메트릭
// ============================================================
const errorRate = new Rate("stress_error_rate");
const inferenceLatency = new Trend("stress_inference_latency_ms", true);

// ============================================================
// 트래픽 폭주 시나리오
// 비즈니스 시나리오: 초당 1,000건 진동 데이터 처리 목표
// ============================================================
export const options = {
  scenarios: {
    // 정상 → 폭주 → 정상 복구 사이클
    traffic_spike: {
      executor: "ramping-vus",
      startVUs: 0,
      stages: [
        { duration: "30s", target: 10 },    // 1단계: 웜업
        { duration: "1m",  target: 50 },    // 2단계: 정상 부하
        { duration: "2m",  target: 200 },   // 3단계: 트래픽 폭주 (KEDA 스케일링 유도)
        { duration: "30s", target: 500 },   // 4단계: 극한 부하 (에러율 관찰)
        { duration: "1m",  target: 50 },    // 5단계: 부하 감소 (스케일 다운)
        { duration: "30s", target: 0 },     // 6단계: 쿨다운
      ],
      gracefulRampDown: "30s",
    },
  },

  // 폭주 시나리오용 완화된 임계값 (SRE 계획서: 에러율 50% 초과 시 조기 종료)
  thresholds: {
    // 에러율 50% 초과 시 테스트 즉시 중단
    "stress_error_rate": [
      { threshold: "rate<0.50", abortOnFail: true, delayAbortEval: "30s" },
    ],

    // P95 레이턴시 10초 (폭주 중 허용 기준)
    "stress_inference_latency_ms": ["p(95)<10000"],

    // 전체 실패율 50% 미만 (조기 종료 조건)
    "http_req_failed": [
      { threshold: "rate<0.50", abortOnFail: true, delayAbortEval: "30s" },
    ],
  },
};

const BASE_URL = __ENV.BASE_URL || "http://localhost:8080";

// KAMP 제조 AI 데이터셋 기반 진동 센서 데이터
// 비즈니스 시나리오: 회전기계 실시간 고장 진단
const VIBRATION_SAMPLES = [
  { air_temperature: 298.1, process_temperature: 308.6, rotational_speed: 1551, torque: 42.8, tool_wear: 0 },
  { air_temperature: 301.2, process_temperature: 311.3, rotational_speed: 1480, torque: 45.2, tool_wear: 30 },
  { air_temperature: 305.8, process_temperature: 315.9, rotational_speed: 1320, torque: 52.1, tool_wear: 80 },
  { air_temperature: 308.9, process_temperature: 320.1, rotational_speed: 1168, torque: 73.2, tool_wear: 200 },
  { air_temperature: 312.4, process_temperature: 324.8, rotational_speed: 1050, torque: 82.5, tool_wear: 240 },
];

export default function () {
  const payload = VIBRATION_SAMPLES[__ITER % VIBRATION_SAMPLES.length];

  group("stress_inference", function () {
    const res = http.post(
      `${BASE_URL}/predict`,
      JSON.stringify(payload),
      {
        headers: {
          "Content-Type": "application/json",
          "X-Request-ID": `k6-stress-${Date.now()}-${__VU}`,
        },
        tags: { scenario: "stress" },
        timeout: "15s",   // 폭주 중 타임아웃 여유 증가
      }
    );

    const success = check(res, {
      "status 200": (r) => r.status === 200,
      "not 5xx": (r) => r.status < 500,
      "latency < 10s": (r) => r.timings.duration < 10000,
    });

    errorRate.add(!success);
    inferenceLatency.add(res.timings.duration);

    // 폭주 중 고레이턴시 로깅
    if (res.timings.duration > 5000) {
      console.warn(
        `고레이턴시 감지 | VU: ${__VU} | ${res.timings.duration.toFixed(0)}ms | ` +
        `상태: ${res.status}`
      );
    }
  });

  // 폭주 시나리오: 요청 간 대기 없음 (최대 부하)
  sleep(0.1);
}

// ============================================================
// 테스트 완료 후 결과 요약
// ============================================================
export function handleSummary(data) {
  const p99 = data.metrics["stress_inference_latency_ms"]?.values?.["p(99)"] || 0;
  const p95 = data.metrics["stress_inference_latency_ms"]?.values?.["p(95)"] || 0;
  const errorRateVal = data.metrics["stress_error_rate"]?.values?.rate || 0;
  const totalReqs = data.metrics["http_reqs"]?.values?.count || 0;
  const rps = data.metrics["http_reqs"]?.values?.rate || 0;

  console.log("\n");
  console.log("=".repeat(65));
  console.log("  트래픽 폭주 테스트 결과 — Chaos Engineering 검증");
  console.log("=".repeat(65));
  console.log(`  총 요청 수:       ${totalReqs}`);
  console.log(`  최대 RPS:         ${rps.toFixed(1)} req/s`);
  console.log(`  P99 레이턴시:     ${p99.toFixed(0)}ms`);
  console.log(`  P95 레이턴시:     ${p95.toFixed(0)}ms`);
  console.log(`  에러율:           ${(errorRateVal * 100).toFixed(2)}%`);
  console.log("-".repeat(65));
  console.log("  [KEDA 스케일링 확인]");
  console.log("  kubectl get hpa -n <namespace> --watch");
  console.log("  kubectl get pods -n <namespace> -l app=inference-worker --watch");
  console.log("-".repeat(65));
  console.log("  [Grafana 확인 패널]");
  console.log("  - Error Budget 번 레이트 (폭주 중 급증 예상)");
  console.log("  - Deployment 레플리카 수 (KEDA 자동 확장 확인)");
  console.log("  - Kafka Consumer Lag (부하 분산 확인)");
  console.log("=".repeat(65));

  // 조기 종료 여부 확인
  if (errorRateVal >= 0.5) {
    console.log("\n  ⚠️  에러율 50% 초과로 테스트가 조기 종료됐습니다.");
    console.log("  SRE 계획서 기준: 에러율 50% 초과 시 테스트 조기 종료 조건 적용됨");
  }

  return {
    stdout: JSON.stringify(data, null, 2),
  };
}
