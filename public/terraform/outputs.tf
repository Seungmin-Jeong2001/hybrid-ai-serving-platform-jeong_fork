# 네트워크 출력
output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs of the EKS private subnets"
  value       = aws_subnet.eks_private[*].id
}

output "eks_private_subnet_ids" {
  description = "IDs of the EKS private subnets"
  value       = aws_subnet.eks_private[*].id
}

output "msk_private_subnet_ids" {
  description = "IDs of the MSK private subnets"
  value       = aws_subnet.msk_private[*].id
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

# VPN 출력
output "vpn_gateway_id" {
  description = "VPN gateway ID"
  value       = try(aws_vpn_gateway.main[0].id, null)
}

output "customer_gateway_id" {
  description = "Customer gateway ID"
  value       = try(aws_customer_gateway.main[0].id, null)
}

output "vpn_connection_id" {
  description = "Site-to-Site VPN connection ID"
  value       = try(aws_vpn_connection.main[0].id, null)
}
