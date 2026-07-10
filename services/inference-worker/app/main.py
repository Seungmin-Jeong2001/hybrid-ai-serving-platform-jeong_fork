# Kafka worker responsible for predictor invocation, result storage,
# and retry/DLQ handling for the asynchronous inference pipeline.

import json
import logging
import os
import random
import threading
import time
from enum import StrEnum
from typing import Any

import boto3
import httpx
from botocore.exceptions import BotoCoreError, ClientError, NoCredentialsError
from kafka import KafkaConsumer, KafkaProducer, TopicPartition
from kafka.errors import KafkaError
from prometheus_client import Counter, Histogram, start_http_server

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger("inference-worker")


END_TO_END_LATENCY_SECONDS = Histogram(
    "end_to_end_latency_seconds",
    "End-to-end latency from edge request creation to DynamoDB persistence.",
    buckets=(0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60, 120, 300),
)
PIPELINE_COMPLETED_TOTAL = Counter(
    "inference_pipeline_completed_total",
    "Total number of inference requests fully completed and persisted to DynamoDB.",
)
RETRY_PUBLISHED_TOTAL = Counter(
    "inference_retry_published_total",
    "Total number of retry messages published by inference worker.",
)
DLQ_PUBLISHED_TOTAL = Counter(
    "inference_dlq_published_total",
    "Total number of DLQ messages published by inference worker.",
)


class ErrorType(StrEnum):
    BOOTSTRAP_CONFIG_ERROR = "BOOTSTRAP_CONFIG_ERROR"
    INVALID_INFERENCE_REQUEST = "INVALID_INFERENCE_REQUEST"
    SCHEMA_VALIDATION_ERROR = "SCHEMA_VALIDATION_ERROR"
    KSERVE_TIMEOUT = "KSERVE_TIMEOUT"
    KSERVE_INTERNAL_ERROR = "KSERVE_INTERNAL_ERROR"
    KSERVE_CLIENT_ERROR = "KSERVE_CLIENT_ERROR"
    KSERVE_BAD_RESPONSE = "KSERVE_BAD_RESPONSE"
    DYNAMODB_WRITE_ERROR = "DYNAMODB_WRITE_ERROR"
    AUTH_ERROR = "AUTH_ERROR"
    KAFKA_PUBLISH_ERROR = "KAFKA_PUBLISH_ERROR"
    RETRY_PUBLISH_ERROR = "RETRY_PUBLISH_ERROR"
    DLQ_PUBLISH_ERROR = "DLQ_PUBLISH_ERROR"
    UNHANDLED_WORKER_ERROR = "UNHANDLED_WORKER_ERROR"


AUTH_ERROR_CODES = {
    "AccessDenied",
    "AccessDeniedException",
    "ExpiredToken",
    "IncompleteSignature",
    "InvalidClientTokenId",
    "SignatureDoesNotMatch",
    "UnrecognizedClientException",
}


class InvalidInferenceRequestError(Exception):
    pass


class KServeBadResponseError(Exception):
    pass


class PipelinePublishError(Exception):
    def __init__(self, error_type: ErrorType, message: str):
        super().__init__(message)
        self.error_type = error_type


def _bootstrap_servers() -> str:
    value = os.getenv("BOOTSTRAP_SERVERS", "").strip()
    if not value or value in {"replace-me:9092", "replace-me:9094"}:
        raise RuntimeError(f"{ErrorType.BOOTSTRAP_CONFIG_ERROR}: BOOTSTRAP_SERVERS must be configured")
    return value


def _kafka_security_protocol() -> str:
    return os.getenv("KAFKA_SECURITY_PROTOCOL", "SSL")


def _predict_url() -> str:
    base_url = os.getenv(
        "PREDICTOR_URL",
        "http://pdm-predictor.inference.svc.cluster.local",
    ).rstrip("/")
    endpoint = os.getenv("PREDICTOR_ENDPOINT", "/v1/models/pdm:predict")
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


def _kserve_timeout_seconds() -> float:
    return float(os.getenv("KSERVE_TIMEOUT_SECONDS", "10"))


def _kafka_publish_timeout_seconds() -> float:
    return float(os.getenv("KAFKA_PUBLISH_TIMEOUT_SECONDS", "10"))


def _results_table_name() -> str:
    return os.getenv("DYNAMODB_TABLE_NAME", "sgs-hasp-inference-results")


def _results_ttl_seconds() -> int:
    return int(os.getenv("RESULTS_TTL_SECONDS", str(90 * 24 * 60 * 60)))


def _worker_concurrency() -> int:
    return max(1, int(os.getenv("WORKER_CONCURRENCY", "4")))


def _metrics_port() -> int:
    return int(os.getenv("METRICS_PORT", "9090"))


