# 네트워크 출력
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

# 데이터 저장소 출력
output "dynamodb_table_name" {
  description = "Inference jobs DynamoDB table name"
  value       = aws_dynamodb_table.inference_jobs.name
}

output "account_id" {
  description = "AWS account ID"
  value       = data.aws_caller_identity.current.account_id
}

# IRSA 출력 (inference-worker ServiceAccount annotation에 사용)
output "inference_worker_role_arn" {
  description = "IAM role ARN for the inference-worker service account (IRSA)"
  value       = aws_iam_role.inference_worker.arn
}

# 컨테이너 출력
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

output "ebs_csi_driver_role_arn" {
  description = "IAM role ARN used by the EBS CSI driver add-on"
  value       = aws_iam_role.ebs_csi.arn
}

output "aws_load_balancer_controller_role_arn" {
  description = "IAM role ARN for the aws-load-balancer-controller service account (IRSA)"
  value       = aws_iam_role.aws_load_balancer_controller.arn
}

output "eks_node_group_names" {
  description = "EKS managed node group names keyed by workload"
  value       = { for k, ng in aws_eks_node_group.workloads : k => ng.node_group_name }
}

# MSK 출력
output "msk_cluster_arn" {
  description = "MSK cluster ARN"
  value       = aws_msk_cluster.main.arn
}

# S3 출력
output "artifacts_s3_bucket_name" {
  description = "Shared artifacts S3 bucket name"
  value       = aws_s3_bucket.artifacts.bucket
}

# ALB 출력
output "internal_alb_arn" {
  description = "Internal ALB ARN"
  value       = aws_lb.internal.arn
}

output "internal_alb_dns_name" {
  description = "Internal ALB DNS name"
  value       = aws_lb.internal.dns_name
}

output "internal_alb_target_group_arn" {
  description = "Internal ALB target group ARN"
  value       = aws_lb_target_group.internal.arn
}

# VPC 엔드포인트 출력
output "s3_gateway_endpoint_id" {
  description = "S3 gateway VPC endpoint ID"
  value       = aws_vpc_endpoint.s3.id
}

output "s3_interface_endpoint_id" {
  description = "S3 interface VPC endpoint ID (used by on-premise traffic over VPN)"
  value       = aws_vpc_endpoint.s3_interface.id
}

# VPN 출력
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

# Route 53 Resolver 출력
output "inbound_resolver_ips" {
  description = "온프레미스 DNS 서버가 *.amazonaws.com / Private Hosted Zone 등을 forward할 대상 IP"
  value       = [for ip in aws_route53_resolver_endpoint.inbound.ip_address : ip.ip]
}
