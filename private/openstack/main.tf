locals {
  common_metadata = merge(
    {
      managed_by = "terraform"
      scope      = "private-cloud-foundation"
    },
    var.instance_metadata,
  )

  cloud_init_common = {
    install_node_dependencies       = tostring(var.install_node_dependencies)
    gitlab_container_image          = var.gitlab_container_image
    enable_gpu_bootstrap            = tostring(var.enable_gpu_bootstrap)
    gpu_driver_autoinstall          = tostring(var.gpu_driver_autoinstall)
    gpu_driver_package              = var.gpu_driver_package
    enable_gpu_cuda_bootstrap       = tostring(var.enable_gpu_cuda_bootstrap)
    gpu_cuda_toolkit_package        = var.gpu_cuda_toolkit_package
    gpu_cudnn_package               = var.gpu_cudnn_package
    enable_gpu_training_bootstrap   = tostring(var.enable_gpu_training_bootstrap)
    gpu_training_venv_path          = var.gpu_training_venv_path
    gpu_training_pytorch_cuda_index = var.gpu_training_pytorch_cuda_index_url
    gpu_training_pip_cache_dir      = var.gpu_training_pip_cache_dir
    gpu_training_python_packages    = var.gpu_training_python_packages
  }
}

resource "openstack_networking_network_v2" "private" {
  name           = "${var.project_name}-net"
  admin_state_up = true
}

resource "openstack_networking_subnet_v2" "private" {
  name            = "${var.project_name}-subnet"
  network_id      = openstack_networking_network_v2.private.id
  cidr            = var.private_network_cidr
  ip_version      = 4
  dns_nameservers = var.dns_nameservers
}

resource "openstack_networking_router_v2" "private" {
  count = var.external_network_id == "" ? 0 : 1

  name                = "${var.project_name}-router"
  admin_state_up      = true
  external_network_id = var.external_network_id
}

resource "openstack_networking_router_interface_v2" "private" {
  count = var.external_network_id == "" ? 0 : 1

  router_id = openstack_networking_router_v2.private[0].id
  subnet_id = openstack_networking_subnet_v2.private.id
}

resource "openstack_networking_secgroup_v2" "private" {
  name        = "${var.project_name}-sg"
  description = "Base security group for private cloud foundation nodes."
}

resource "openstack_networking_secgroup_rule_v2" "allow_internal_tcp" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  remote_ip_prefix  = var.private_network_cidr
  security_group_id = openstack_networking_secgroup_v2.private.id
}

resource "openstack_networking_secgroup_rule_v2" "allow_internal_udp" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "udp"
  remote_ip_prefix  = var.private_network_cidr
  security_group_id = openstack_networking_secgroup_v2.private.id
}

resource "openstack_networking_secgroup_rule_v2" "allow_internal_icmp" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "icmp"
  remote_ip_prefix  = var.private_network_cidr
  security_group_id = openstack_networking_secgroup_v2.private.id
}

resource "openstack_networking_secgroup_rule_v2" "allow_ssh" {
  for_each = toset(var.ssh_allowed_cidrs)

  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = each.value
  security_group_id = openstack_networking_secgroup_v2.private.id
}

resource "openstack_networking_secgroup_rule_v2" "allow_gitlab_http" {
  for_each = toset(var.gitlab_count > 0 ? var.gitlab_http_allowed_cidrs : [])

  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 80
  port_range_max    = 80
  remote_ip_prefix  = each.value
  security_group_id = openstack_networking_secgroup_v2.private.id
}

resource "openstack_networking_secgroup_rule_v2" "allow_harbor_http" {
  for_each = var.harbor_count > 0 ? setsubtract(
    toset(var.harbor_http_allowed_cidrs),
    toset(var.gitlab_count > 0 ? var.gitlab_http_allowed_cidrs : []),
  ) : toset([])

  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 80
  port_range_max    = 80
  remote_ip_prefix  = each.value
  security_group_id = openstack_networking_secgroup_v2.private.id
}

