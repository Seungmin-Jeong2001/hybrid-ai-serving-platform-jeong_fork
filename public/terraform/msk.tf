resource "aws_security_group" "msk" {
  name        = "${var.project_name}-msk-sg"
  description = "Security group for the MSK cluster"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Allow Kafka traffic from within the VPC"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
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

resource "aws_msk_cluster" "main" {
  cluster_name           = "${var.project_name}-msk"
  kafka_version          = var.msk_kafka_version
  number_of_broker_nodes = var.msk_number_of_broker_nodes

  broker_node_group_info {
    instance_type   = var.msk_broker_instance_type
    client_subnets  = aws_subnet.private[*].id
    security_groups = [aws_security_group.msk.id]

    storage_info {
      ebs_storage_info {
        volume_size = var.msk_ebs_volume_size
      }
    }
  }

  encryption_info {
    encryption_in_transit {
      client_broker = "TLS_PLAINTEXT"
      in_cluster    = true
    }
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-msk"
  })
}
