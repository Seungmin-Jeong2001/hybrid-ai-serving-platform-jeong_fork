locals {
  common_metadata = merge(
    {
      managed_by = "terraform"
      scope      = "private-cloud-foundation"
    },
    var.instance_metadata,
  )
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
  port_range_min    = 1
  port_range_max    = 65535
  remote_ip_prefix  = var.private_network_cidr
  security_group_id = openstack_networking_secgroup_v2.private.id
}

resource "openstack_networking_secgroup_rule_v2" "allow_internal_udp" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "udp"
  port_range_min    = 1
  port_range_max    = 65535
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

resource "openstack_compute_keypair_v2" "admin" {
  name       = var.key_pair_name
  public_key = var.ssh_public_key
}

resource "openstack_compute_instance_v2" "control_plane" {
  count = var.control_plane_count

  name              = format("%s-control-%02d", var.project_name, count.index + 1)
  image_name        = var.control_plane_image_name
  flavor_name       = var.control_plane_flavor_name
  key_pair          = openstack_compute_keypair_v2.admin.name
  security_groups   = [openstack_networking_secgroup_v2.private.name]
  availability_zone = var.availability_zone
  user_data         = templatefile("${path.module}/cloud-init/base.yaml.tftpl", { node_role = "control-plane" })

  metadata = merge(local.common_metadata, {
    role = "control-plane"
  })

  network {
    uuid = openstack_networking_network_v2.private.id
  }
}

resource "openstack_networking_floatingip_v2" "control_plane" {
  count = var.assign_floating_ips ? var.control_plane_count : 0

  pool    = var.floating_ip_pool
  port_id = openstack_compute_instance_v2.control_plane[count.index].network[0].port
}

resource "openstack_compute_instance_v2" "build_worker" {
  count = var.build_worker_count

  name              = format("%s-build-%02d", var.project_name, count.index + 1)
  image_name        = var.build_worker_image_name
  flavor_name       = var.build_worker_flavor_name
  key_pair          = openstack_compute_keypair_v2.admin.name
  security_groups   = [openstack_networking_secgroup_v2.private.name]
  availability_zone = var.availability_zone
  user_data         = templatefile("${path.module}/cloud-init/base.yaml.tftpl", { node_role = "build-worker" })

  metadata = merge(local.common_metadata, {
    role = "build-worker"
  })

  network {
    uuid = openstack_networking_network_v2.private.id
  }
}

resource "openstack_networking_floatingip_v2" "build_worker" {
  count = var.assign_floating_ips ? var.build_worker_count : 0

  pool    = var.floating_ip_pool
  port_id = openstack_compute_instance_v2.build_worker[count.index].network[0].port
}

resource "openstack_compute_instance_v2" "gpu_worker" {
  count = var.gpu_worker_count

  name              = format("%s-gpu-%02d", var.project_name, count.index + 1)
  image_name        = var.gpu_worker_image_name
  flavor_name       = var.gpu_worker_flavor_name
  key_pair          = openstack_compute_keypair_v2.admin.name
  security_groups   = [openstack_networking_secgroup_v2.private.name]
  availability_zone = var.availability_zone
  user_data         = templatefile("${path.module}/cloud-init/base.yaml.tftpl", { node_role = "gpu-worker" })

  metadata = merge(local.common_metadata, {
    role = "gpu-worker"
  })

  network {
    uuid = openstack_networking_network_v2.private.id
  }
}

resource "openstack_networking_floatingip_v2" "gpu_worker" {
  count = var.assign_floating_ips ? var.gpu_worker_count : 0

  pool    = var.floating_ip_pool
  port_id = openstack_compute_instance_v2.gpu_worker[count.index].network[0].port
}
