# PDM Predictor 1-Pod RPS Test

This folder contains the load-test assets used to measure the stable RPS of a
single `pdm-predictor` pod.

## Purpose

- Fix predictor to `minReplicas=1`, `maxReplicas=1`
- Send a production-like `window=1000` payload directly to predictor
- Find the highest RPS that still satisfies:
  - `http_req_failed < 1%`
  - `p95 < 500ms`

## Files

- `pdm-predictor-rps-test.js`: k6 script for stable RPS measurement
- `pdm-predictor-payload.json`: production-like payload with 1000 inputs
- `k6-job.yaml`: in-cluster ConfigMap + Job manifest

## Recommended execution

Use the cluster-internal job instead of local `kubectl port-forward`.

Reason:

- local port-forward can become the bottleneck first
- port-forward failures can distort the true predictor capacity

## Run in cluster

1. Ensure predictor is fixed to one pod.
2. Create the ConfigMap from the tracked files:

```bash
kubectl create configmap pdm-predictor-rps-scripts \
  --from-file=pdm-predictor-rps-test.js=sre/k6/pdm-predictor-rps/pdm-predictor-rps-test.js \
  --from-file=pdm-predictor-payload.json=sre/k6/pdm-predictor-rps/pdm-predictor-payload.json \
  -n inference
```

3. Apply the job:

```bash
kubectl apply -f sre/k6/pdm-predictor-rps/k6-job.yaml
```

4. Watch the job:

```bash
kubectl get pods -n inference -w
kubectl logs -n inference job/pdm-predictor-rps-test -f
```

5. Clean up if needed:

```bash
kubectl delete job -n inference pdm-predictor-rps-test
kubectl delete configmap -n inference pdm-predictor-rps-scripts
```

## Run locally for smoke checks only

```bash
kubectl port-forward -n inference svc/pdm-predictor 18080:80
k6 run -e BASE_URL=http://127.0.0.1:18080 -e PREDICT_PATH=/v1/models/pdm:predict ./pdm-predictor-rps-test.js
```

Do not use long-running local port-forward results as the final sizing basis.
