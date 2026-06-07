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

variable "gitlab_http_allowed_cidrs" {
  description = "CIDR ranges allowed to reach the standalone GitLab VM over HTTP. Used by the host reverse proxy; keep empty unless a local proxy needs direct VM HTTP access."
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

variable "gitlab_count" {
  description = "Number of standalone GitLab VMs."
  type        = number
  default     = 1
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
  default     = "ubuntu-22.04"
}

variable "gpu_worker_flavor_name" {
  description = "OpenStack GPU flavor name for GPU-worker VMs."
  type        = string
  default     = "g1.large"
}

variable "gitlab_image_name" {
  description = "OpenStack image name for standalone GitLab VMs."
  type        = string
  default     = "ubuntu-22.04"
}

variable "gitlab_flavor_name" {
  description = "OpenStack flavor name for standalone GitLab VMs."
  type        = string
  default     = "m1.large"
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

variable "enable_gpu_cuda_bootstrap" {
  description = "Install CUDA Toolkit and cuDNN packages on GPU workers."
  type        = bool
  default     = true
}

variable "gpu_cuda_toolkit_package" {
  description = "CUDA Toolkit apt package installed on GPU workers."
  type        = string
  default     = "cuda-toolkit-12-1"
}

variable "gpu_cudnn_package" {
  description = "cuDNN apt package installed on GPU workers."
  type        = string
  default     = "cudnn9-cuda-12"
}

variable "enable_gpu_training_bootstrap" {
  description = "Create a Python virtual environment on GPU workers with model-training dependencies."
  type        = bool
  default     = true
}

variable "gpu_training_venv_path" {
  description = "Path for the GPU worker model-training Python virtual environment."
  type        = string
  default     = "/opt/hybrid-ai/training-venv"
}

variable "gpu_training_pytorch_cuda_index_url" {
  description = "PyTorch CUDA wheel index used when installing GPU training dependencies."
  type        = string
  default     = "https://download.pytorch.org/whl/cu121"
}

variable "gpu_training_pip_cache_dir" {
  description = "Default pip cache directory used by GitLab shell training jobs on GPU workers."
  type        = string
  default     = "/mnt/nfs/hybrid-ai/pip-cache"
}

variable "gpu_training_python_packages" {
  description = "Python packages installed into the GPU worker model-training virtual environment."
  type        = list(string)
  default = [
    "torch==2.1.0+cu121",
    "torchvision==0.16.0+cu121",
    "torchaudio==2.1.0+cu121",
    "numpy==1.26.4",
    "pandas==2.2.2",
    "scipy==1.11.4",
    "scikit-learn==1.4.2",
    "matplotlib==3.8.4",
    "seaborn==0.13.2",
    "notebook==7.2.2",
    "ipykernel==6.29.5",
    "minio==7.2.8",
  ]
}

variable "instance_metadata" {
  description = "Extra metadata added to every provisioned VM."
  type        = map(string)
  default     = {}
}
