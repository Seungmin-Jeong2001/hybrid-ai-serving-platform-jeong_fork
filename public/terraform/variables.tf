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


# ECR 리포지토리 변수
variable "ecr_repositories" {
  description = "ECR repository names"
  type        = list(string)
  default = [
    "predictive-model",
    "inference-api",
    "inference-worker",
    "dashboard-backend",
    "dashboard-frontend",
  ]
}

# EKS 변수
variable "eks_public_access_cidrs" {
  description = "CIDR blocks allowed to access the EKS public endpoint"
  type        = list(string)
  default = [
    "221.150.194.220/32", # choi
    "125.243.10.39/32",   # shin
    "218.39.98.40/32",    # kim 1
    "218.39.98.124/32"    # kim 2
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
    capacity_type  = string
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
    inference_ondemand = {
      instance_types = ["m7i-flex.xlarge"] # 임시 비용 절감, 원래 값: m7i-flex.large (t3.small은 최대 파드 11개 한계로 변경) / t3.medium 파드 부족으로 변경 (06-22)
      capacity_type  = "ON_DEMAND"
      az_count       = 3
      desired_size   = 3
      min_size       = 3
      max_size       = 3
      labels         = { workload = "inference", capacity = "ondemand" }
      taints         = []
    }
    inference_spot = {
      instance_types = ["m7i-flex.xlarge"]
      capacity_type  = "SPOT"
      az_count       = 3
      desired_size   = 0
      min_size       = 0
      max_size       = 7
      labels         = { workload = "inference", capacity = "spot" }
      taints         = []
    }
    general = {
      # system(ArgoCD, KEDA, cert-manager) + monitoring(Prometheus, Grafana, Loki) + app(dashboard) 통합
      # KEDA(제어부)와 inference(실행부) 장애 전파 격리 목적
      # ★ 운영 전환 시: m7i-flex.large × 2 (8GB × 2, 비용 동일 + HA 확보)
      # ★   → instance_types = ["m7i-flex.large"], desired_size = 2, min_size = 2
      instance_types = ["m7i-flex.xlarge"] # 데모: 4vCPU / 16GB — general 워크로드 전체 수용
      capacity_type  = "ON_DEMAND"
      az_count       = 3
      desired_size   = 3
      min_size       = 3
      max_size       = 5
      labels         = { workload = "general" }
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
  default     = 3
}

variable "msk_ebs_volume_size" {
  description = "Broker EBS volume size in GiB for the MSK cluster"
  type        = number
  default     = 100
}

variable "manage_msk_topics" {
  description = "Whether Terraform should reconcile MSK topics through the AWS Kafka topic API"
  type        = bool
  default     = true
}

variable "msk_topic_replication_factor" {
  description = "Replication factor to use when creating MSK topics"
  type        = number
  default     = 3
}

variable "msk_topic_configs" {
  description = "Topic-level MSK configuration properties to apply when creating or updating topics"
  type        = map(string)
  default = {
    "min.insync.replicas" = "2"
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
  default     = ["10.42.0.0/24"]
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

variable "alb_certificate_arn" {
  description = "Optional override for the ACM certificate ARN used by the internal ALB ingress resources; when empty Terraform auto-discovers a matching ACM certificate"
  type        = string
  default     = ""
}

variable "alb_certificate_domain" {
  description = "Primary ACM certificate domain name to discover automatically for the internal ALB ingress resources"
  type        = string
  default     = "*.sgs-hasp.click"
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

variable "enable_s3_interface_endpoint" {
  description = "S3 인터페이스 엔드포인트 생성 여부 (온프레미스 VPN→S3 직접 접근=ECR-over-VPN에 필요, 비용 발생)"
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

# MacMini bastion 등 전용 VPN 게이트웨이 (customer_gateways와 분리 관리, 동일 VGW에 연결)
variable "vpn_gateways" {
  description = "Map of dedicated VPN gateways (e.g. MacMini bastion) keyed by name; each creates its own customer gateway + VPN connection on the shared VGW"
  type = map(object({
    ip      = string
    bgp_asn = number
  }))
  default = {}
}

variable "vpn_gateway_static_route_cidrs" {
  description = "Static route CIDR blocks per vpn_gateways entry (edge customer_gateways의 CIDR과 중복 금지)"
  type        = map(list(string))
  default     = {}
}

variable "dlq_alert_slack_webhook_url" {
  description = "Slack incoming webhook URL for DLQ alerts; leave empty to skip Lambda webhook delivery"
  type        = string
  default     = ""
  sensitive   = true
}

variable "dlq_alert_topic_name" {
  description = "MSK topic name that stores failed inference requests"
  type        = string
  default     = "inference-dlq"
}

variable "incident_copilot_bedrock_model_id" {
  description = "Amazon Bedrock model ID used by the inference incident copilot Lambda"
  type        = string
  default     = "anthropic.claude-3-haiku-20240307-v1:0"
}

variable "incident_copilot_monitoring_url" {
  description = "Optional monitoring dashboard URL shown in Incident Copilot Slack alerts"
  type        = string
  default     = ""
}
