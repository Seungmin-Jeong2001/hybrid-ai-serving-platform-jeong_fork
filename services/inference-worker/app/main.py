import json
import logging
import os
import random
import time
from typing import Any

import boto3
import httpx
from kafka import KafkaConsumer, KafkaProducer, TopicPartition
from kafka.errors import KafkaError
from botocore.exceptions import ClientError


logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger("inference-worker")


def _bootstrap_servers() -> str:
    value = os.getenv("BOOTSTRAP_SERVERS", "").strip()
    if not value or value == "replace-me:9092":
        raise RuntimeError("BOOTSTRAP_SERVERS must be configured")
    return value


def _predict_url() -> str:
    base_url = os.getenv(
        "PREDICTOR_URL",
        "http://kserve-predictor.hasp.svc.cluster.local",
    ).rstrip("/")
    endpoint = os.getenv("PREDICTOR_ENDPOINT", "/v1/models/default:predict")
    return f"{base_url}{endpoint}"


def _request_topic() -> str:
    return os.getenv("REQUEST_TOPIC", "inference-request")


def _retry_topic() -> str:
    return os.getenv("RETRY_TOPIC", "inference-retry")


def _dlq_topic() -> str:
    return os.getenv("DLQ_TOPIC", "inference-dlq")


def _subscribed_topics() -> tuple[str, str]:
    return (_request_topic(), _retry_topic())


def _consumer_group() -> str:
    return os.getenv("WORKER_CONSUMER_GROUP", "inference-worker-group")


def _max_retry_count() -> int:
    return int(os.getenv("MAX_RETRY_COUNT", "3"))


def _retry_backoff_schedule_seconds() -> tuple[int, ...]:
    return (10, 30, 60)


def _retry_jitter_seconds() -> int:
    return int(os.getenv("RETRY_JITTER_SECONDS", "5"))


def _retry_poll_delay_seconds() -> float:
    return float(os.getenv("RETRY_POLL_DELAY_SECONDS", "1"))


def _jobs_table_name() -> str:
    return os.getenv("DYNAMODB_TABLE_NAME", "sgs-hasp-inference-jobs")


def _idempotency_ttl_seconds() -> int:
    return int(os.getenv("IDEMPOTENCY_TTL_SECONDS", str(7 * 24 * 60 * 60)))


def _create_jobs_table():
    return boto3.resource("dynamodb", region_name=os.getenv("AWS_REGION")).Table(
        _jobs_table_name()
    )


def _create_consumer() -> KafkaConsumer:
    return KafkaConsumer(
        *_subscribed_topics(),
        bootstrap_servers=_bootstrap_servers(),
        client_id=os.getenv("KAFKA_CONSUMER_CLIENT_ID", "inference-worker"),
        group_id=_consumer_group(),
        enable_auto_commit=False,
        auto_offset_reset=os.getenv("AUTO_OFFSET_RESET", "earliest"),
        value_deserializer=lambda value: json.loads(value.decode("utf-8")),
        key_deserializer=lambda value: value.decode("utf-8") if value is not None else None,
    )


def _create_producer() -> KafkaProducer:
    return KafkaProducer(
        bootstrap_servers=_bootstrap_servers(),
        client_id=os.getenv("KAFKA_PRODUCER_CLIENT_ID", "inference-worker"),
        acks="all",
        enable_idempotence=True,
        retries=3,
        value_serializer=lambda value: json.dumps(value).encode("utf-8"),
        key_serializer=lambda value: value.encode("utf-8"),
    )


def _now_epoch() -> int:
    return int(time.time())


def _ttl_epoch() -> int:
    return _now_epoch() + _idempotency_ttl_seconds()


def _compute_next_attempt_at(retry_count: int) -> int:
    schedule = _retry_backoff_schedule_seconds()
    delay_index = min(max(retry_count - 1, 0), len(schedule) - 1)
    base_delay = schedule[delay_index]
    jitter = random.randint(-_retry_jitter_seconds(), _retry_jitter_seconds())
    return _now_epoch() + max(base_delay + jitter, 0)


def _load_job_record(jobs_table, request_id: str) -> dict[str, Any] | None:
    response = jobs_table.get_item(Key={"request_id": request_id})
    return response.get("Item")


