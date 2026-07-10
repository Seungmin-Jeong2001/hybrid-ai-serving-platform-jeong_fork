locals {
  cluster_autoscaler_discovery_tags = {
    "k8s.io/cluster-autoscaler/enabled"                      = "true"
    "k8s.io/cluster-autoscaler/${aws_eks_cluster.main.name}" = "owned"
  }

  cluster_autoscaler_label_tags = merge([
    for workload, cfg in var.eks_node_groups : {
      for label_key, label_value in cfg.labels :
      "${workload}:label:${label_key}" => {
        workload = workload
        key      = "k8s.io/cluster-autoscaler/node-template/label/${label_key}"
        value    = label_value
      }
    }
  ]...)

  cluster_autoscaler_taint_tags = merge([
    for workload, cfg in var.eks_node_groups : {
      for taint in cfg.taints :
      "${workload}:taint:${taint.key}" => {
        workload = workload
        key      = "k8s.io/cluster-autoscaler/node-template/taint/${taint.key}"
        value    = "${taint.value}:${taint.effect}"
      }
    }
  ]...)

  cluster_autoscaler_asg_tags = merge(
    {
      for entry in flatten([
        for workload, ng in aws_eks_node_group.workloads : [
          for tag_key, tag_value in local.cluster_autoscaler_discovery_tags : {
            id       = "${workload}:discovery:${tag_key}"
            workload = workload
            key      = tag_key
            value    = tag_value
            asg_name = ng.resources[0].autoscaling_groups[0].name
          }
        ]
      ]) : entry.id => entry
    },
    {
      for id, entry in local.cluster_autoscaler_label_tags :
      id => merge(entry, {
        asg_name = aws_eks_node_group.workloads[entry.workload].resources[0].autoscaling_groups[0].name
      })
    },
    {
      for id, entry in local.cluster_autoscaler_taint_tags :
      id => merge(entry, {
        asg_name = aws_eks_node_group.workloads[entry.workload].resources[0].autoscaling_groups[0].name
      })
    },
  )
}

resource "aws_autoscaling_group_tag" "cluster_autoscaler" {
  for_each = local.cluster_autoscaler_asg_tags

  autoscaling_group_name = each.value.asg_name

  tag {
    key                 = each.value.key
    value               = each.value.value
    propagate_at_launch = true
  }
}
