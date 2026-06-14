# Network outputs
output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets"
  value       = aws_subnet.public[*].id
}

output "eks_private_subnet_ids" {
  description = "IDs of the EKS private subnets"
  value       = aws_subnet.eks_private[*].id
}

output "msk_private_subnet_ids" {
  description = "IDs of the MSK private subnets"
  value       = aws_subnet.msk_private[*].id
}

output "nat_gateway_id" {
  description = "ID of the single NAT gateway"
  value       = aws_nat_gateway.main.id
}

# Data store outputs
output "dynamodb_table_name" {
  description = "Inference jobs DynamoDB table name"
  value       = aws_dynamodb_table.inference_results.name
}

output "dynamodb_alert_state_table_name" {
  description = "Equipment alert state DynamoDB table name"
  value       = aws_dynamodb_table.equipment_alert_state.name
}

output "ses_alert_sender_email" {
  description = "SES alert sender email"
  value       = var.ses_alert_sender_email
}

output "ses_alert_recipient_email" {
  description = "SES alert recipient email"
  value       = var.ses_alert_recipient_email
}

output "account_id" {
  description = "AWS account ID"
  value       = data.aws_caller_identity.current.account_id
}

# IRSA outputs
output "inference_worker_role_arn" {
  description = "IAM role ARN for the inference-worker service account (IRSA)"
  value       = aws_iam_role.inference_worker.arn
}

output "dashboard_backend_role_arn" {
  description = "IAM role ARN for the dashboard-backend service account (IRSA)"
  value       = aws_iam_role.dashboard_backend.arn
}

output "ebs_csi_driver_role_arn" {
  description = "IAM role ARN used by the EBS CSI driver add-on"
  value       = aws_iam_role.ebs_csi.arn
}

output "aws_load_balancer_controller_role_arn" {
  description = "IAM role ARN for the aws-load-balancer-controller service account (IRSA)"
  value       = aws_iam_role.aws_load_balancer_controller.arn
}

output "eks_bootstrap_admin_role_arn" {
  description = "IAM role ARN used by bootstrap workflows to register the Argo CD root application"
  value       = aws_iam_role.eks_bootstrap_admin.arn
}

# Container and cluster outputs
output "ecr_repository_urls" {
  description = "ECR repository URLs"
  value       = { for name, repo in aws_ecr_repository.repos : name => repo.repository_url }
}

output "eks_cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.main.name
}

output "eks_cluster_endpoint" {
  description = "EKS cluster endpoint"
  value       = aws_eks_cluster.main.endpoint
}

output "eks_oidc_issuer" {
  description = "OIDC issuer URL for the EKS cluster"
  value       = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

output "eks_node_group_names" {
  description = "EKS managed node group names keyed by workload"
  value       = { for k, ng in aws_eks_node_group.workloads : k => ng.node_group_name }
}

# MSK outputs
output "msk_cluster_arn" {
  description = "MSK cluster ARN"
  value       = aws_msk_cluster.main.arn
}

output "msk_bootstrap_brokers" {
  description = "TLS bootstrap brokers for the MSK cluster"
  value       = aws_msk_cluster.main.bootstrap_brokers_tls
}

output "manage_msk_topics" {
  description = "Whether MSK topics should be reconciled by the CI workflow"
  value       = var.manage_msk_topics
}

output "msk_topic_replication_factor" {
  description = "Replication factor to use when creating MSK topics"
  value       = var.msk_topic_replication_factor
}

output "msk_topic_configs" {
  description = "Topic-level configuration to apply to managed MSK topics"
  value       = var.msk_topic_configs
}

output "msk_topics" {
  description = "Managed MSK topics and their desired partition counts"
  value       = var.msk_topics
}

# S3 outputs
output "artifacts_s3_bucket_name" {
  description = "Shared artifacts S3 bucket name"
  value       = aws_s3_bucket.artifacts.bucket
}

# VPC endpoint outputs
output "s3_gateway_endpoint_id" {
  description = "S3 gateway VPC endpoint ID"
  value       = aws_vpc_endpoint.s3.id
}

# S3 Interface VPCE 비활성화됨 - endpoints.tf 참고
# output "s3_interface_endpoint_id" {
#   description = "S3 interface VPC endpoint ID (used by on-premise traffic over VPN)"
#   value       = aws_vpc_endpoint.s3_interface.id
# }

# VPN outputs
output "vpn_gateway_id" {
  description = "VPN gateway ID"
  value       = try(aws_vpn_gateway.main[0].id, null)
}

output "customer_gateway_ids" {
  description = "Customer gateway IDs keyed by site name"
  value       = { for k, cgw in aws_customer_gateway.sites : k => cgw.id }
}

output "vpn_connection_ids" {
  description = "Site-to-Site VPN connection IDs keyed by site name"
  value       = { for k, vpn in aws_vpn_connection.sites : k => vpn.id }
}

# Route 53 Resolver outputs
# 비활성화됨 - route53_resolver.tf 참고
# output "inbound_resolver_ips" {
#   description = "Inbound Route 53 Resolver IPs for forwarding *.amazonaws.com and private hosted zones"
#   value       = [for ip in aws_route53_resolver_endpoint.inbound.ip_address : ip.ip]
# }
