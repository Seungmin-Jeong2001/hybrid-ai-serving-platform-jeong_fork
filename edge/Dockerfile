FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY simulator.py .

RUN mkdir -p /data

ENV DATA_PATH=/data/normal.csv

CMD ["python", "simulator.py"]
