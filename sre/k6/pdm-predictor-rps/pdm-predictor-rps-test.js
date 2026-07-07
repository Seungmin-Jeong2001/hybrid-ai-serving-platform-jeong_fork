import http from "k6/http";
import { check } from "k6";
import { SharedArray } from "k6/data";

// Load the production-like predictor payload once and reuse it across VUs.
const payload = new SharedArray("pdm payload", function () {
  return [JSON.parse(open("./pdm-predictor-payload.json"))];
})[0];

// Ramp traffic gradually to find the highest stable RPS for a single predictor pod.
export const options = {
  scenarios: {
    ramp_rps: {
      // Increase request rate per second instead of fixing a VU count.
      executor: "ramping-arrival-rate",

      // Start from a low rate and ramp up stage by stage.
      startRate: 1,

      // The rate unit is requests per second.
      timeUnit: "1s",

      // Pre-allocate enough VUs for lower stages.
      preAllocatedVUs: 20,

      // Allow k6 to add more VUs when the arrival rate increases.
      maxVUs: 200,

      // Raise the target every minute and observe where latency or errors break.
      stages: [
        { target: 60, duration: "1m" },
        { target: 80, duration: "1m" },
        { target: 100, duration: "1m" },
        { target: 120, duration: "1m" }
      ]
    }
  },

  // Stable-RPS pass criteria.
  thresholds: {
    // Failure rate must stay below 1%.
    http_req_failed: ["rate<0.01"],

    // p95 latency must stay below 500 ms.
    http_req_duration: ["p(95)<500"]
  }
};

// Default to the in-cluster predictor service.
const BASE_URL =
  __ENV.BASE_URL || "http://pdm-predictor.inference.svc.cluster.local";

// Override the prediction path with an env var if needed.
const PREDICT_PATH = __ENV.PREDICT_PATH || "/v1/models/pdm:predict";

export default function () {
  // Send one inference request with the production-like payload.
  const res = http.post(
    `${BASE_URL}${PREDICT_PATH}`,
    JSON.stringify(payload),
    {
      headers: {
        "Content-Type": "application/json"
      },
      timeout: "30s"
    }
  );

  // A healthy predictor should return HTTP 200.
  check(res, {
    "status is 200": (r) => r.status === 200
  });

  // Print unexpected responses to help triage failures quickly.
  if (res.status !== 200) {
    console.log(`status=${res.status} body=${res.body}`);
  }
}