def _claim_request(jobs_table, request_id: str, source_topic: str) -> bool:
    timestamp = _now_epoch()
    try:
        jobs_table.put_item(
            Item={
                "request_id": request_id,
                "status": "PROCESSING",
                "retry_count": 0,
                "source_topic": source_topic,
                "updated_at": timestamp,
                "ttl": _ttl_epoch(),
            },
            ConditionExpression="attribute_not_exists(request_id)",
        )
        return True
    except ClientError as exc:
        if exc.response["Error"]["Code"] != "ConditionalCheckFailedException":
            raise
        return False


def _update_job_status(
    jobs_table,
    request_id: str,
    *,
    status: str,
    retry_count: int,
    source_topic: str,
    last_error: str | None = None,
) -> None:
    expression_attribute_values: dict[str, Any] = {
        ":status": status,
        ":retry_count": retry_count,
        ":source_topic": source_topic,
        ":updated_at": _now_epoch(),
        ":ttl": _ttl_epoch(),
    }
    update_expression = (
        "SET #status = :status, retry_count = :retry_count, source_topic = :source_topic, "
        "updated_at = :updated_at, ttl = :ttl"
    )
    expression_attribute_names = {"#status": "status"}

    if last_error is not None:
        expression_attribute_values[":last_error"] = last_error
        update_expression += ", last_error = :last_error"

    jobs_table.update_item(
        Key={"request_id": request_id},
        UpdateExpression=update_expression,
        ExpressionAttributeNames=expression_attribute_names,
        ExpressionAttributeValues=expression_attribute_values,
    )


def _should_route_immediately_to_dlq(payload: dict[str, Any]) -> bool:
    parameters = payload.get("parameters", {})
    return bool(parameters.get("dlq_immediately") or parameters.get("retryable") is False)


def _publish(
    producer: KafkaProducer,
    topic: str,
    job_id: str,
    payload: dict[str, Any],
) -> None:
    producer.send(topic, key=job_id, value=payload).get(timeout=30)


def _build_failure_payload(
    payload: dict[str, Any],
    *,
    error_message: str,
    retry_count: int,
    source_topic: str,
    failure_stage: str,
) -> dict[str, Any]:
    failed_payload = dict(payload)
    failed_payload["retry_count"] = retry_count
    failed_payload["source_topic"] = source_topic
    failed_payload["failure_stage"] = failure_stage
    failed_payload["last_error"] = error_message
    return failed_payload


def _defer_retry_record(consumer: KafkaConsumer, record, next_attempt_at: int) -> bool:
    if record.topic != _retry_topic():
        return False

    remaining_seconds = next_attempt_at - _now_epoch()
    if remaining_seconds <= 0:
        return False

    topic_partition = TopicPartition(record.topic, record.partition)
    consumer.seek(topic_partition, record.offset)
    sleep_seconds = min(remaining_seconds, _retry_poll_delay_seconds())
    logger.info(
        "defer retry request_id=%s remaining_seconds=%s next_attempt_at=%s",
        record.key or "unknown-job",
        remaining_seconds,
        next_attempt_at,
    )
    time.sleep(sleep_seconds)
    return True


def _process_message(payload: dict[str, Any]) -> dict[str, Any]:
    predictor_payload = {
        "inputs": payload.get("inputs", []),
        "parameters": payload.get("parameters", {}),
    }
    with httpx.Client(timeout=30.0) as client:
        response = client.post(_predict_url(), json=predictor_payload)
        response.raise_for_status()
        return response.json()


