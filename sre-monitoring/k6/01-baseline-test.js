import http from "k6/http";
import { check, sleep } from "k6";
import { Rate } from "k6/metrics";

const errorRate = new Rate("errors");
const BASE_URL = __ENV.INFERENCE_API_URL || "http://inference-api.inference.svc.cluster.local";

// SLO 목표: 가용성 99.9%, p95 응답시간 500ms 이하
export const options = {
  stages: [
    { duration: "1m", target: 10 },  // 워밍업
    { duration: "3m", target: 10 },  // 기준 부하 유지
    { duration: "1m", target: 0  },  // 종료
  ],
  thresholds: {
    http_req_failed:   ["rate<0.001"],  // 99.9% 가용성 SLO
    http_req_duration: ["p(95)<500"],   // p95 500ms 이하
    errors:            ["rate<0.001"],
  },
};

export default function () {
  const payload = JSON.stringify({
    job_id: `test-${Date.now()}`,
    sensor_data: [0.1, 0.2, 0.3, 0.4, 0.5],
  });

  const res = http.post(`${BASE_URL}/infer`, payload, {
    headers: { "Content-Type": "application/json" },
    timeout: "5s",
  });

  const success = check(res, {
    "status 200": (r) => r.status === 200,
    "응답시간 500ms 이하": (r) => r.timings.duration < 500,
  });

  errorRate.add(!success);
  sleep(1);
}