def _create_results_table():
    return boto3.resource("dynamodb", region_name=os.getenv("AWS_REGION")).Table(
        _results_table_name()
    )


def _validate_payload(payload: dict[str, Any]) -> None:
    required_fields = {
        "factory_id": str,
        "equipment_id": str,
        "timestamp": int,
        "inputs": list,
    }

    if not isinstance(payload, dict):
        raise InvalidInferenceRequestError("payload must be an object")

    for field_name, field_type in required_fields.items():
        if field_name not in payload:
            raise InvalidInferenceRequestError(f"missing required field: {field_name}")
        if not isinstance(payload[field_name], field_type):
            raise InvalidInferenceRequestError(
                f"invalid field type for {field_name}: expected {field_type.__name__}"
            )


def _classify_boto_error(exc: Exception) -> ErrorType:
    if isinstance(exc, NoCredentialsError):
        return ErrorType.AUTH_ERROR
    if isinstance(exc, ClientError):
        code = exc.response.get("Error", {}).get("Code", "")
        if code in AUTH_ERROR_CODES:
            return ErrorType.AUTH_ERROR
    return ErrorType.DYNAMODB_WRITE_ERROR


def _classify_http_error(exc: httpx.HTTPError) -> ErrorType:
    if isinstance(exc, httpx.TimeoutException):
        return ErrorType.KSERVE_TIMEOUT
    if isinstance(exc, httpx.HTTPStatusError):
        status_code = exc.response.status_code
        if 500 <= status_code:
            return ErrorType.KSERVE_INTERNAL_ERROR
        if 400 <= status_code < 500:
            return ErrorType.KSERVE_CLIENT_ERROR
    return ErrorType.KSERVE_INTERNAL_ERROR


def _is_retryable_error(error_type: ErrorType) -> bool:
    return error_type in {
        ErrorType.KSERVE_TIMEOUT,
        ErrorType.KSERVE_INTERNAL_ERROR,
        ErrorType.DYNAMODB_WRITE_ERROR,
        ErrorType.KAFKA_PUBLISH_ERROR,
    }


def _create_consumer(worker_index: int) -> KafkaConsumer:
    return KafkaConsumer(
        *_subscribed_topics(),
        bootstrap_servers=_bootstrap_servers(),
        security_protocol=_kafka_security_protocol(),
        client_id=f"{os.getenv('KAFKA_CONSUMER_CLIENT_ID', 'inference-worker')}-{worker_index}",
        group_id=_consumer_group(),
        enable_auto_commit=False,
        auto_offset_reset=os.getenv("AUTO_OFFSET_RESET", "earliest"),
        value_deserializer=lambda value: json.loads(value.decode("utf-8")),
        key_deserializer=lambda value: value.decode("utf-8") if value is not None else None,
    )


def _create_producer(worker_index: int) -> KafkaProducer:
    return KafkaProducer(
        bootstrap_servers=_bootstrap_servers(),
        security_protocol=_kafka_security_protocol(),
        client_id=f"{os.getenv('KAFKA_PRODUCER_CLIENT_ID', 'inference-worker')}-{worker_index}",
        acks="all",
        enable_idempotence=True,
        retries=3,
        value_serializer=lambda value: json.dumps(value).encode("utf-8"),
        key_serializer=lambda value: value.encode("utf-8"),
    )


def _now_epoch() -> int:
    return int(time.time())


def _now_epoch_ms() -> int:
    return int(time.time() * 1000)


def _compute_next_attempt_at(retry_count: int) -> int:
    schedule = _retry_backoff_schedule_seconds()
    delay_index = min(max(retry_count - 1, 0), len(schedule) - 1)
    base_delay = schedule[delay_index]
    jitter = random.randint(-_retry_jitter_seconds(), _retry_jitter_seconds())
    return _now_epoch() + max(base_delay + jitter, 0)


def _save_result(
    results_table,
    request_id: str,
    factory_id: str,
    equipment_id: str,
    prediction: str,
    requested_at: int,
) -> int:
    completed_at = _now_epoch_ms()
    results_table.put_item(
        Item={
            "request_id": request_id,
            "factory_id": factory_id,
            "equipment_id": equipment_id,
            "prediction": prediction,
            "requested_at": requested_at,
            "completed_at": completed_at,
            "ttl": _now_epoch() + _results_ttl_seconds(),
        }
    )
    return completed_at


def _observe_end_to_end_latency(requested_at: int, completed_at: int) -> None:
    if requested_at <= 0 or completed_at < requested_at:
        return
    END_TO_END_LATENCY_SECONDS.observe((completed_at - requested_at) / 1000)


