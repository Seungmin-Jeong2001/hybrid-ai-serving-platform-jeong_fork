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

# ECR 변수
variable "ecr_repositories" {
  description = "ECR repository names"
  type        = list(string)
  default = [
    "factory-simulator",
    "operation-simulator",
  ]
}

# EKS 변수
variable "eks_cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.31"
}

variable "eks_node_instance_types" {
  description = "Instance types for the EKS managed node group"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "eks_node_desired_size" {
  description = "Desired number of nodes in the EKS managed node group"
  type        = number
  default     = 2
}

variable "eks_node_min_size" {
  description = "Minimum number of nodes in the EKS managed node group"
  type        = number
  default     = 1
}

variable "eks_node_max_size" {
  description = "Maximum number of nodes in the EKS managed node group"
  type        = number
  default     = 3
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
  default     = "kafka.t3.small"
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

# VPN 변수
variable "enable_site_to_site_vpn" {
  description = "Whether to create the Site-to-Site VPN resources"
  type        = bool
  default     = false
}

variable "customer_gateway_ip" {
  description = "Public IP address of the customer gateway device"
  type        = string
  default     = ""
}

variable "customer_gateway_bgp_asn" {
  description = "BGP ASN for the customer gateway"
  type        = number
  default     = 65000
}

variable "vpn_static_routes_only" {
  description = "Whether the VPN connection should use static routes only"
  type        = bool
  default     = true
}

variable "vpn_static_route_cidrs" {
  description = "Static route CIDR blocks for the Site-to-Site VPN connection"
  type        = list(string)
  default     = []
}
