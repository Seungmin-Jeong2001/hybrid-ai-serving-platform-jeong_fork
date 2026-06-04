# Inference Services

This directory contains containerized application code for the three workloads
deployed into the `inference` namespace.

Official container images should be built and pushed by GitHub Actions rather
than from a developer workstation. Local `docker build` is still useful for
fast debugging, but the authoritative images should come from CI and be pushed
to ECR with the commit SHA tag.

## Services

- `inference-api`: public-facing HTTP API that forwards inference requests to the predictor
- `inference-worker`: background worker placeholder for Kafka request processing
- `kserve-predictor`: model-serving HTTP service compatible with simple JSON inference calls

`inference-api` publishes Kafka request messages with a `request_id`, and
`inference-worker` uses the DynamoDB inference jobs table for application-level
idempotency before invoking the predictor.
Retry messages carry `next_attempt_at`, and the worker applies a `10s, 30s, 60s`
backoff schedule with jitter before retry processing.

## Local build

```powershell
docker build -t inference-api:local services/inference-api
docker build -t inference-worker:local services/inference-worker
docker build -t kserve-predictor:local services/kserve-predictor
```

## ECR push example

```powershell
aws ecr get-login-password --region ap-northeast-2 |
  docker login --username AWS --password-stdin 808379768010.dkr.ecr.ap-northeast-2.amazonaws.com

docker build -t 808379768010.dkr.ecr.ap-northeast-2.amazonaws.com/inference-api:latest services/inference-api
docker push 808379768010.dkr.ecr.ap-northeast-2.amazonaws.com/inference-api:latest
```

Repeat the same pattern for `inference-worker` and `kserve-predictor`.

## GitHub Actions

The workflow at `.github/workflows/inference-images.yml` is the intended
production path.

- Pull requests build all four service images for validation only.
- Pushes to `main` build and push immutable `${GITHUB_SHA}` tags to ECR.
- Pushes to `main` also refresh the mutable `latest` tag for compatibility with
  the current Kubernetes manifests.

To activate the workflow, add the repository secret
`AWS_GITHUB_ACTIONS_ROLE_ARN` with an IAM role that trusts GitHub OIDC and has
permission to push to the four ECR repositories.

Kafka topics are managed from Terraform in `public/terraform`, not from the
application containers. Set `manage_msk_topics=true` during `terraform apply`
to reconcile the configured MSK topic names and partition counts.

Producer settings such as `acks=all` and `enable.idempotence=true` belong in
the Kafka producer application code, not in the MSK topic definition.