def _observe_pipeline_completed() -> None:
    PIPELINE_COMPLETED_TOTAL.inc()


def _observe_retry_published() -> None:
    RETRY_PUBLISHED_TOTAL.inc()


def _observe_dlq_published() -> None:
    DLQ_PUBLISHED_TOTAL.inc()


def _start_metrics_server() -> None:
    port = _metrics_port()
    start_http_server(port)
    logger.info("worker metrics server listening port=%s", port)


def _publish(
    producer: KafkaProducer,
    topic: str,
    request_id: str,
    payload: Any,
) -> None:
    key = payload.get("equipment_id") if isinstance(payload, dict) else None
    key = key or request_id
    try:
        producer.send(topic, key=key, value=payload).get(timeout=_kafka_publish_timeout_seconds())
        if topic == _retry_topic():
            _observe_retry_published()
        elif topic == _dlq_topic():
            _observe_dlq_published()
    except KafkaError as exc:
        if topic == _retry_topic():
            error_type = ErrorType.RETRY_PUBLISH_ERROR
        elif topic == _dlq_topic():
            error_type = ErrorType.DLQ_PUBLISH_ERROR
        else:
            error_type = ErrorType.KAFKA_PUBLISH_ERROR
        raise PipelinePublishError(error_type, str(exc)) from exc


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
        record.key or "unknown",
        remaining_seconds,
        next_attempt_at,
    )
    time.sleep(sleep_seconds)
    return True


def _create_predict_client() -> httpx.Client:
    return httpx.Client(
        timeout=_kserve_timeout_seconds(),
        limits=httpx.Limits(max_connections=100, max_keepalive_connections=100),
    )


def _process_message(payload: dict[str, Any], predict_client: httpx.Client) -> dict[str, Any]:
    _validate_payload(payload)
    predictor_payload = {
        "request_id": payload.get("request_id", ""),
        "factory_id": payload.get("factory_id", ""),
        "equipment_id": payload.get("equipment_id", ""),
        "timestamp": payload.get("timestamp"),
        "inputs": payload.get("inputs", []),
    }
    response = predict_client.post(_predict_url(), json=predictor_payload)
    response.raise_for_status()
    result = response.json()

    predictions = result.get("predictions")
    if not isinstance(predictions, list) or not predictions:
        raise KServeBadResponseError("predictor response missing predictions")
    first_prediction = predictions[0]
    if not isinstance(first_prediction, dict) or not first_prediction.get("class_name"):
        raise KServeBadResponseError("predictor response missing class_name")
    return result


