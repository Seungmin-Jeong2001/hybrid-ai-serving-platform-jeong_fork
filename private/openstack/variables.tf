variable "project_name" {
  description = "Name prefix for private cloud foundation resources."
  type        = string
  default     = "hybrid-ai-private"
}

variable "region" {
  description = "OpenStack region. Leave null to use the provider environment."
  type        = string
  default     = null
}

variable "availability_zone" {
  description = "Optional availability zone for compute instances."
  type        = string
  default     = null
}

variable "external_network_id" {
  description = "External network ID for router gateway. Empty string disables router creation."
  type        = string
  default     = ""
}

variable "floating_ip_pool" {
  description = "External network name used to allocate floating IPs. Required when assign_floating_ips is true."
  type        = string
  default     = ""
}

variable "assign_floating_ips" {
  description = "Whether to assign floating IPs to provisioned nodes for SSH/bootstrap access."
  type        = bool
  default     = false
}

variable "private_network_cidr" {
  description = "CIDR block for the private foundation network."
  type        = string
  default     = "10.42.0.0/24"
}

variable "dns_nameservers" {
  description = "DNS servers assigned to the private subnet."
  type        = list(string)
  default     = ["1.1.1.1", "8.8.8.8"]
}

variable "ssh_allowed_cidrs" {
  description = "CIDR ranges allowed to reach instances over SSH."
  type        = list(string)
  default     = []
}

variable "key_pair_name" {
  description = "OpenStack key pair name for provisioned instances."
  type        = string
  default     = "hybrid-ai-private-admin"
}

variable "ssh_public_key" {
  description = "Public SSH key material for the OpenStack key pair."
  type        = string
  sensitive   = true
}

variable "control_plane_count" {
  description = "Number of Kubernetes control-plane candidate VMs."
  type        = number
  default     = 1
}

variable "build_worker_count" {
  description = "Number of model build worker VMs."
  type        = number
  default     = 1
}

variable "gpu_worker_count" {
  description = "Number of GPU worker VMs. Keep zero until GPU quota is confirmed."
  type        = number
  default     = 0
}

variable "control_plane_image_name" {
  description = "OpenStack image name for control-plane VMs."
  type        = string
  default     = "ubuntu-22.04"
}

variable "control_plane_flavor_name" {
  description = "OpenStack flavor name for control-plane VMs."
  type        = string
  default     = "m1.medium"
}

variable "build_worker_image_name" {
  description = "OpenStack image name for build-worker VMs."
  type        = string
  default     = "ubuntu-22.04"
}

variable "build_worker_flavor_name" {
  description = "OpenStack flavor name for build-worker VMs."
  type        = string
  default     = "m1.large"
}

variable "gpu_worker_image_name" {
  description = "OpenStack image name for GPU-worker VMs."
  type        = string
  default     = "ubuntu-22.04-gpu"
}

variable "gpu_worker_flavor_name" {
  description = "OpenStack GPU flavor name for GPU-worker VMs."
  type        = string
  default     = "g1.large"
}

variable "install_node_dependencies" {
  description = "Install common infrastructure node dependencies through cloud-init."
  type        = bool
  default     = true
}

variable "enable_gpu_bootstrap" {
  description = "Install and tune GPU worker host dependencies through cloud-init."
  type        = bool
  default     = true
}

variable "gpu_driver_autoinstall" {
  description = "Allow GPU workers to use ubuntu-drivers autoinstall when an NVIDIA PCI device is detected."
  type        = bool
  default     = true
}

variable "instance_metadata" {
  description = "Extra metadata added to every provisioned VM."
  type        = map(string)
  default     = {}
}