resource "openstack_networking_secgroup_rule_v2" "allow_harbor_https" {
  for_each = toset(var.harbor_count > 0 ? var.harbor_http_allowed_cidrs : [])

  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 443
  port_range_max    = 443
  remote_ip_prefix  = each.value
  security_group_id = openstack_networking_secgroup_v2.private.id
}

resource "openstack_networking_secgroup_rule_v2" "allow_minio_api_nodeport" {
  for_each = toset(var.minio_nodeport_allowed_cidrs)

  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 30900
  port_range_max    = 30900
  remote_ip_prefix  = each.value
  security_group_id = openstack_networking_secgroup_v2.private.id
}

resource "openstack_networking_secgroup_rule_v2" "allow_minio_console_nodeport" {
  for_each = toset(var.minio_nodeport_allowed_cidrs)

  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 30990
  port_range_max    = 30990
  remote_ip_prefix  = each.value
  security_group_id = openstack_networking_secgroup_v2.private.id
}

resource "openstack_compute_keypair_v2" "admin" {
  name       = var.key_pair_name
  public_key = var.ssh_public_key
}

resource "openstack_networking_port_v2" "control_plane" {
  count = var.control_plane_count

  name               = format("%s-control-%02d-port", var.project_name, count.index + 1)
  network_id         = openstack_networking_network_v2.private.id
  admin_state_up     = true
  security_group_ids = [openstack_networking_secgroup_v2.private.id]

  fixed_ip {
    subnet_id = openstack_networking_subnet_v2.private.id
    ip_address = (
      length(var.control_plane_private_ips) > count.index
      ? var.control_plane_private_ips[count.index]
      : null
    )
  }
}

resource "openstack_compute_instance_v2" "control_plane" {
  count = var.control_plane_count

  name              = format("%s-control-%02d", var.project_name, count.index + 1)
  image_name        = var.control_plane_image_name
  flavor_name       = var.control_plane_flavor_name
  key_pair          = openstack_compute_keypair_v2.admin.name
  availability_zone = var.availability_zone
  user_data         = templatefile("${path.module}/cloud-init/base.yaml.tftpl", merge(local.cloud_init_common, { node_role = "control-plane" }))
  config_drive      = true

  metadata = merge(local.common_metadata, {
    role = "control-plane"
  })

  network {
    port = openstack_networking_port_v2.control_plane[count.index].id
  }

  lifecycle {
    ignore_changes = [
      flavor_name,
      image_name,
      user_data,
    ]
  }

  timeouts {
    create = var.compute_instance_create_timeout
    update = var.compute_instance_update_timeout
    delete = var.compute_instance_delete_timeout
  }
}

resource "openstack_networking_floatingip_v2" "control_plane" {
  count = var.assign_floating_ips ? var.control_plane_count : 0

  pool = var.floating_ip_pool
}

resource "openstack_networking_floatingip_associate_v2" "control_plane" {
  count = var.assign_floating_ips ? var.control_plane_count : 0

  floating_ip = openstack_networking_floatingip_v2.control_plane[count.index].address
  port_id     = openstack_networking_port_v2.control_plane[count.index].id

  depends_on = [
    openstack_compute_instance_v2.control_plane,
    openstack_networking_router_interface_v2.private,
  ]
}

resource "openstack_networking_port_v2" "build_worker" {
  count = var.build_worker_count

  name               = format("%s-build-%02d-port", var.project_name, count.index + 1)
  network_id         = openstack_networking_network_v2.private.id
  admin_state_up     = true
  security_group_ids = [openstack_networking_secgroup_v2.private.id]

  fixed_ip {
    subnet_id = openstack_networking_subnet_v2.private.id
    ip_address = (
      length(var.build_worker_private_ips) > count.index
      ? var.build_worker_private_ips[count.index]
      : null
    )
  }
}

