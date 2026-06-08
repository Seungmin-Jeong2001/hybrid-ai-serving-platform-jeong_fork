variable "aws_region" {
  description = "AWS region for the in-cluster Terraform stack"
  type        = string
  default     = "ap-northeast-2"
}

variable "argocd_chart_version" {
  description = "Argo CD Helm chart version"
  type        = string
  default     = "7.8.23"
}