def _run_worker_loop(worker_index: int) -> None:
    logger.info(
        "worker started worker_index=%s bootstrap_servers=%s subscribed_topics=%s dlq_topic=%s consumer_group=%s results_table=%s retry_schedule_seconds=%s retry_jitter_seconds=%s",
        worker_index,
        _bootstrap_servers(),
        ",".join(_subscribed_topics()),
        _dlq_topic(),
        _consumer_group(),
        _results_table_name(),
        ",".join(str(value) for value in _retry_backoff_schedule_seconds()),
        _retry_jitter_seconds(),
    )
    consumer = _create_consumer(worker_index)
    producer = _create_producer(worker_index)
    results_table = _create_results_table()
    predict_client = _create_predict_client()

    try:
        while True:
            records_map = consumer.poll(timeout_ms=1000, max_records=10)
            should_continue_polling = True
            for _, records in records_map.items():
                for record in records:
                    payload = record.value
                    payload_dict = payload if isinstance(payload, dict) else {}
                    request_id = payload_dict.get("request_id") or record.key or "unknown"
                    retry_count = int(payload_dict.get("retry_count", 0) or 0)
                    next_attempt_at = int(payload_dict.get("next_attempt_at", 0) or 0)

                    try:
                        if _defer_retry_record(consumer, record, next_attempt_at):
                            should_continue_polling = False
                            break

                        result = _process_message(payload, predict_client)
                        prediction = result["predictions"][0]["class_name"]

                        completed_at = _save_result(
                            results_table,
                            request_id=request_id,
                            factory_id=payload.get("factory_id", ""),
                            equipment_id=payload.get("equipment_id", ""),
                            prediction=prediction,
                            requested_at=payload.get("timestamp", 0),
                        )
                        _observe_end_to_end_latency(payload.get("timestamp", 0), completed_at)
                        _observe_pipeline_completed()

                        consumer.commit()
                        logger.info(
                            "inference completed request_id=%s equipment_id=%s prediction=%s",
                            request_id,
                            payload.get("equipment_id"),
                            prediction,
                        )
                    except InvalidInferenceRequestError as exc:
                        failure_payload = _build_failure_payload(
                            payload_dict,
                            error_message=str(exc),
                            retry_count=retry_count,
                            source_topic=record.topic,
                            failure_stage="payload-validation",
                        )
                        _publish(producer, _dlq_topic(), request_id, failure_payload)
                        consumer.commit()
                        logger.warning(
                            "routed invalid inference request to dlq request_id=%s error_type=%s error=%s",
                            request_id,
                            ErrorType.INVALID_INFERENCE_REQUEST,
                            exc,
                        )
                    except KServeBadResponseError as exc:
                        failure_payload = _build_failure_payload(
                            payload_dict,
                            error_message=str(exc),
                            retry_count=retry_count,
                            source_topic=record.topic,
                            failure_stage="predictor-response",
                        )
                        _publish(producer, _dlq_topic(), request_id, failure_payload)
                        consumer.commit()
                        logger.warning(
                            "routed invalid predictor response to dlq request_id=%s error_type=%s error=%s",
                            request_id,
                            ErrorType.KSERVE_BAD_RESPONSE,
                            exc,
                        )
                    except httpx.HTTPError as exc:
                        error_type = _classify_http_error(exc)
                        next_retry_count = retry_count + 1
                        failure_payload = _build_failure_payload(
                            payload_dict,
                            error_message=str(exc),
                            retry_count=next_retry_count,
                            source_topic=record.topic,
                            failure_stage="predictor-http",
                        )

                        if _is_retryable_error(error_type) and next_retry_count <= _max_retry_count():
                            failure_payload["next_attempt_at"] = _compute_next_attempt_at(next_retry_count)
                            _publish(producer, _retry_topic(), request_id, failure_payload)
                            logger.warning(
                                "published retry message request_id=%s error_type=%s retry_count=%s",
                                request_id,
                                error_type,
                                next_retry_count,
                            )
                        else:
                            _publish(producer, _dlq_topic(), request_id, failure_payload)
                            logger.warning(
                                "published dlq message request_id=%s error_type=%s retry_count=%s",
                                request_id,
                                error_type,
                                next_retry_count,
                            )

                        consumer.commit()
                    except RuntimeError as exc:
                        error_type_text, _, error_message = str(exc).partition(": ")
                        error_type = ErrorType(error_type_text)
                        next_retry_count = retry_count + 1
                        failure_payload = _build_failure_payload(
                            payload_dict,
                            error_message=error_message or str(exc),
                            retry_count=next_retry_count,
                            source_topic=record.topic,
                            failure_stage="result-storage",
                        )
                        if _is_retryable_error(error_type) and next_retry_count <= _max_retry_count():
                            failure_payload["next_attempt_at"] = _compute_next_attempt_at(next_retry_count)
                            _publish(producer, _retry_topic(), request_id, failure_payload)
                            logger.warning(
                                "published retry after storage error request_id=%s error_type=%s retry_count=%s error=%s",
                                request_id,
                                error_type,
                                next_retry_count,
                                error_message or str(exc),
                            )
                        else:
                            _publish(producer, _dlq_topic(), request_id, failure_payload)
                            logger.warning(
                                "published dlq after storage/auth error request_id=%s error_type=%s retry_count=%s error=%s",
                                request_id,
                                error_type,
                                next_retry_count,
                                error_message or str(exc),
                            )
                        consumer.commit()
                    except PipelinePublishError as exc:
                        logger.exception(
                            "critical pipeline publish failure request_id=%s error_type=%s",
                            request_id,
                            exc.error_type,
                        )
                    except Exception as exc:  # noqa: BLE001
                        failure_payload = _build_failure_payload(
                            payload_dict,
                            error_message=str(exc),
                            retry_count=retry_count,
                            source_topic=record.topic,
                            failure_stage="worker-unhandled",
                        )
                        _publish(producer, _dlq_topic(), request_id, failure_payload)
                        consumer.commit()
                        logger.exception(
                            "worker failed and routed to dlq request_id=%s error_type=%s",
                            request_id,
                            ErrorType.UNHANDLED_WORKER_ERROR,
                        )
                if not should_continue_polling:
                    break
    finally:
        consumer.close()
        predict_client.close()
        producer.flush()
        producer.close()


def run() -> None:
    concurrency = _worker_concurrency()
    logger.info("starting inference-worker concurrency=%s", concurrency)
    _start_metrics_server()
    if concurrency == 1:
        _run_worker_loop(0)
        return

    threads = []
    for worker_index in range(concurrency):
        thread = threading.Thread(
            target=_run_worker_loop,
            args=(worker_index,),
            name=f"inference-worker-{worker_index}",
            daemon=False,
        )
        thread.start()
        threads.append(thread)

    for thread in threads:
        thread.join()


if __name__ == "__main__":
    run()
