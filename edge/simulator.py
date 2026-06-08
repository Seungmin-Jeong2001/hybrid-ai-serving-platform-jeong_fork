import json
import logging
import os
import random
import time
import uuid
from pathlib import Path

import pandas as pd
import requests

API_URL = os.getenv("API_URL", "http://your-api-server/infer")
DATA_PATH = Path(os.getenv("DATA_PATH", "/data/normal.csv"))
FACTORY_ID = os.getenv("FACTORY_ID", "FAB-01")
EQUIPMENT_COUNT = int(os.getenv("EQUIPMENT_COUNT", "100"))
WINDOW_SIZE = int(os.getenv("WINDOW_SIZE", "1000"))
INTERVAL_SEC = float(os.getenv("INTERVAL_SEC", "1.0"))
REQUEST_TIMEOUT_SEC = float(os.getenv("REQUEST_TIMEOUT_SEC", "10"))

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

def send_request(session, payload):
    response = session.post(
        API_URL,
        headers={"Content-Type": "application/json"},
        data=json.dumps(payload),
        timeout=REQUEST_TIMEOUT_SEC,
    )
    response.raise_for_status()
    return response

def main():
    df = load_normal_data()
    offsets = create_equipment_offsets(df)
    session = requests.Session()
    logger.info("loaded data path=%s rows=%s", DATA_PATH, len(df))
    logger.info(
        "simulator config api_url=%s factory_id=%s equipment_count=%s window_size=%s interval_sec=%s",
        API_URL,
        FACTORY_ID,
        EQUIPMENT_COUNT,
        WINDOW_SIZE,
        INTERVAL_SEC,
    )

    while True:
        start_time = time.time()
        for equipment_id, offset in offsets.items():
            payload = build_inference_request(df, equipment_id, offset)
            try:
                send_request(session, payload)
                logger.info(
                    "sent equipment_id=%s request_id=%s timestamp=%s",
                    equipment_id,
                    payload["request_id"],
                    payload["timestamp"],
                )
            except Exception as exc:  # noqa: BLE001
                logger.exception("failed equipment_id=%s error=%s", equipment_id, exc)
            offsets[equipment_id] += WINDOW_SIZE
            if offsets[equipment_id] + WINDOW_SIZE >= len(df):
                offsets[equipment_id] = random.randint(
                    0,
                    len(df) - WINDOW_SIZE,
                )
        elapsed = time.time() - start_time
        sleep_time = max(0, INTERVAL_SEC - elapsed)
        time.sleep(sleep_time)

if __name__ == "__main__":
    main()
