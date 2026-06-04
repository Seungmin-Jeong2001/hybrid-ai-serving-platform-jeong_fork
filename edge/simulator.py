import json
import time
import uuid
import random
from pathlib import Path

import pandas as pd
import requests


API_URL = "https://your-api-server.com/inference-requests"
DATA_PATH = Path("./simulator_data/normal.csv")

EQUIPMENT_COUNT = 100
WINDOW_SIZE = 1000
INTERVAL_SEC = 1.0

FACTORY_ID = "FAB-01"


def load_normal_data():
    # CSV 구조: time, sensor1, sensor2, sensor3, sensor4
    # 컬럼명 없이 저장된 파일 기준
    return pd.read_csv(
        DATA_PATH,
        header=None,
        names=["time", "sensor1", "sensor2", "sensor3", "sensor4"]
    )


def create_equipment_offsets(df):
    max_start = len(df) - WINDOW_SIZE

    if max_start <= 0:
        raise ValueError("normal.csv 행 수가 WINDOW_SIZE보다 작습니다.")

    return {
        f"EQ-{i:03d}": random.randint(0, max_start)
        for i in range(1, EQUIPMENT_COUNT + 1)
    }


def build_inference_request(df, equipment_id, start_idx):
    window = df.iloc[start_idx:start_idx + WINDOW_SIZE].reset_index(drop=True)

    samples = []

    for i, row in window.iterrows():
        samples.append({
            "time": round(i * 0.001, 3),  # 상대시간 (0 ~ 0.999초)
            "sensor1": float(row["sensor1"]),
            "sensor2": float(row["sensor2"]),
            "sensor3": float(row["sensor3"]),
            "sensor4": float(row["sensor4"])
        })

    return {
        "request_id": str(uuid.uuid4()),
        "factory_id": FACTORY_ID,
        "equipment_id": equipment_id,
        "timestamp": int(time.time() * 1000),  # 요청 생성 시각(ms)
        "samples": samples
    }


def send_request(payload):
    response = requests.post(
        API_URL,
        headers={"Content-Type": "application/json"},
        data=json.dumps(payload),
        timeout=10
    )

    response.raise_for_status()
    return response


def main():
    df = load_normal_data()
    offsets = create_equipment_offsets(df)

    print(f"Loaded data: {DATA_PATH}, rows={len(df)}")
    print(f"Equipment count: {EQUIPMENT_COUNT}")
    print(f"Window size: {WINDOW_SIZE}")

    while True:
        start_time = time.time()

        for equipment_id, offset in offsets.items():
            payload = build_inference_request(df, equipment_id, offset)

            try:
                send_request(payload)
                print(
                    f"sent: {equipment_id}, "
                    f"request_id={payload['request_id']}, "
                    f"timestamp={payload['timestamp']}"
                )
            except Exception as e:
                print(f"failed: {equipment_id}, error={e}")

            # 다음 1초 window로 이동
            offsets[equipment_id] += WINDOW_SIZE

            # 끝까지 가면 다시 랜덤 위치에서 시작
            if offsets[equipment_id] + WINDOW_SIZE >= len(df):
                offsets[equipment_id] = random.randint(
                    0,
                    len(df) - WINDOW_SIZE
                )

        elapsed = time.time() - start_time
        sleep_time = max(0, INTERVAL_SEC - elapsed)

        time.sleep(sleep_time)


if __name__ == "__main__":
    main()