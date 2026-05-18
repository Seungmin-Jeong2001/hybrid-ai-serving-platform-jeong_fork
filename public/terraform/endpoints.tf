# VPC 엔드포인트 보안 그룹
resource "aws_security_group" "vpce" {
  name        = "${var.project_name}-vpce-sg"
  description = "Security group for interface VPC endpoints"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Allow HTTPS from within the VPC"
    from_port   = 443
    to_port     = 443
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
    Name = "${var.project_name}-vpce-sg"
  })
}

# S3 게이트웨이 엔드포인트
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = concat([aws_route_table.public.id], aws_route_table.private[*].id)

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-s3-endpoint"
  })
}

# DynamoDB 게이트웨이 엔드포인트
resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-dynamodb-endpoint"
  })
}

# ECR API 인터페이스 엔드포인트
resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ecr.api"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  security_group_ids  = [aws_security_group.vpce.id]
  subnet_ids          = aws_subnet.eks_private[*].id

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-ecr-api-endpoint"
  })
}

# ECR DKR 인터페이스 엔드포인트
resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  security_group_ids  = [aws_security_group.vpce.id]
  subnet_ids          = aws_subnet.eks_private[*].id

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-ecr-dkr-endpoint"
  })
}
