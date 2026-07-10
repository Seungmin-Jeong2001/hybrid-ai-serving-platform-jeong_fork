# EKS 클러스터
resource "aws_eks_cluster" "main" {
  name     = "${var.project_name}-eks"
  role_arn = aws_iam_role.eks_cluster.arn
  version  = var.eks_cluster_version

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  vpc_config {
    subnet_ids = concat(
      aws_subnet.public[*].id,
      aws_subnet.eks_private[*].id,
    )
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = var.eks_public_access_cidrs
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
  ]

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-eks"
  })
}

# EKS VPC CNI 애드온
resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "vpc-cni"
}

# EKS CoreDNS 애드온
resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "coredns"
  configuration_values = jsonencode({
    nodeSelector = {
      workload = "general"
    }
  })
}

# EKS kube-proxy 애드온
resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "kube-proxy"
}

# 노드 그룹별 서브넷 매핑
locals {
  node_group_subnet_ids = {
    for name, cfg in var.eks_node_groups :
    name => slice(aws_subnet.eks_private[*].id, 0, cfg.az_count)
  }
}

# 노드 그룹별 Launch Template (EC2 인스턴스 Name 태그 전파용)
resource "aws_launch_template" "node_groups" {
  for_each = var.eks_node_groups

  name = "${var.project_name}-${each.key}-lt"

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.common_tags, {
      Name = "${var.project_name}-${each.key}"
    })
  }

  # system 노드만 30GB: SSM을 통해 Terraform/Kafka 바이너리를 /tmp에 내려받아 실행하므로 디스크 여유 필요
  # 나머지 노드는 기본값(20GB) 사용
  dynamic "block_device_mappings" {
    for_each = each.key == "system" ? [1] : []
    content {
      device_name = "/dev/xvda"
      ebs {
        volume_size           = 30
        volume_type           = "gp3"
        delete_on_termination = true
      }
    }
  }
}

# EKS 노드 그룹 (워크로드별: inference, app, system, monitoring)
resource "aws_eks_node_group" "workloads" {
  for_each = var.eks_node_groups

  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.project_name}-${each.key}"
  node_role_arn   = aws_iam_role.eks_node_group.arn
  subnet_ids      = local.node_group_subnet_ids[each.key]

  instance_types = each.value.instance_types
  capacity_type  = each.value.capacity_type

  launch_template {
    id      = aws_launch_template.node_groups[each.key].id
    version = aws_launch_template.node_groups[each.key].latest_version
  }

  scaling_config {
    desired_size = each.value.desired_size
    min_size     = each.value.min_size
    max_size     = each.value.max_size
  }

  update_config {
    max_unavailable = 1
  }

  labels = each.value.labels

  dynamic "taint" {
    for_each = each.value.taints
    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = taint.value.effect
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_ecr_read_only_policy,
  ]

  tags = merge(local.common_tags, {
    Name     = "${var.project_name}-${each.key}"
    Workload = each.key
  })
}
