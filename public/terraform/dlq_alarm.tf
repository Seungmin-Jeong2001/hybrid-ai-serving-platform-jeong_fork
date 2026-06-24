locals {
  enable_dlq_alert_webhook = trimspace(var.dlq_alert_slack_webhook_url) != ""
}

resource "aws_security_group" "dlq_alert_lambda" {
  count = local.enable_dlq_alert_webhook ? 1 : 0

  name        = "${var.project_name}-dlq-alert-lambda-sg"
  description = "Security group for the DLQ alert Lambda"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-dlq-alert-lambda-sg"
  })
}

data "archive_file" "dlq_alarm_lambda" {
  count = local.enable_dlq_alert_webhook ? 1 : 0

  type        = "zip"
  source_file = "${path.module}/dlq_alarm_lambda.py"
  output_path = "${path.module}/dlq_alarm_lambda.zip"
}

data "aws_iam_policy_document" "dlq_alarm_lambda_assume" {
  count = local.enable_dlq_alert_webhook ? 1 : 0

  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "dlq_alarm_lambda" {
  count = local.enable_dlq_alert_webhook ? 1 : 0

  name               = "${var.project_name}-dlq-alarm-lambda"
  assume_role_policy = data.aws_iam_policy_document.dlq_alarm_lambda_assume[0].json

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "dlq_alarm_lambda_basic" {
  count = local.enable_dlq_alert_webhook ? 1 : 0

  role       = aws_iam_role.dlq_alarm_lambda[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "dlq_alarm_lambda_vpc_access" {
  count = local.enable_dlq_alert_webhook ? 1 : 0

  role       = aws_iam_role.dlq_alarm_lambda[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy_attachment" "dlq_alarm_lambda_msk_execution" {
  count = local.enable_dlq_alert_webhook ? 1 : 0

  role       = aws_iam_role.dlq_alarm_lambda[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaMSKExecutionRole"
}

data "aws_iam_policy_document" "dlq_alarm_lambda_runtime" {
  count = local.enable_dlq_alert_webhook ? 1 : 0

  statement {
    effect = "Allow"
    actions = [
      "cloudwatch:GetMetricData",
      "cloudwatch:GetMetricStatistics",
      "cloudwatch:ListMetrics",
    ]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "eks:DescribeCluster",
    ]
    resources = [aws_eks_cluster.main.arn]
  }

  statement {
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "dlq_alarm_lambda_runtime" {
  count = local.enable_dlq_alert_webhook ? 1 : 0

  name   = "${var.project_name}-incident-copilot-runtime"
  role   = aws_iam_role.dlq_alarm_lambda[0].id
  policy = data.aws_iam_policy_document.dlq_alarm_lambda_runtime[0].json
}

resource "aws_eks_access_entry" "dlq_alarm_lambda" {
  count = local.enable_dlq_alert_webhook ? 1 : 0

  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_iam_role.dlq_alarm_lambda[0].arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "dlq_alarm_lambda_view" {
  count = local.enable_dlq_alert_webhook ? 1 : 0

  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_iam_role.dlq_alarm_lambda[0].arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.dlq_alarm_lambda]
}

resource "aws_lambda_function" "dlq_alarm" {
  count = local.enable_dlq_alert_webhook ? 1 : 0

  function_name    = "${var.project_name}-dlq-alarm-webhook"
  role             = aws_iam_role.dlq_alarm_lambda[0].arn
  runtime          = "python3.11"
  handler          = "dlq_alarm_lambda.handler"
  filename         = data.archive_file.dlq_alarm_lambda[0].output_path
  source_code_hash = data.archive_file.dlq_alarm_lambda[0].output_base64sha256
  timeout          = 30

  vpc_config {
    subnet_ids         = aws_subnet.eks_private[*].id
    security_group_ids = [aws_security_group.dlq_alert_lambda[0].id]
  }

  environment {
    variables = {
      SLACK_WEBHOOK_URL     = var.dlq_alert_slack_webhook_url
      PROJECT_NAME          = var.project_name
      ENVIRONMENT           = var.environment != "" ? var.environment : "public"
      DLQ_TOPIC_NAME        = var.dlq_alert_topic_name
      EKS_CLUSTER_NAME      = aws_eks_cluster.main.name
      EKS_NAMESPACE         = "inference"
      WORKER_SELECTOR       = "app=inference-worker"
      PREDICTOR_SELECTOR    = "serving.kserve.io/inferenceservice=pdm"
      BEDROCK_MODEL_ID      = var.incident_copilot_bedrock_model_id
      MSK_CLUSTER_NAME      = aws_msk_cluster.main.cluster_name
      REQUEST_TOPIC_NAME    = "inference-request"
      RETRY_TOPIC_NAME      = "inference-retry"
      WORKER_CONSUMER_GROUP = "inference-worker-group"
    }
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-dlq-alarm-webhook"
  })

  depends_on = [aws_eks_access_policy_association.dlq_alarm_lambda_view]
}

resource "aws_lambda_event_source_mapping" "dlq_alarm_msk" {
  count = local.enable_dlq_alert_webhook ? 1 : 0

  event_source_arn  = aws_msk_cluster.main.arn
  function_name     = aws_lambda_function.dlq_alarm[0].arn
  topics            = [var.dlq_alert_topic_name]
  batch_size        = 1
  starting_position = "LATEST"
}