def run() -> None:
    logger.info(
        "worker started bootstrap_servers=%s subscribed_topics=%s dlq_topic=%s consumer_group=%s jobs_table=%s retry_schedule_seconds=%s retry_jitter_seconds=%s",
        _bootstrap_servers(),
        ",".join(_subscribed_topics()),
        _dlq_topic(),
        _consumer_group(),
        _jobs_table_name(),
        ",".join(str(value) for value in _retry_backoff_schedule_seconds()),
        _retry_jitter_seconds(),
    )
    consumer = _create_consumer()
    producer = _create_producer()
    jobs_table = _create_jobs_table()

    try:
        while True:
            records_map = consumer.poll(timeout_ms=1000, max_records=10)
            should_continue_polling = True
            for _, records in records_map.items():
                for record in records:
                    payload = record.value
                    request_id = (
                        payload.get("request_id")
                        or payload.get("job_id")
                        or record.key
                        or "unknown-job"
                    )
                    job_id = request_id
                    retry_count = int(payload.get("retry_count", 0))
                    next_attempt_at = int(payload.get("next_attempt_at", 0) or 0)

                    try:
                        if _defer_retry_record(consumer, record, next_attempt_at):
                            should_continue_polling = False
                            break

                        if record.topic == _request_topic():
                            claimed = _claim_request(jobs_table, request_id, record.topic)
                            if not claimed:
                                existing = _load_job_record(jobs_table, request_id)
                                logger.info(
                                    "skip duplicate request_id=%s existing_status=%s",
                                    request_id,
                                    existing.get("status") if existing else "unknown",
                                )
                                consumer.commit()
                                continue
                        else:
                            existing = _load_job_record(jobs_table, request_id)
                            if existing and existing.get("status") == "SUCCEEDED":
                                logger.info(
                                    "skip duplicate retry request_id=%s because it already succeeded",
                                    request_id,
                                )
                                consumer.commit()
                                continue
                            _update_job_status(
                                jobs_table,
                                request_id,
                                status="PROCESSING",
                                retry_count=retry_count,
                                source_topic=record.topic,
                            )

                        if _should_route_immediately_to_dlq(payload):
                            dlq_payload = _build_failure_payload(
                                payload,
                                error_message="message met immediate dlq criteria",
                                retry_count=retry_count,
                                source_topic=record.topic,
                                failure_stage="pre-validation",
                            )
                            _publish(producer, _dlq_topic(), job_id, dlq_payload)
                            _update_job_status(
                                jobs_table,
                                request_id,
                                status="DLQ",
                                retry_count=retry_count,
                                source_topic=_dlq_topic(),
                                last_error="message met immediate dlq criteria",
                            )
                            consumer.commit()
                            logger.info("message routed immediately to dlq job_id=%s", job_id)
                            continue

                        result = _process_message(payload)
                        _update_job_status(
                            jobs_table,
                            request_id,
                            status="SUCCEEDED",
                            retry_count=retry_count,
                            source_topic=record.topic,
                        )
                        consumer.commit()
                        logger.info(
                            "processed inference job_id=%s source_topic=%s result=%s",
                            job_id,
                            record.topic,
                            json.dumps(result),
                        )
                    except httpx.HTTPError as exc:
                        next_retry_count = retry_count + 1
                        failure_payload = _build_failure_payload(
                            payload,
                            error_message=str(exc),
                            retry_count=next_retry_count,
                            source_topic=record.topic,
                            failure_stage="predictor-http",
                        )

                        if next_retry_count <= _max_retry_count():
                            next_attempt_at = _compute_next_attempt_at(next_retry_count)
                            failure_payload["next_attempt_at"] = next_attempt_at
                            _publish(producer, _retry_topic(), job_id, failure_payload)
                            _update_job_status(
                                jobs_table,
                                request_id,
                                status="RETRY_PENDING",
                                retry_count=next_retry_count,
                                source_topic=_retry_topic(),
                                last_error=str(exc),
                            )
                            logger.warning(
                                "published retry message job_id=%s retry_count=%s next_attempt_at=%s",
                                job_id,
                                next_retry_count,
                                next_attempt_at,
                            )
                        else:
                            failure_payload["dlq_reason"] = "retry_exhausted"
                            _publish(producer, _dlq_topic(), job_id, failure_payload)
                            _update_job_status(
                                jobs_table,
                                request_id,
                                status="DLQ",
                                retry_count=next_retry_count,
                                source_topic=_dlq_topic(),
                                last_error=str(exc),
                            )
                            logger.warning(
                                "published dlq message after retries job_id=%s retry_count=%s",
                                job_id,
                                next_retry_count,
                            )

                        consumer.commit()
                    except KafkaError:
                        logger.exception("failed to publish retry/dlq message job_id=%s", job_id)
                    except Exception as exc:  # noqa: BLE001
                        failure_payload = _build_failure_payload(
                            payload,
                            error_message=str(exc),
                            retry_count=retry_count,
                            source_topic=record.topic,
                            failure_stage="worker-unhandled",
                        )
                        failure_payload["dlq_reason"] = "unhandled_worker_error"
                        _publish(producer, _dlq_topic(), job_id, failure_payload)
                        _update_job_status(
                            jobs_table,
                            request_id,
                            status="DLQ",
                            retry_count=retry_count,
                            source_topic=_dlq_topic(),
                            last_error=str(exc),
                        )
                        consumer.commit()
                        logger.exception("worker failed and routed to dlq job_id=%s", job_id)
                if not should_continue_polling:
                    break
    finally:
        consumer.close()
        producer.flush()
        producer.close()


if __name__ == "__main__":
    run()