resource "openstack_compute_instance_v2" "build_worker" {
  count = var.build_worker_count

  name              = format("%s-build-%02d", var.project_name, count.index + 1)
  image_name        = var.build_worker_image_name
  flavor_name       = var.build_worker_flavor_name
  key_pair          = openstack_compute_keypair_v2.admin.name
  availability_zone = var.availability_zone
  user_data         = templatefile("${path.module}/cloud-init/base.yaml.tftpl", merge(local.cloud_init_common, { node_role = "build-worker" }))
  config_drive      = true

  metadata = merge(local.common_metadata, {
    role = "build-worker"
  })

  network {
    port = openstack_networking_port_v2.build_worker[count.index].id
  }

  lifecycle {
    ignore_changes = [
      flavor_name,
      image_name,
      user_data,
    ]
  }

  timeouts {
    create = var.compute_instance_create_timeout
    update = var.compute_instance_update_timeout
    delete = var.compute_instance_delete_timeout
  }
}

resource "openstack_networking_floatingip_v2" "build_worker" {
  count = var.assign_floating_ips ? var.build_worker_count : 0

  pool = var.floating_ip_pool
}

resource "openstack_networking_floatingip_associate_v2" "build_worker" {
  count = var.assign_floating_ips ? var.build_worker_count : 0

  floating_ip = openstack_networking_floatingip_v2.build_worker[count.index].address
  port_id     = openstack_networking_port_v2.build_worker[count.index].id

  depends_on = [
    openstack_compute_instance_v2.build_worker,
    openstack_networking_router_interface_v2.private,
  ]
}

resource "openstack_networking_port_v2" "gpu_worker" {
  count = var.gpu_worker_count

  name               = format("%s-gpu-%02d-port", var.project_name, count.index + 1)
  network_id         = openstack_networking_network_v2.private.id
  admin_state_up     = true
  security_group_ids = [openstack_networking_secgroup_v2.private.id]

  fixed_ip {
    subnet_id = openstack_networking_subnet_v2.private.id
    ip_address = (
      length(var.gpu_worker_private_ips) > count.index
      ? var.gpu_worker_private_ips[count.index]
      : null
    )
  }
}

resource "openstack_compute_instance_v2" "gpu_worker" {
  count = var.gpu_worker_count

  name              = format("%s-gpu-%02d", var.project_name, count.index + 1)
  image_name        = var.gpu_worker_image_name
  flavor_name       = var.gpu_worker_flavor_name
  key_pair          = openstack_compute_keypair_v2.admin.name
  availability_zone = var.availability_zone
  user_data         = templatefile("${path.module}/cloud-init/base.yaml.tftpl", merge(local.cloud_init_common, { node_role = "gpu-worker" }))
  config_drive      = true

  metadata = merge(local.common_metadata, {
    role = "gpu-worker"
  })

  network {
    port = openstack_networking_port_v2.gpu_worker[count.index].id
  }

  lifecycle {
    ignore_changes = [
      flavor_name,
      image_name,
      user_data,
    ]
  }

  timeouts {
    create = var.compute_instance_create_timeout
    update = var.compute_instance_update_timeout
    delete = var.compute_instance_delete_timeout
  }
}

resource "openstack_networking_floatingip_v2" "gpu_worker" {
  count = var.assign_floating_ips ? var.gpu_worker_count : 0

  pool = var.floating_ip_pool
}

resource "openstack_networking_floatingip_associate_v2" "gpu_worker" {
  count = var.assign_floating_ips ? var.gpu_worker_count : 0

  floating_ip = openstack_networking_floatingip_v2.gpu_worker[count.index].address
  port_id     = openstack_networking_port_v2.gpu_worker[count.index].id

  depends_on = [
    openstack_compute_instance_v2.gpu_worker,
    openstack_networking_router_interface_v2.private,
  ]
}

resource "openstack_networking_port_v2" "gitlab" {
  count = var.gitlab_count

  name               = format("%s-gitlab-%02d-port", var.project_name, count.index + 1)
  network_id         = openstack_networking_network_v2.private.id
  admin_state_up     = true
  security_group_ids = [openstack_networking_secgroup_v2.private.id]

  fixed_ip {
    subnet_id = openstack_networking_subnet_v2.private.id
    ip_address = (
      length(var.gitlab_private_ips) > count.index
      ? var.gitlab_private_ips[count.index]
      : null
    )
  }
}

