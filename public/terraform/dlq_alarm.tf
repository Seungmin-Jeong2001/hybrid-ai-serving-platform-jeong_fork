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

resource "aws_security_group_rule" "dlq_alert_lambda_to_eks_api" {
  count = local.enable_dlq_alert_webhook ? 1 : 0

  type                     = "ingress"
  description              = "Allow the DLQ alert Lambda to reach the EKS private API endpoint"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  source_security_group_id = aws_security_group.dlq_alert_lambda[0].id
}

data "archive_file" "dlq_alarm_lambda" {
  count = local.enable_dlq_alert_webhook ? 1 : 0

  type        = "zip"
  source_file = "${path.module}/dlq_alarm_lambda.py"
  output_path = "${path.module}/dlq_alarm_lambda.zip"
}

data "archive_file" "incident_copilot_action_group_lambda" {
  count = local.enable_dlq_alert_webhook ? 1 : 0

  type        = "zip"
  source_file = "${path.module}/incident_copilot_action_group_lambda.py"
  output_path = "${path.module}/incident_copilot_action_group_lambda.zip"
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
      "bedrock:InvokeAgent",
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
  timeout          = 60

  vpc_config {
    subnet_ids         = aws_subnet.eks_private[*].id
    security_group_ids = [aws_security_group.dlq_alert_lambda[0].id]
  }

  environment {
    variables = {
      SLACK_WEBHOOK_URL      = var.dlq_alert_slack_webhook_url
      PROJECT_NAME           = var.project_name
      ENVIRONMENT            = var.environment != "" ? var.environment : "public"
      DLQ_TOPIC_NAME         = var.dlq_alert_topic_name
      EKS_CLUSTER_NAME       = aws_eks_cluster.main.name
      EKS_NAMESPACE          = "inference"
      WORKER_SELECTOR        = "app=inference-worker"
      PREDICTOR_SELECTOR     = "serving.kserve.io/inferenceservice=pdm"
      BEDROCK_MODEL_ID       = var.incident_copilot_bedrock_model_id
      MSK_CLUSTER_NAME       = aws_msk_cluster.main.cluster_name
      REQUEST_TOPIC_NAME     = "inference-request"
      RETRY_TOPIC_NAME       = "inference-retry"
      WORKER_CONSUMER_GROUP  = "inference-worker-group"
      BEDROCK_AGENT_ID       = try(aws_bedrockagent_agent.incident_copilot[0].id, "")
      BEDROCK_AGENT_ALIAS_ID = try(aws_bedrockagent_agent_alias.incident_copilot[0].agent_alias_id, "")
    }
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-dlq-alarm-webhook"
  })

  depends_on = [aws_eks_access_policy_association.dlq_alarm_lambda_view]
}

resource "aws_lambda_function" "incident_copilot_action_group" {
  count = local.enable_dlq_alert_webhook ? 1 : 0

  function_name    = "${var.project_name}-incident-copilot-action-group"
  role             = aws_iam_role.dlq_alarm_lambda[0].arn
  runtime          = "python3.11"
  handler          = "incident_copilot_action_group_lambda.handler"
  filename         = data.archive_file.incident_copilot_action_group_lambda[0].output_path
  source_code_hash = data.archive_file.incident_copilot_action_group_lambda[0].output_base64sha256
  timeout          = 30

  vpc_config {
    subnet_ids         = aws_subnet.eks_private[*].id
    security_group_ids = [aws_security_group.dlq_alert_lambda[0].id]
  }

  environment {
    variables = {
      EKS_CLUSTER_NAME   = aws_eks_cluster.main.name
      EKS_NAMESPACE      = "inference"
      WORKER_SELECTOR    = "app=inference-worker"
      PREDICTOR_SELECTOR = "serving.kserve.io/inferenceservice=pdm"
    }
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-incident-copilot-action-group"
  })

  depends_on = [aws_eks_access_policy_association.dlq_alarm_lambda_view]
}

data "aws_iam_policy_document" "incident_copilot_agent_assume" {
  count = local.enable_dlq_alert_webhook ? 1 : 0

  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["bedrock.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "AWS:SourceArn"
      values   = ["arn:aws:bedrock:${var.aws_region}:${data.aws_caller_identity.current.account_id}:agent/*"]
    }
  }
}

resource "aws_iam_role" "incident_copilot_agent" {
  count = local.enable_dlq_alert_webhook ? 1 : 0

  name               = "${var.project_name}-incident-copilot-agent"
  assume_role_policy = data.aws_iam_policy_document.incident_copilot_agent_assume[0].json

  tags = local.common_tags
}

