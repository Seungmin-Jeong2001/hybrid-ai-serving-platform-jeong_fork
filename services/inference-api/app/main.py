import json
import logging
import os
from contextlib import asynccontextmanager
from typing import Any
from uuid import uuid4

from fastapi import FastAPI, HTTPException
from kafka import KafkaProducer
from kafka.errors import KafkaError
from pydantic import BaseModel, Field


logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger("inference-api")

producer: KafkaProducer | None = None


def _bootstrap_servers() -> str:
    value = os.getenv("BOOTSTRAP_SERVERS", "").strip()
    if not value or value == "replace-me:9092":
        raise RuntimeError("BOOTSTRAP_SERVERS must be configured")
    return value


def _request_topic() -> str:
    return os.getenv("REQUEST_TOPIC", "inference-request")


def _create_producer() -> KafkaProducer:
    return KafkaProducer(
        bootstrap_servers=_bootstrap_servers(),
        client_id=os.getenv("KAFKA_PRODUCER_CLIENT_ID", "inference-api"),
        acks="all",
        enable_idempotence=True,
        retries=3,
        value_serializer=lambda value: json.dumps(value).encode("utf-8"),
        key_serializer=lambda value: value.encode("utf-8"),
    )


class InferenceRequest(BaseModel):
    request_id: str | None = None
    inputs: list[Any] = Field(default_factory=list)
    parameters: dict[str, Any] = Field(default_factory=dict)


@asynccontextmanager
async def lifespan(_: FastAPI):
    global producer

    producer = _create_producer()
    logger.info(
        "request producer ready bootstrap_servers=%s request_topic=%s",
        _bootstrap_servers(),
        _request_topic(),
    )
    try:
        yield
    finally:
        if producer is not None:
            producer.flush()
            producer.close()


app = FastAPI(title="inference-api", version="0.1.0", lifespan=lifespan)


@app.get("/healthz")
async def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/infer")
async def infer(request: InferenceRequest) -> dict[str, Any]:
    if producer is None:
        raise HTTPException(status_code=503, detail="kafka producer is not ready")

    job_id = request.request_id or str(uuid4())
    payload = {
        "request_id": job_id,
        "job_id": job_id,
        "inputs": request.inputs,
        "parameters": request.parameters,
        "retry_count": 0,
        "source_topic": _request_topic(),
    }

    try:
        future = producer.send(_request_topic(), key=job_id, value=payload)
        record_metadata = future.get(timeout=30)
    except KafkaError as exc:
        logger.exception("failed to publish inference request: %s", exc)
        raise HTTPException(status_code=502, detail="failed to publish inference request") from exc

    return {
        "status": "accepted",
        "job_id": job_id,
        "request_topic": record_metadata.topic,
        "partition": record_metadata.partition,
        "offset": record_metadata.offset,
    }
