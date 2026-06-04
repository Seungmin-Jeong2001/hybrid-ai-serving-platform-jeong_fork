# Route 53 Resolver Inbound Endpoint
# - 온프레미스(Private Cloud / Edge)에서 VPC 내부의 사설 DNS(예: VPCE PrivateLink, Private Hosted Zone)를
#   조회할 수 있도록 인바운드 DNS 진입점을 제공한다.
# - 온프레미스 DNS 서버는 아래 출력되는 IP들을 conditional forwarder로 등록해 사용한다.

# Inbound Resolver 전용 SG (DNS 53/UDP + 53/TCP)
resource "aws_security_group" "resolver_inbound" {
  name        = "${var.project_name}-resolver-inbound-sg"
  description = "Allow DNS from on-prem sites (Private Cloud + Edge) to the Route 53 Inbound Resolver"
  vpc_id      = aws_vpc.main.id

  dynamic "ingress" {
    for_each = length(concat(var.private_cloud_cidrs, var.edge_network_cidrs)) > 0 ? [1] : []
    content {
      description = "DNS UDP from on-prem sites"
      from_port   = 53
      to_port     = 53
      protocol    = "udp"
      cidr_blocks = concat(var.private_cloud_cidrs, var.edge_network_cidrs)
    }
  }

  dynamic "ingress" {
    for_each = length(concat(var.private_cloud_cidrs, var.edge_network_cidrs)) > 0 ? [1] : []
    content {
      description = "DNS TCP from on-prem sites"
      from_port   = 53
      to_port     = 53
      protocol    = "tcp"
      cidr_blocks = concat(var.private_cloud_cidrs, var.edge_network_cidrs)
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-resolver-inbound-sg"
  })
}

# Route 53 Resolver Inbound Endpoint
# - AWS 요구사항: 서로 다른 AZ에 있는 2개 이상의 서브넷 필요
# - EKS 프라이빗 서브넷은 다중 AZ로 깔려 있어 그대로 사용
resource "aws_route53_resolver_endpoint" "inbound" {
  name      = "${var.project_name}-inbound-resolver"
  direction = "INBOUND"

  security_group_ids = [aws_security_group.resolver_inbound.id]

  dynamic "ip_address" {
    for_each = slice(aws_subnet.eks_private[*].id, 0, 2)
    content {
      subnet_id = ip_address.value
    }
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-inbound-resolver"
  })
}
