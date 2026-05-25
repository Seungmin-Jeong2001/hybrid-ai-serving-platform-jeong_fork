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

  # 온프레미스(VPN)에서 인터페이스 엔드포인트(특히 S3/SSM) 호출 허용
  dynamic "ingress" {
    for_each = length(var.edge_network_cidrs) > 0 ? [1] : []
    content {
      description = "Allow HTTPS from on-premise / edge networks over VPN"
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = var.edge_network_cidrs
    }
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

# S3 게이트웨이 엔드포인트 (VPC 내부 트래픽용)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.public.id, aws_route_table.private.id]

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-s3-gw-endpoint"
  })
}

# S3 인터페이스 엔드포인트 (VPN 통한 온프레미스 → S3 트래픽용)
# - 내부 VPC 트래픽은 게이트웨이 엔드포인트로, 온프레미스만 인터페이스 엔드포인트로 분리하기 위해
#   private_dns_only_for_inbound_resolver_endpoint = true 설정
# - AWS 제약: PrivateDnsOnlyForInboundResolverEndpoint=true 사용 시 S3 게이트웨이 엔드포인트가
#   먼저 존재해야 하므로 명시적으로 depends_on 지정
resource "aws_vpc_endpoint" "s3_interface" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  security_group_ids  = [aws_security_group.vpce.id]
  subnet_ids          = aws_subnet.eks_private[*].id

  dns_options {
    private_dns_only_for_inbound_resolver_endpoint = true
  }

  depends_on = [aws_vpc_endpoint.s3]

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-s3-if-endpoint"
  })
}

# DynamoDB 게이트웨이 엔드포인트
resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

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

# SSM (Session Manager - bastionless private access)
resource "aws_vpc_endpoint" "ssm" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ssm"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  security_group_ids  = [aws_security_group.vpce.id]
  subnet_ids          = aws_subnet.eks_private[*].id

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-ssm-endpoint"
  })
}

# SSM Messages
resource "aws_vpc_endpoint" "ssmmessages" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ssmmessages"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  security_group_ids  = [aws_security_group.vpce.id]
  subnet_ids          = aws_subnet.eks_private[*].id

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-ssmmessages-endpoint"
  })
}

# EC2 Messages
resource "aws_vpc_endpoint" "ec2messages" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ec2messages"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  security_group_ids  = [aws_security_group.vpce.id]
  subnet_ids          = aws_subnet.eks_private[*].id

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-ec2messages-endpoint"
  })
}
