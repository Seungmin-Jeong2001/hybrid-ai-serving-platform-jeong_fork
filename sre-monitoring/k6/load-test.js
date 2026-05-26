/**
 * k6 부하 테스트 — 정상 부하 시나리오
 * 담당: 신민석 (⑥ Reliability & Chaos Engineering)
 *
 * 검증 목표:
 *   - SLO 목표 하에서의 정상 부하 처리 확인
 *   - P99 레이턴시 < 5s 검증
 *   - 에러율 < 1% 검증
 *
 * 실행:
 *   # 기본 실행 (로컬 테스트)
 *   k6 run load-test.js
 *
 *   # 실제 엔드포인트 지정
 *   k6 run -e BASE_URL=http://your-alb-endpoint.ap-northeast-2.elb.amazonaws.com load-test.js
 *
 *   # 결과를 Prometheus로 전송 (Grafana 연동)
 *   k6 run --out experimental-prometheus-rw load-test.js
 *
 * 의존성:
 *   ② 안예원 BentoML 서비스 또는 ④ 최호성 API Server 배포 완료 필요
 */

import http from "k6/http";
import { sleep, check, group } from "k6";
import { Rate, Trend, Counter } from "k6/metrics";

// ============================================================
// 커스텀 메트릭 정의
// ============================================================
const errorRate = new Rate("inference_error_rate");
const inferenceLatency = new Trend("inference_latency_ms", true);
const successCount = new Counter("inference_success_count");
const failCount = new Counter("inference_fail_count");

// ============================================================
// 부하 테스트 설정 — 정상 부하 (SLO 검증용)
// ============================================================
export const options = {
  stages: [
    { duration: "1m", target: 10 },   // 웜업: 10 VU로 서서히 증가
    { duration: "3m", target: 10 },   // 정상 부하 유지
    { duration: "1m", target: 20 },   // 부하 증가
    { duration: "3m", target: 20 },   // 증가된 부하 유지
    { duration: "1m", target: 0 },    // 쿨다운
  ],

  // SLO 기반 임계값
  thresholds: {
    // P99 < 5s (KServe timeout 기준) + P95 < 3s (일반 응답성 목표)
    // 같은 키를 두 번 쓰면 나중 값이 앞을 덮어써 P99 검증이 누락되므로 배열로 합침
    "http_req_duration{scenario:inference}": ["p(99)<5000", "p(95)<3000"],

    // 에러율 < 1% (DLQ SLO 기준)
    "inference_error_rate": ["rate<0.01"],

    // 전체 HTTP 오류율 < 5%
    "http_req_failed": ["rate<0.05"],

    // 커스텀 레이턴시 메트릭
    "inference_latency_ms": ["p(99)<5000", "p(95)<3000"],
  },
};

// ============================================================
// 환경 설정
// ============================================================
const BASE_URL = __ENV.BASE_URL || "http://localhost:8080";

// AI4I 2020 Predictive Maintenance Dataset 기반 센서 데이터 샘플
// (② 안예원 BentoML 서비스 입력 형식에 맞게 조정 필요)
const SENSOR_SAMPLES = [
  // 정상 상태 (Machine Failure = 0)
  { air_temperature: 298.1, process_temperature: 308.6, rotational_speed: 1551, torque: 42.8, tool_wear: 0 },
  { air_temperature: 300.5, process_temperature: 310.2, rotational_speed: 1408, torque: 46.3, tool_wear: 25 },
  { air_temperature: 302.7, process_temperature: 312.8, rotational_speed: 1498, torque: 38.5, tool_wear: 50 },

  // 고장 경계 상태 (Machine Failure = 1)
  { air_temperature: 310.2, process_temperature: 322.4, rotational_speed: 1168, torque: 73.2, tool_wear: 200 },
  { air_temperature: 308.9, process_temperature: 320.1, rotational_speed: 1350, torque: 65.8, tool_wear: 180 },
];

// ============================================================
// 메인 테스트 함수
// ============================================================
export default function () {
  // 랜덤 센서 데이터 선택
  const payload = SENSOR_SAMPLES[Math.floor(Math.random() * SENSOR_SAMPLES.length)];

  group("inference", function () {
    // ── 헬스체크 ──────────────────────────────────────────
    const healthRes = http.get(`${BASE_URL}/healthz`, {
      tags: { scenario: "health" },
      timeout: "5s",
    });

    check(healthRes, {
      "health check 200": (r) => r.status === 200,
    });

    // ── 추론 요청 ──────────────────────────────────────────
    const inferenceRes = http.post(
      `${BASE_URL}/predict`,
      JSON.stringify(payload),
      {
        headers: {
          "Content-Type": "application/json",
          "X-Request-ID": `k6-${Date.now()}-${__VU}-${__ITER}`,
        },
        tags: { scenario: "inference" },
        timeout: "10s",
      }
    );

    // 응답 검증
    const success = check(inferenceRes, {
      "status 200": (r) => r.status === 200,
      "has failure_probability": (r) => {
        try {
          const body = JSON.parse(r.body);
          return typeof body.failure_probability === "number";
        } catch {
          return false;
        }
      },
      "latency < 5s": (r) => r.timings.duration < 5000,
    });

    // 커스텀 메트릭 기록
    errorRate.add(!success);
    inferenceLatency.add(inferenceRes.timings.duration);

    if (success) {
      successCount.add(1);
    } else {
      failCount.add(1);
      console.error(
        `추론 실패 | VU: ${__VU} | 상태: ${inferenceRes.status} | ` +
        `레이턴시: ${inferenceRes.timings.duration}ms | ` +
        `응답: ${inferenceRes.body?.substring(0, 100)}`
      );
    }
  });

  // 요청 간 대기 (1초 — 초당 약 1 req/VU)
  sleep(1);
}

// ============================================================
// 테스트 완료 후 요약 출력
// ============================================================
export function handleSummary(data) {
  const p99 = data.metrics["inference_latency_ms"]?.values?.["p(99)"] || 0;
  const p95 = data.metrics["inference_latency_ms"]?.values?.["p(95)"] || 0;
  const errorRateVal = data.metrics["inference_error_rate"]?.values?.rate || 0;
  const totalRequests = data.metrics["http_reqs"]?.values?.count || 0;

  const sloP99Pass = p99 < 5000;
  const sloP95Pass = p95 < 3000;
  const sloErrorPass = errorRateVal < 0.01;

  console.log("\n");
  console.log("=".repeat(60));
  console.log("  SLO 검증 결과 요약");
  console.log("=".repeat(60));
  console.log(`  총 요청 수: ${totalRequests}`);
  console.log(`  P99 레이턴시: ${p99.toFixed(0)}ms  (목표: < 5000ms) → ${sloP99Pass ? "✅ PASS" : "❌ FAIL"}`);
  console.log(`  P95 레이턴시: ${p95.toFixed(0)}ms  (목표: < 3000ms) → ${sloP95Pass ? "✅ PASS" : "❌ FAIL"}`);
  console.log(`  에러율:       ${(errorRateVal * 100).toFixed(2)}%    (목표: < 1%)      → ${sloErrorPass ? "✅ PASS" : "❌ FAIL"}`);
  console.log("=".repeat(60));
  console.log(`  전체 SLO: ${sloP99Pass && sloP95Pass && sloErrorPass ? "✅ PASS" : "❌ FAIL"}`);
  console.log("=".repeat(60));

  return {
    stdout: JSON.stringify(data, null, 2),
  };
}
