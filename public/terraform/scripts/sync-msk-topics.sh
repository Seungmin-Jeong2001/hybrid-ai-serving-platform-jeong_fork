#!/bin/sh
# MSK 토픽 생성 및 설정 동기화 (kafka-topics.sh / kafka-configs.sh 사용)

set -eu

KAFKA_VERSION="3.7.1"
KAFKA_SCALA="2.13"
KAFKA_DIR="/tmp/kafka-${KAFKA_VERSION}"
KAFKA_TOPICS="${KAFKA_DIR}/bin/kafka-topics.sh"
KAFKA_CONFIGS="${KAFKA_DIR}/bin/kafka-configs.sh"

require_env() {
  var_name="$1"
  eval "var_value=\${$var_name:-}"
  if [ -z "$var_value" ]; then
    echo "$var_name must be set." >&2
    exit 1
  fi
}

require_env "MSK_BOOTSTRAP_BROKERS"
require_env "MSK_TOPIC_REPLICATION_FACTOR"
require_env "MSK_TOPIC_CONFIGS_JSON"
require_env "MSK_TOPICS_JSON"

if [ "${MSK_TOPIC_REPLICATION_FACTOR}" -lt 1 ]; then
  echo "MSK_TOPIC_REPLICATION_FACTOR must be at least 1." >&2
  exit 1
fi

# Kafka 바이너리 설치
if [ ! -f "$KAFKA_TOPICS" ]; then
  if ! java -version >/dev/null 2>&1; then
    sudo yum install -y java-17-amazon-corretto-headless
  fi
  curl -fsSL \
    "https://downloads.apache.org/kafka/${KAFKA_VERSION}/kafka_${KAFKA_SCALA}-${KAFKA_VERSION}.tgz" \
    -o /tmp/kafka.tgz
  tar -xzf /tmp/kafka.tgz -C /tmp
  mv "/tmp/kafka_${KAFKA_SCALA}-${KAFKA_VERSION}" "$KAFKA_DIR"
  rm /tmp/kafka.tgz
fi

# 토픽 생성 및 파티션 조정
printf '%s' "$MSK_TOPICS_JSON" | jq -r 'to_entries[] | @base64' | while IFS= read -r entry; do
  topic_name="$(printf '%s' "$entry" | base64 -d | jq -r '.key')"
  desired_partitions="$(printf '%s' "$entry" | base64 -d | jq -r '.value')"

  if [ "$desired_partitions" -lt 1 ]; then
    echo "Topic '$topic_name' must have at least one partition." >&2
    exit 1
  fi

  existing_partitions="$("$KAFKA_TOPICS" \
    --bootstrap-server "$MSK_BOOTSTRAP_BROKERS" \
    --describe \
    --topic "$topic_name" 2>/dev/null \
    | grep -oE 'PartitionCount:[0-9]+' | cut -d: -f2 || echo "")"

  if [ -z "$existing_partitions" ]; then
    echo "Creating topic '$topic_name' with $desired_partitions partitions."
    "$KAFKA_TOPICS" \
      --bootstrap-server "$MSK_BOOTSTRAP_BROKERS" \
      --create \
      --topic "$topic_name" \
      --partitions "$desired_partitions" \
      --replication-factor "$MSK_TOPIC_REPLICATION_FACTOR"
    continue
  fi

  if [ "$existing_partitions" -lt "$desired_partitions" ]; then
    echo "Increasing topic '$topic_name' partitions from $existing_partitions to $desired_partitions."
    "$KAFKA_TOPICS" \
      --bootstrap-server "$MSK_BOOTSTRAP_BROKERS" \
      --alter \
      --topic "$topic_name" \
      --partitions "$desired_partitions"
    continue
  fi

  if [ "$existing_partitions" -gt "$desired_partitions" ]; then
    echo "Topic '$topic_name' already has $existing_partitions partitions, which is greater than the desired $desired_partitions. Partition reduction is not supported." >&2
    exit 1
  fi

  echo "Topic '$topic_name' already matches desired partition count $desired_partitions."
done

# 설정 적용 (신규/기존 토픽 모두)
has_configs="$(printf '%s' "$MSK_TOPIC_CONFIGS_JSON" | jq 'length > 0')"
if [ "$has_configs" = "true" ]; then
  config_str="$(printf '%s' "$MSK_TOPIC_CONFIGS_JSON" | \
    jq -r 'to_entries | map("\(.key)=\(.value)") | join(",")')"

  printf '%s' "$MSK_TOPICS_JSON" | jq -r 'keys[]' | while IFS= read -r topic_name; do
    echo "Applying configs to topic '$topic_name': $config_str"
    "$KAFKA_CONFIGS" \
      --bootstrap-server "$MSK_BOOTSTRAP_BROKERS" \
      --alter \
      --entity-type topics \
      --entity-name "$topic_name" \
      --add-config "$config_str"
  done
fi
