import asyncio
import json
import logging
import os
import random
import time
import uuid
from pathlib import Path

import httpx
import pandas as pd

API_URL = os.getenv("API_URL", "http://your-api-server/infer")
DATA_PATH = Path(os.getenv("DATA_PATH", "/data/normal.csv"))
FACTORY_ID = os.getenv("FACTORY_ID", "FAB-01")
EQUIPMENT_COUNT = int(os.getenv("EQUIPMENT_COUNT", "100"))
WINDOW_SIZE = int(os.getenv("WINDOW_SIZE", "1000"))
INTERVAL_SEC = float(os.getenv("INTERVAL_SEC", "1.0"))
REQUEST_TIMEOUT_SEC = float(os.getenv("REQUEST_TIMEOUT_SEC", "10"))
MAX_CONCURRENCY = int(os.getenv("MAX_CONCURRENCY", str(EQUIPMENT_COUNT)))

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger("edge-simulator")


def load_normal_data():
    return pd.read_csv(
        DATA_PATH,
        header=None,
        names=["time", "sensor1", "sensor2", "sensor3", "sensor4"],
    )


def create_equipment_offsets(df):
    max_start = len(df) - WINDOW_SIZE
    if max_start <= 0:
        raise ValueError("normal.csv is smaller than WINDOW_SIZE.")
    return {
        f"EQ-{i:03d}": random.randint(0, max_start)
        for i in range(1, EQUIPMENT_COUNT + 1)
    }


def build_inference_request(df, equipment_id, start_idx):
    window = df.iloc[start_idx:start_idx + WINDOW_SIZE].reset_index(drop=True)
    inputs = []
    for i, row in window.iterrows():
        inputs.append({
            "time": round(i * 0.001, 3),
            "sensor1": float(row["sensor1"]),
            "sensor2": float(row["sensor2"]),
            "sensor3": float(row["sensor3"]),
            "sensor4": float(row["sensor4"]),
        })

    return {
        "request_id": str(uuid.uuid4()),
        "factory_id": FACTORY_ID,
        "equipment_id": equipment_id,
        "timestamp": int(time.time() * 1000),
        "inputs": inputs,
    }


async def send_request_async(client, semaphore, equipment_id, payload):
    async with semaphore:
        try:
            response = await client.post(
                API_URL,
                headers={"Content-Type": "application/json"},
                content=json.dumps(payload),
                timeout=REQUEST_TIMEOUT_SEC,
            )
            response.raise_for_status()
            logger.info(
                "sent equipment_id=%s request_id=%s timestamp=%s",
                equipment_id,
                payload["request_id"],
                payload["timestamp"],
            )
        except Exception as exc:  # noqa: BLE001
            logger.exception("failed equipment_id=%s error=%s", equipment_id, exc)


async def main():
    df = load_normal_data()
    offsets = create_equipment_offsets(df)
    equipment_ids = list(offsets.keys())
    semaphore = asyncio.Semaphore(MAX_CONCURRENCY)
    cadence_sec = INTERVAL_SEC / EQUIPMENT_COUNT
    in_flight_tasks: set[asyncio.Task] = set()
    sent_since_log = 0
    log_started_at = time.perf_counter()

    logger.info("loaded data path=%s rows=%s", DATA_PATH, len(df))
    logger.info(
        "simulator config api_url=%s factory_id=%s equipment_count=%s window_size=%s interval_sec=%s cadence_sec=%s max_concurrency=%s target_rps=%s",
        API_URL,
        FACTORY_ID,
        EQUIPMENT_COUNT,
        WINDOW_SIZE,
        INTERVAL_SEC,
        round(cadence_sec, 4),
        MAX_CONCURRENCY,
        round(EQUIPMENT_COUNT / INTERVAL_SEC, 2),
    )

    limits = httpx.Limits(
        max_connections=MAX_CONCURRENCY,
        max_keepalive_connections=MAX_CONCURRENCY,
    )
    async with httpx.AsyncClient(limits=limits) as client:
        next_send_at = time.perf_counter()
        while True:

            # 모든 장비 요청을 병렬로 전송
            for equipment_id in equipment_ids:
                now = time.perf_counter()
                sleep_time = next_send_at - now
                if sleep_time > 0:
                    await asyncio.sleep(sleep_time)

                offset = offsets[equipment_id]
                payload = build_inference_request(df, equipment_id, offset)
                task = asyncio.create_task(
                    send_request_async(client, semaphore, equipment_id, payload)
                )
                in_flight_tasks.add(task)
                task.add_done_callback(in_flight_tasks.discard)
                sent_since_log += 1

                offsets[equipment_id] += WINDOW_SIZE
                if offsets[equipment_id] + WINDOW_SIZE >= len(df):
                    offsets[equipment_id] = random.randint(0, len(df) - WINDOW_SIZE)

                next_send_at += cadence_sec

                log_elapsed = time.perf_counter() - log_started_at
                if log_elapsed >= 1.0:
                    achieved_rps = round(sent_since_log / log_elapsed, 2)
                    logger.info(
                        "steady window sent=%s elapsed_sec=%.3f achieved_rps=%s inflight=%s",
                        sent_since_log,
                        log_elapsed,
                        achieved_rps,
                        len(in_flight_tasks),
                    )
                    sent_since_log = 0
                    log_started_at = time.perf_counter()


if __name__ == "__main__":
    asyncio.run(main())
