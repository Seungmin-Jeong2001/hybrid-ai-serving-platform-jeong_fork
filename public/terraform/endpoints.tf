# VPC 엔드포인트 보안 그룹
resource "aws_security_group" "vpce" {
  name        = "${var.project_name}-vpce-sg"
  description = "Security group for interface VPC endpoints"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Allow HTTPS from VPC and Private Cloud sites"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = concat([var.vpc_cidr], var.private_cloud_cidrs)
  }

  # Private Cloud 사이트(VPN)에서 인터페이스 엔드포인트(ECR/S3/STS/SSM 등) 호출 허용
  # Edge 사이트는 VPCE를 직접 호출할 필요가 없으므로 의도적으로 제외 (역할 분리)
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

# S3 게이트웨이 엔드포인트 (무료, VPC 내부 트래픽용)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-s3-gw-endpoint"
  })
}

# S3 인터페이스 엔드포인트 - 온프레미스(VPN 경유)에서 S3 직접 접근용.
# ECR 이미지 레이어가 S3에 저장되므로 ECR-over-VPN pull/push에 필수.
# 비용 발생(엔드포인트 시간당+데이터) → var.enable_s3_interface_endpoint=true 일 때만 생성.
# VPN 활성화(enable_site_to_site_vpn) 시 함께 켜는 것을 권장.
resource "aws_vpc_endpoint" "s3_interface" {
  count = var.enable_s3_interface_endpoint ? 1 : 0

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

# DynamoDB 게이트웨이 엔드포인트 (무료)
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

# STS 인터페이스 엔드포인트 (IRSA 토큰 검증용)
resource "aws_vpc_endpoint" "sts" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.sts"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  security_group_ids  = [aws_security_group.vpce.id]
  subnet_ids          = aws_subnet.eks_private[*].id

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-sts-endpoint"
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