data "aws_iam_policy_document" "incident_copilot_agent_runtime" {
  count = local.enable_dlq_alert_webhook ? 1 : 0

  statement {
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
      "bedrock:GetFoundationModel",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "incident_copilot_agent_runtime" {
  count = local.enable_dlq_alert_webhook ? 1 : 0

  name   = "${var.project_name}-incident-copilot-agent-runtime"
  role   = aws_iam_role.incident_copilot_agent[0].id
  policy = data.aws_iam_policy_document.incident_copilot_agent_runtime[0].json
}

resource "aws_lambda_permission" "incident_copilot_action_group_bedrock" {
  count = local.enable_dlq_alert_webhook ? 1 : 0

  statement_id   = "AllowBedrockInvokeActionGroup"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.incident_copilot_action_group[0].function_name
  principal      = "bedrock.amazonaws.com"
  source_account = data.aws_caller_identity.current.account_id
  source_arn     = "arn:aws:bedrock:${var.aws_region}:${data.aws_caller_identity.current.account_id}:agent/*"
}

resource "aws_bedrockagent_agent" "incident_copilot" {
  count = local.enable_dlq_alert_webhook ? 1 : 0

  agent_name                  = "${var.project_name}-${var.environment != "" ? var.environment : "public"}-incident-copilot"
  agent_resource_role_arn     = aws_iam_role.incident_copilot_agent[0].arn
  foundation_model            = var.incident_copilot_bedrock_model_id
  idle_session_ttl_in_seconds = 900
  instruction = join(" ", [
    "You are Inference Incident Copilot for an asynchronous inference platform.",
    "Your job is to investigate DLQ incidents by selectively invoking only the most relevant action-group functions.",
    "Do not call every function. Choose only the minimum functions required to confirm the root-cause hypothesis.",
    "Prioritize concrete evidence from Kubernetes logs, events, and deployment status.",
    "Respond only in JSON with keys likely_causes, recommended_actions, confidence.",
    "likely_causes and recommended_actions must be arrays of up to 3 complete Korean sentences.",
    "recommended_actions must name the exact component to inspect, such as predictor logs, inference-worker logs, retry topic lag, or Kubernetes warning events.",
    "If evidence is insufficient, explicitly say which evidence is missing instead of guessing.",
  ])
  prepare_agent = true

  tags = local.common_tags

  depends_on = [aws_iam_role_policy.incident_copilot_agent_runtime]
}

resource "aws_bedrockagent_agent_action_group" "incident_triage" {
  count = local.enable_dlq_alert_webhook ? 1 : 0

  action_group_name = "incident-triage"
  agent_id          = aws_bedrockagent_agent.incident_copilot[0].id
  agent_version     = "DRAFT"
  description       = "Collect targeted Kubernetes evidence for inference incidents"

  action_group_executor {
    lambda = aws_lambda_function.incident_copilot_action_group[0].arn
  }

  function_schema {
    member_functions {
      functions {
        name        = "collect_worker_logs"
        description = "Collect recent logs from the inference-worker pod"
      }
      functions {
        name        = "collect_predictor_logs"
        description = "Collect recent logs from the pdm-predictor pod"
      }
      functions {
        name        = "collect_worker_events"
        description = "Collect recent Kubernetes events related to inference-worker"
      }
      functions {
        name        = "collect_predictor_events"
        description = "Collect recent Kubernetes events related to pdm-predictor"
      }
      functions {
        name        = "collect_namespace_warning_events"
        description = "Collect recent warning events from the inference namespace"
      }
      functions {
        name        = "collect_worker_deployment_status"
        description = "Collect inference-worker deployment rollout status"
      }
      functions {
        name        = "collect_predictor_deployment_status"
        description = "Collect pdm-predictor deployment rollout status"
      }
      functions {
        name        = "collect_worker_status"
        description = "Collect aggregate readiness and restart status for inference-worker pods"
      }
      functions {
        name        = "collect_predictor_status"
        description = "Collect aggregate readiness and restart status for pdm-predictor pods"
      }
    }
  }

  depends_on = [
    aws_bedrockagent_agent.incident_copilot,
    aws_lambda_permission.incident_copilot_action_group_bedrock,
  ]
}

resource "aws_bedrockagent_agent_alias" "incident_copilot" {
  count = local.enable_dlq_alert_webhook ? 1 : 0

  agent_alias_name = "prod"
  agent_id         = aws_bedrockagent_agent.incident_copilot[0].id
  description      = "Production alias for the inference incident copilot"

  depends_on = [aws_bedrockagent_agent_action_group.incident_triage]
}

resource "aws_lambda_event_source_mapping" "dlq_alarm_msk" {
  count = local.enable_dlq_alert_webhook ? 1 : 0

  event_source_arn  = aws_msk_cluster.main.arn
  function_name     = aws_lambda_function.dlq_alarm[0].arn
  topics            = [var.dlq_alert_topic_name]
  batch_size        = 1
  starting_position = "LATEST"
}
