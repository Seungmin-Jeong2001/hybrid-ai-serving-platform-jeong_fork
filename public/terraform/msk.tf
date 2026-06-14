# MSK 보안 그룹
resource "aws_security_group" "msk" {
  name        = "${var.project_name}-msk-sg"
  description = "Security group for the MSK cluster"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Allow Kafka TLS traffic from EKS private subnets"
    from_port   = 9094
    to_port     = 9094
    protocol    = "tcp"
    cidr_blocks = var.eks_private_subnet_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-msk-sg"
  })
}

# MSK 클러스터
resource "aws_msk_cluster" "main" {
  cluster_name           = "${var.project_name}-msk"
  kafka_version          = var.msk_kafka_version
  number_of_broker_nodes = var.msk_number_of_broker_nodes

  broker_node_group_info {
    instance_type   = var.msk_broker_instance_type
    client_subnets  = slice(aws_subnet.msk_private[*].id, 0, 2) # 임시 비용 절감 (브로커 1개, AWS 최소 2개 서브넷 요구), 원래 값: aws_subnet.msk_private[*].id (3 AZ, 나중에 복구)
    security_groups = [aws_security_group.msk.id]

    storage_info {
      ebs_storage_info {
        volume_size = var.msk_ebs_volume_size
      }
    }
  }

  encryption_info {
    encryption_in_transit {
      client_broker = "TLS"
      in_cluster    = true
    }
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-msk"
  })
}
