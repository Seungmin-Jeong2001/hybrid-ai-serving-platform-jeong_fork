output "gitlab_oidc_provider_arn" {
  description = "ARN of the AWS IAM OIDC provider for GitLab."
  value       = aws_iam_openid_connect_provider.gitlab.arn
}

output "gitlab_ecr_promotion_role_arn" {
  description = "ARN of the IAM role assumed by GitLab CI for ECR promotion."
  value       = aws_iam_role.gitlab_ecr_promotion.arn
}

output "gitlab_ecr_promotion_role_arn_variable_name" {
  description = "GitLab CI/CD variable name that should store the ECR promotion role ARN."
  value       = "GITLAB_ECR_PROMOTION_ROLE_ARN"
}

output "aws_role_arn_gitlab_variable" {
  description = "Backward-compatible output for older references. Prefer gitlab_ecr_promotion_role_arn."
  value       = aws_iam_role.gitlab_ecr_promotion.arn
}
