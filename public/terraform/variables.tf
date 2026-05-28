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

variable "mgmt_private_subnet_cidr" {
  description = "CIDR block for the single-AZ management/CI-CD private subnet"
  type        = string
  default     = "10.0.30.0/24"
}

variable "mgmt_subnet_az_index" {
  description = "Availability zone index (0=AZ-a, 1=AZ-b, 2=AZ-c) for the management subnet"
  type        = number
  default     = 2
}

variable "nat_gateway_az_index" {
  description = "Availability zone index (0=AZ-a, 1=AZ-b, 2=AZ-c) for the single NAT gateway"
  type        = number
  default     = 1
}

# ECR 변수
variable "ecr_repositories" {
  description = "ECR repository names"
  type        = list(string)
  default = [
    "dnn-model"
  ]
}

# EKS 변수
variable "eks_public_access_cidrs" {
  description = "CIDR blocks allowed to access the EKS public endpoint"
  type        = list(string)
  default = [
    "221.150.194.220/32", # choi
    "125.243.10.39/32",   # shin
    "218.39.98.40 "       # kim
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
    use_mgmt_subnet = bool # if true, ignore az_count and place in the management subnet
  }))
  default = {
    inference = {
      instance_types  = ["c6i.xlarge"]
      az_count        = 3
      desired_size    = 2
      min_size        = 1
      max_size        = 10
      labels          = { workload = "inference" }
      taints          = []
      use_mgmt_subnet = false
    }
    app = {
      instance_types  = ["t3.medium"]
      az_count        = 3
      desired_size    = 2
      min_size        = 1
      max_size        = 10
      labels          = { workload = "app" }
      taints          = []
      use_mgmt_subnet = false
    }
    system = {
      instance_types  = ["t3.medium"]
      az_count        = 2
      desired_size    = 2
      min_size        = 2
      max_size        = 3
      labels          = { workload = "system" }
      taints          = []
      use_mgmt_subnet = false
    }
    monitoring = {
      instance_types  = ["t3.large"]
      az_count        = 2
      desired_size    = 1
      min_size        = 1
      max_size        = 2
      labels          = { workload = "monitoring" }
      taints          = []
      use_mgmt_subnet = false
    }
    management = {
      instance_types  = ["t3.medium"]
      az_count        = 1
      desired_size    = 1
      min_size        = 1
      max_size        = 2
      labels          = { workload = "management" }
      taints          = []
      use_mgmt_subnet = true
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
  default     = 1000
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
variable "internal_alb_deletion_protection" {
  description = "Whether to enable deletion protection for the internal ALB"
  type        = bool
  default     = false
}

variable "internal_alb_target_port" {
  description = "Target port for the internal ALB target group"
  type        = number
  default     = 80
}

variable "internal_alb_target_type" {
  description = "Target type for the internal ALB target group"
  type        = string
  default     = "ip"
}

variable "internal_alb_health_check_path" {
  description = "Health check path for the internal ALB target group"
  type        = string
  default     = "/"
}

variable "edge_network_cidrs" {
  description = "On-premise / edge (factory) CIDR blocks allowed to reach the internal ALB over VPN"
  type        = list(string)
  default     = []
}

# VPN 변수
variable "enable_site_to_site_vpn" {
  description = "Whether to create the Site-to-Site VPN resources"
  type        = bool
  default     = false
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
