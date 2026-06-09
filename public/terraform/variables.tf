# 공통 변수
variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "ap-northeast-2"
}

variable "project_name" {
  description = "Short project name used for AWS resource names"
  type        = string
  default     = "sgs-hasp"
}

variable "environment" {
  description = "Deployment environment name"
  type        = string
  default     = ""
}

# 네트워크 변수
variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for the three public subnets"
  type        = list(string)
  default = [
    "10.0.1.0/24",
    "10.0.2.0/24",
    "10.0.3.0/24",
  ]
}

variable "eks_private_subnet_cidrs" {
  description = "CIDR blocks for the three EKS private subnets"
  type        = list(string)
  default = [
    "10.0.11.0/24",
    "10.0.12.0/24",
    "10.0.13.0/24",
  ]
}

variable "msk_private_subnet_cidrs" {
  description = "CIDR blocks for the three MSK private subnets"
  type        = list(string)
  default = [
    "10.0.21.0/24",
    "10.0.22.0/24",
    "10.0.23.0/24",
  ]
}

variable "nat_gateway_az_index" {
  description = "Availability zone index (0=AZ-a, 1=AZ-b, 2=AZ-c) for the single NAT gateway"
  type        = number
  default     = 1
}

# ECR 리포지토리 변수
variable "ecr_repositories" {
  description = "ECR repository names"
  type        = list(string)
  default = [
    "predictive-model",
    "inference-api",
    "inference-worker",
  ]
}

# EKS 변수
variable "eks_public_access_cidrs" {
  description = "CIDR blocks allowed to access the EKS public endpoint"
  type        = list(string)
  default = [
    "221.150.194.220/32", # choi
    "125.243.10.39/32",   # shin
    "218.39.98.40/32"     # kim
  ]
}

variable "eks_cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.31"
}

variable "eks_node_groups" {
  description = "Per-workload EKS managed node group configuration"
  type = map(object({
    instance_types = list(string)
    az_count       = number # how many AZs to span (1..3); subnets are taken from eks_private in order
    desired_size   = number
    min_size       = number
    max_size       = number
    labels         = map(string)
    taints = list(object({
      key    = string
      value  = string
      effect = string
    }))
  }))
  default = {
    inference = {
      instance_types = ["t3.medium"] # 임시 비용 절감, 원래 값: m7i-flex.large (t3.small은 최대 파드 11개 한계로 변경)
      az_count       = 3
      desired_size   = 1 # ★ 원래 값 : 2 (나중에 복구) ★
      min_size       = 1
      max_size       = 10
      labels         = { workload = "inference" }
      taints         = []
    }
    app = {
      instance_types = ["t3.small"]
      az_count       = 3
      desired_size   = 0 # ★ 임시로 0 , 원래 값 : 1 (나중에 복구) ★
      min_size       = 0 # ★ 임시로 0 , 원래 값 : 1 (나중에 복구) ★
      max_size       = 10
      labels         = { workload = "app" }
      taints         = []
    }
    system = {
      instance_types = ["t3.medium"] # 임시 비용 절감, 원래 값: m7i-flex.large (ArgoCD 등 system 워크로드 메모리 요구로 small 불가)
      az_count       = 2
      desired_size   = 1 # 원래 값: 2 (나중에 복구)
      min_size       = 1 # 원래 값: 2 (나중에 복구)
      max_size       = 3
      labels         = { workload = "system" }
      taints         = []
    }
    monitoring = {
      instance_types = ["c7i-flex.large"] # 임시 비용 절감, 원래 값: m7i-flex.large
      az_count       = 1                  # 임시 비용 절감, 원래 값: 2 (나중에 복구)
      desired_size   = 0                  # 임시로 0 (비용 절감), 원래 값: 1 (나중에 복구)
      min_size       = 0                  # 임시로 0 (비용 절감), 원래 값: 1 (나중에 복구)
      max_size       = 2
      labels         = { workload = "monitoring" }
      taints         = []
    }
  }
}

# MSK 변수
variable "msk_kafka_version" {
  description = "Apache Kafka version for the MSK cluster"
  type        = string
  default     = "3.9.x"
}

variable "msk_broker_instance_type" {
  description = "Broker instance type for the MSK cluster"
  type        = string
  # NOTE: AWS MSK는 t3 계열 중 kafka.t3.small만 지원 (kafka.t3.medium 등 없음).
  # 더 안정적인 네트워크가 필요하면 kafka.m5.large 이상으로 상향할 것.
  default = "kafka.t3.small"
}

variable "msk_number_of_broker_nodes" {
  description = "Number of broker nodes for the MSK cluster"
  type        = number
  default     = 2 # 임시 비용 절감 (서브넷 2개 최소 요구사항 맞춤), 원래 값: 3 (나중에 복구)
}

variable "msk_ebs_volume_size" {
  description = "Broker EBS volume size in GiB for the MSK cluster"
  type        = number
  default     = 100 # ★ 원래 값: 1000 GiB (나중에 복구) ★
}

variable "manage_msk_topics" {
  description = "Whether Terraform should reconcile MSK topics through the AWS Kafka topic API"
  type        = bool
  default     = true
}

variable "msk_topic_replication_factor" {
  description = "Replication factor to use when creating MSK topics"
  type        = number
  default     = 1 # ★ 원래 값: 3 (나중에 복구) ★
}

variable "msk_topic_configs" {
  description = "Topic-level MSK configuration properties to apply when creating or updating topics"
  type        = map(string)
  default = {
    "min.insync.replicas" = "1" # ★ 원래 값: 2 (나중에 복구) ★
  }
}

variable "msk_topics" {
  description = "MSK topic names mapped to their desired partition counts"
  type        = map(number)
  default = {
    inference-request = 6
    inference-retry   = 3
    inference-dlq     = 1
  }
}

# S3 변수
variable "artifacts_s3_bucket_name" {
  description = "Optional override for the shared artifacts S3 bucket name"
  type        = string
  default     = ""
}

variable "artifacts_s3_force_destroy" {
  description = "Whether to allow Terraform to delete the shared artifacts S3 bucket even when it contains objects"
  type        = bool
  default     = false
}

# ALB 변수
variable "private_cloud_cidrs" {
  description = "Private Cloud 사이트 CIDR (VPCE 경유로 ECR/S3/STS 등 AWS 서비스 접근 허용)"
  type        = list(string)
  default     = []
}

variable "edge_network_cidrs" {
  description = "Edge(공장) 사이트 CIDR (VPN 경유로 Internal ALB 접근 허용)"
  type        = list(string)
  default     = []
}

# VPN 변수
variable "argocd_chart_version" {
  description = "Argo CD Helm chart version"
  type        = string
  default     = "7.8.23"
}

variable "additional_eks_admin_role_arns" {
  description = "Additional IAM role ARNs that should receive EKS cluster admin access"
  type        = list(string)
  default = [
    "arn:aws:iam::808379768010:role/kt_sgs_platform_admin_role",
  ]
}

variable "enable_site_to_site_vpn" {
  description = "Whether to create the Site-to-Site VPN resources"
  type        = bool
  default     = true
}

variable "customer_gateways" {
  description = "Map of customer gateways keyed by site name"
  type = map(object({
    ip      = string
    bgp_asn = number
  }))
  default = {}
}

variable "vpn_static_routes_only" {
  description = "Whether the VPN connection should use static routes only"
  type        = bool
  default     = true
}

variable "vpn_static_route_cidrs" {
  description = "Static route CIDR blocks per site for the Site-to-Site VPN connections"
  type        = map(list(string))
  default     = {}
}