resource "openstack_compute_instance_v2" "gitlab" {
  count = var.gitlab_count

  name              = format("%s-gitlab-%02d", var.project_name, count.index + 1)
  image_name        = var.gitlab_image_name
  flavor_name       = var.gitlab_flavor_name
  key_pair          = openstack_compute_keypair_v2.admin.name
  availability_zone = var.availability_zone
  user_data         = templatefile("${path.module}/cloud-init/base.yaml.tftpl", merge(local.cloud_init_common, { node_role = "gitlab" }))
  config_drive      = true

  metadata = merge(local.common_metadata, {
    role = "gitlab"
  })

  network {
    port = openstack_networking_port_v2.gitlab[count.index].id
  }

  lifecycle {
    ignore_changes = [
      flavor_name,
      image_name,
      user_data,
    ]
  }

  timeouts {
    create = var.compute_instance_create_timeout
    update = var.compute_instance_update_timeout
    delete = var.compute_instance_delete_timeout
  }
}

resource "openstack_networking_floatingip_v2" "gitlab" {
  count = var.assign_floating_ips ? var.gitlab_count : 0

  pool = var.floating_ip_pool
}

resource "openstack_networking_floatingip_associate_v2" "gitlab" {
  count = var.assign_floating_ips ? var.gitlab_count : 0

  floating_ip = openstack_networking_floatingip_v2.gitlab[count.index].address
  port_id     = openstack_networking_port_v2.gitlab[count.index].id

  depends_on = [
    openstack_compute_instance_v2.gitlab,
    openstack_networking_router_interface_v2.private,
  ]
}

resource "openstack_networking_port_v2" "harbor" {
  count = var.harbor_count

  name               = format("%s-harbor-%02d-port", var.project_name, count.index + 1)
  network_id         = openstack_networking_network_v2.private.id
  admin_state_up     = true
  security_group_ids = [openstack_networking_secgroup_v2.private.id]

  fixed_ip {
    subnet_id = openstack_networking_subnet_v2.private.id
    ip_address = (
      length(var.harbor_private_ips) > count.index
      ? var.harbor_private_ips[count.index]
      : null
    )
  }
}

resource "openstack_compute_instance_v2" "harbor" {
  count = var.harbor_count

  name              = format("%s-harbor-%02d", var.project_name, count.index + 1)
  image_name        = var.harbor_image_name
  flavor_name       = var.harbor_flavor_name
  key_pair          = openstack_compute_keypair_v2.admin.name
  availability_zone = var.availability_zone
  user_data         = templatefile("${path.module}/cloud-init/base.yaml.tftpl", merge(local.cloud_init_common, { node_role = "harbor" }))
  config_drive      = true

  metadata = merge(local.common_metadata, {
    role = "harbor"
  })

  network {
    port = openstack_networking_port_v2.harbor[count.index].id
  }

  lifecycle {
    ignore_changes = [
      flavor_name,
      image_name,
      user_data,
    ]
  }

  timeouts {
    create = var.compute_instance_create_timeout
    update = var.compute_instance_update_timeout
    delete = var.compute_instance_delete_timeout
  }
}

resource "openstack_networking_floatingip_v2" "harbor" {
  count = var.assign_floating_ips ? var.harbor_count : 0

  pool = var.floating_ip_pool
}

resource "openstack_networking_floatingip_associate_v2" "harbor" {
  count = var.assign_floating_ips ? var.harbor_count : 0

  floating_ip = openstack_networking_floatingip_v2.harbor[count.index].address
  port_id     = openstack_networking_port_v2.harbor[count.index].id

  depends_on = [
    openstack_compute_instance_v2.harbor,
    openstack_networking_router_interface_v2.private,
  ]
}
