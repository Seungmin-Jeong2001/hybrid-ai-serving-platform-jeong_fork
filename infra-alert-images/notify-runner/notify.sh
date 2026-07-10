#!/usr/bin/env sh
set -eu

NOTIFY_STATUS="${NOTIFY_STATUS:-failed}"
ERROR_SUMMARY_FILE="${ERROR_SUMMARY_FILE:-ci_error_summary.txt}"

echo "[notify-runner] start pipeline notification: status=${NOTIFY_STATUS}"

if [ -z "${ALERT_RELAY_URL:-}" ]; then
  echo "[notify-runner] ALERT_RELAY_URL is not set. Skip alert."
  exit 0
fi

if [ -z "${ALERT_RELAY_TOKEN:-}" ]; then
  echo "[notify-runner] ALERT_RELAY_TOKEN is not set. Skip alert."
  exit 0
fi

FOUND_SUMMARY_FILE=""
SUMMARY_SOURCE="default"

if [ -n "${NOTIFY_SUMMARY:-}" ]; then
  SUMMARY="${NOTIFY_SUMMARY}"
  SUMMARY_SOURCE="NOTIFY_SUMMARY"
else
  if [ -f "$ERROR_SUMMARY_FILE" ]; then
    FOUND_SUMMARY_FILE="$ERROR_SUMMARY_FILE"
  else
    FOUND_SUMMARY_FILE="$(find . -type f \( -name 'ci_error_summary.txt' -o -name 'ci_error_summary*.txt' \) | sort | tail -n 1 || true)"
  fi

  if [ -n "${FOUND_SUMMARY_FILE:-}" ] && [ -f "$FOUND_SUMMARY_FILE" ]; then
    SUMMARY="$(tail -n 80 "$FOUND_SUMMARY_FILE")"
    SUMMARY_SOURCE="$FOUND_SUMMARY_FILE"
  else
    SUMMARY="No summary provided. Check the GitLab pipeline log."
  fi
fi

jq -n \
  --arg project "${CI_PROJECT_NAME:-unknown}" \
  --arg project_path "${CI_PROJECT_PATH:-unknown}" \
  --arg job "${CI_JOB_NAME:-unknown}" \
  --arg stage "${CI_JOB_STAGE:-unknown}" \
  --arg status "${NOTIFY_STATUS}" \
  --arg branch "${CI_COMMIT_REF_NAME:-unknown}" \
  --arg commit "${CI_COMMIT_SHORT_SHA:-unknown}" \
  --arg pipeline_url "${CI_PIPELINE_URL:-unknown}" \
  --arg job_url "${CI_JOB_URL:-unknown}" \
  --arg summary "$SUMMARY" \
  --arg error_summary "$SUMMARY" \
  --arg occurred_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  '{
    project: $project,
    project_path: $project_path,
    job: $job,
    stage: $stage,
    status: $status,
    branch: $branch,
    commit: $commit,
    pipeline_url: $pipeline_url,
    job_url: $job_url,
    summary: $summary,
    error_summary: $error_summary,
    occurred_at: $occurred_at
  }' > /tmp/alert-payload.json

echo "[notify-runner] summary source: ${SUMMARY_SOURCE}"
echo "[notify-runner] send alert to relay: ${ALERT_RELAY_URL}"

curl -sS -X POST "$ALERT_RELAY_URL" \
  -H "Content-Type: application/json" \
  -H "X-Relay-Token: ${ALERT_RELAY_TOKEN}" \
  --data-binary @/tmp/alert-payload.json

echo
echo "[notify-runner] alert sent"
