output "private_network_id" {
  description = "OpenStack private network ID."
  value       = openstack_networking_network_v2.private.id
}

output "private_subnet_id" {
  description = "OpenStack private subnet ID."
  value       = openstack_networking_subnet_v2.private.id
}

output "private_network_cidr" {
  description = "CIDR block for the private foundation network."
  value       = var.private_network_cidr
}

output "security_group_id" {
  description = "Base security group ID for private cloud nodes."
  value       = openstack_networking_secgroup_v2.private.id
}

output "control_plane_nodes" {
  description = "Control-plane candidate VM inventory."
  value = [
    for index, node in openstack_compute_instance_v2.control_plane : {
      name       = node.name
      private_ip = openstack_networking_port_v2.control_plane[index].all_fixed_ips[0]
      floating_ip = (
        var.assign_floating_ips
        ? openstack_networking_floatingip_v2.control_plane[index].address
        : null
      )
      role = node.metadata.role
    }
  ]
}

output "build_worker_nodes" {
  description = "Build-worker VM inventory."
  value = [
    for index, node in openstack_compute_instance_v2.build_worker : {
      name       = node.name
      private_ip = openstack_networking_port_v2.build_worker[index].all_fixed_ips[0]
      floating_ip = (
        var.assign_floating_ips
        ? openstack_networking_floatingip_v2.build_worker[index].address
        : null
      )
      role = node.metadata.role
    }
  ]
}

output "gpu_worker_nodes" {
  description = "GPU-worker VM inventory."
  value = [
    for index, node in openstack_compute_instance_v2.gpu_worker : {
      name       = node.name
      private_ip = openstack_networking_port_v2.gpu_worker[index].all_fixed_ips[0]
      floating_ip = (
        var.assign_floating_ips
        ? openstack_networking_floatingip_v2.gpu_worker[index].address
        : null
      )
      role = node.metadata.role
    }
  ]
}

output "gitlab_nodes" {
  description = "Standalone GitLab VM inventory."
  value = [
    for index, node in openstack_compute_instance_v2.gitlab : {
      name       = node.name
      private_ip = openstack_networking_port_v2.gitlab[index].all_fixed_ips[0]
      floating_ip = (
        var.assign_floating_ips
        ? openstack_networking_floatingip_v2.gitlab[index].address
        : null
      )
      role = node.metadata.role
    }
  ]
}

output "harbor_nodes" {
  description = "Standalone Harbor registry VM inventory."
  value = [
    for index, node in openstack_compute_instance_v2.harbor : {
      name       = node.name
      private_ip = openstack_networking_port_v2.harbor[index].all_fixed_ips[0]
      floating_ip = (
        var.assign_floating_ips
        ? openstack_networking_floatingip_v2.harbor[index].address
        : null
      )
      role = node.metadata.role
    }
  ]
}

output "nfs_server_ip" {
  description = "NFS server IP (first control-plane node)."
  value       = openstack_networking_port_v2.control_plane[0].all_fixed_ips[0]
}
