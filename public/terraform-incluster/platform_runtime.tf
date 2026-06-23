resource "kubernetes_namespace" "inference" {
  metadata {
    name = "inference"
  }
  # lifecycle ignore_changes로 ArgoCD가 추가하는 annotation/label 무시
  lifecycle {
    ignore_changes = [metadata[0].annotations, metadata[0].labels]
  }
}

resource "kubernetes_config_map" "inference_config" {
  metadata {
    name      = "inference-config"
    namespace = kubernetes_namespace.inference.metadata[0].name
  }

  depends_on = [kubernetes_namespace.inference]

  data = {
    BOOTSTRAP_SERVERS       = data.terraform_remote_state.platform.outputs.msk_bootstrap_brokers
    KAFKA_TLS               = "enable"
    KAFKA_SECURITY_PROTOCOL = "SSL"
    DYNAMODB_TABLE_NAME     = data.terraform_remote_state.platform.outputs.dynamodb_table_name
    ALERT_STATE_TABLE_NAME  = data.terraform_remote_state.platform.outputs.dynamodb_alert_state_table_name
    SES_SENDER_EMAIL        = data.terraform_remote_state.platform.outputs.ses_alert_sender_email
    SES_RECIPIENT_EMAIL     = data.terraform_remote_state.platform.outputs.ses_alert_recipient_email
  }
}

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.13.4"
  namespace  = "kube-system"
  wait       = true
  timeout    = 900

  values = [
    yamlencode({
      clusterName = data.terraform_remote_state.platform.outputs.eks_cluster_name
      region      = var.aws_region
      vpcId       = data.terraform_remote_state.platform.outputs.vpc_id
      serviceAccount = {
        create = true
        name   = "aws-load-balancer-controller"
        annotations = {
          "eks.amazonaws.com/role-arn" = data.terraform_remote_state.platform.outputs.aws_load_balancer_controller_role_arn
        }
      }
      nodeSelector = {
        workload = "general"
      }
    })
  ]
}

resource "time_sleep" "wait_for_aws_load_balancer_controller_webhook" {
  depends_on      = [helm_release.aws_load_balancer_controller]
  create_duration = "30s"
}
