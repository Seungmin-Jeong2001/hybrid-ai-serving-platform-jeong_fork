#!/bin/sh
# Terraform 적용 시 필요한 MSK 토픽 생성 및 파티션 수 지정

set -eu

require_env() {
  var_name="$1"
  eval "var_value=\${$var_name:-}"
  if [ -z "$var_value" ]; then
    echo "$var_name must be set." >&2
    exit 1
  fi
}

wait_topic_active() {
  topic_name="$1"
  attempt=0

  while [ "$attempt" -lt 30 ]; do
    status="$(aws kafka describe-topic \
      --region "$AWS_REGION" \
      --cluster-arn "$MSK_CLUSTER_ARN" \
      --topic-name "$topic_name" \
      --query 'Status' \
      --output text 2>/dev/null || true)"

    if [ "$status" = "ACTIVE" ]; then
      return 0
    fi

    sleep 10
    attempt=$((attempt + 1))
  done

  echo "Timed out waiting for topic '$topic_name' to become ACTIVE." >&2
  exit 1
}

require_env "AWS_REGION"
require_env "MSK_CLUSTER_ARN"
require_env "MSK_TOPIC_REPLICATION_FACTOR"
require_env "MSK_TOPIC_CONFIGS_JSON"
require_env "MSK_TOPICS_JSON"

if [ "${MSK_TOPIC_REPLICATION_FACTOR}" -lt 1 ]; then
  echo "MSK_TOPIC_REPLICATION_FACTOR must be at least 1." >&2
  exit 1
fi

topic_configs_b64="$(printf '%s' "$MSK_TOPIC_CONFIGS_JSON" | jq -r 'to_entries | map("\(.key)=\(.value)") | join("\n")' | base64 | tr -d '\n')"

printf '%s' "$MSK_TOPICS_JSON" | jq -r 'to_entries[] | @base64' | while IFS= read -r entry; do
  topic_name="$(printf '%s' "$entry" | base64 -d | jq -r '.key')"
  desired_partitions="$(printf '%s' "$entry" | base64 -d | jq -r '.value')"

  if [ "$desired_partitions" -lt 1 ]; then
    echo "Topic '$topic_name' must have at least one partition." >&2
    exit 1
  fi

  existing_partitions="$(aws kafka describe-topic \
    --region "$AWS_REGION" \
    --cluster-arn "$MSK_CLUSTER_ARN" \
    --topic-name "$topic_name" \
    --query 'PartitionCount' \
    --output text 2>/tmp/msk-topic.err || true)"

  if [ "$existing_partitions" = "None" ] || [ -z "$existing_partitions" ]; then
    if grep -q "NotFoundException" /tmp/msk-topic.err 2>/dev/null || [ ! -s /tmp/msk-topic.err ]; then
      echo "Creating topic '$topic_name' with $desired_partitions partitions."
      aws kafka create-topic \
        --region "$AWS_REGION" \
        --cluster-arn "$MSK_CLUSTER_ARN" \
        --topic-name "$topic_name" \
        --partition-count "$desired_partitions" \
        --replication-factor "$MSK_TOPIC_REPLICATION_FACTOR" \
        --configs "$topic_configs_b64" >/dev/null

      wait_topic_active "$topic_name"
      continue
    fi

    cat /tmp/msk-topic.err >&2
    exit 1
  fi

  if [ "$existing_partitions" -lt "$desired_partitions" ]; then
    echo "Increasing topic '$topic_name' partitions from $existing_partitions to $desired_partitions."
    aws kafka update-topic \
      --region "$AWS_REGION" \
      --cluster-arn "$MSK_CLUSTER_ARN" \
      --topic-name "$topic_name" \
      --partition-count "$desired_partitions" \
      --configs "$topic_configs_b64" >/dev/null

    wait_topic_active "$topic_name"
    continue
  fi

  if [ "$existing_partitions" -gt "$desired_partitions" ]; then
    echo "Topic '$topic_name' already has $existing_partitions partitions, which is greater than the desired $desired_partitions. Partition reduction is not supported." >&2
    exit 1
  fi

  aws kafka update-topic \
    --region "$AWS_REGION" \
    --cluster-arn "$MSK_CLUSTER_ARN" \
    --topic-name "$topic_name" \
    --configs "$topic_configs_b64" >/dev/null

  wait_topic_active "$topic_name"
  echo "Topic '$topic_name' already matches desired partition count $desired_partitions."
done
