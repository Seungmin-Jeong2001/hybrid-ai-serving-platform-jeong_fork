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

variable "private_subnet_cidrs" {
  description = "CIDR blocks for the three private subnets"
  type        = list(string)
  default = [
    "10.0.11.0/24",
    "10.0.12.0/24",
    "10.0.13.0/24",
  ]
}

variable "ecr_repositories" {
  description = "ECR repository names"
  type        = list(string)
  default = [
    "factory-simulator",
    "operation-simulator",
  ]
}

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
