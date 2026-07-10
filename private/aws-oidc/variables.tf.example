variable "aws_region" {
  description = "AWS region for the target ECR repository and IAM resources."
  type        = string
  default     = "ap-northeast-2"
}

variable "aws_account_id" {
  description = "AWS account ID that owns the IAM role and ECR repository."
  type        = string
  default     = "808379768010"
}

variable "gitlab_oidc_url" {
  description = "GitLab OIDC issuer URL."
  type        = string
  default     = "https://gitlab.intp.me"
}

variable "gitlab_oidc_host" {
  description = "Host portion of the GitLab OIDC issuer, used in IAM trust policy condition keys."
  type        = string
  default     = "gitlab.intp.me"
}

variable "gitlab_project_sub" {
  description = "Expected OIDC subject claim for the GitLab project/ref allowed to assume the role."
  type        = string
  default     = "project_path:3stacks/predictor-model:ref_type:branch:ref:main"
}

variable "role_name" {
  description = "IAM role name assumed by GitLab CI for ECR promotion."
  type        = string
  default     = "gitlab-ecr-promotion-role"
}

variable "ecr_repository_name" {
  description = "Existing ECR repository name that receives promoted images."
  type        = string
  default     = "predictive-model"
}
