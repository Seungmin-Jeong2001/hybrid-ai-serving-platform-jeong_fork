# Kafka Exporter

`Kafka Consumer Lag` metric collection for the MSK-backed inference pipeline.

## Purpose

This exporter exposes Prometheus metrics such as:

- `kafka_consumergroup_lag`
- `kafka_topic_partition_current_offset`

These are used by the service dashboard for:

- `Kafka Consumer Lag Trend`
- `DLQ Count` (if topic-based offset metrics are used)

## Configuration

Generate [`values.generated.yaml`](C:\git_clone\hybrid-ai-serving-platform\sre-monitoring\kafka-exporter\values.generated.yaml) from Terraform output:

```powershell
powershell -ExecutionPolicy Bypass -File .\sre-monitoring\kafka-exporter\generate-values.ps1
```

The script reads:

- `public/terraform/outputs.tf` -> `msk_bootstrap_brokers`

The current platform uses:

- TLS broker endpoint
- Port `9094`
- No SASL config in app runtime

## Deploy

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

powershell -ExecutionPolicy Bypass -File .\sre-monitoring\kafka-exporter\generate-values.ps1

helm upgrade --install kafka-exporter prometheus-community/prometheus-kafka-exporter \
  -n monitoring \
  -f sre-monitoring/kafka-exporter/values.generated.yaml
```

## Example PromQL

Consumer lag for inference requests:

```promql
sum(kafka_consumergroup_lag{topic="inference-request"})
```

Consumer lag by group:

```promql
sum by (consumergroup) (kafka_consumergroup_lag{topic="inference-request"})
```
