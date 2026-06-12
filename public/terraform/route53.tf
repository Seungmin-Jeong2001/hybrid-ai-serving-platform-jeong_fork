# Route53 Private Hosted Zone
# - VPN 연결된 엣지에서 dashboard.sgs-hasp.click → internal ALB IP로 resolve
# - Resolver Inbound Endpoint를 통해 온프레미스(엣지)에서 VPC DNS 조회 가능

# Private Hosted Zone
resource "aws_route53_zone" "private" {
  name = "sgs-hasp.click"

  vpc {
    vpc_id = aws_vpc.main.id
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-private-hosted-zone"
  })
}

# dashboard.sgs-hasp.click → internal ALB (워크플로우에서 UPSERT)
resource "aws_route53_record" "dashboard_private" {
  zone_id = aws_route53_zone.private.zone_id
  name    = "dashboard.sgs-hasp.click"
  type    = "A"

  alias {
    name                   = "placeholder.elb.amazonaws.com"
    zone_id                = "ZWKZPGTI48KDX"
    evaluate_target_health = true
  }

  lifecycle {
    ignore_changes = [alias]
  }
}

# api.sgs-hasp.click → internal ALB (엣지 추론 요청용)
resource "aws_route53_record" "api_private" {
  zone_id = aws_route53_zone.private.zone_id
  name    = "api.sgs-hasp.click"
  type    = "A"

  alias {
    name                   = "placeholder.elb.amazonaws.com"
    zone_id                = "ZWKZPGTI48KDX"
    evaluate_target_health = true
  }

  lifecycle {
    ignore_changes = [alias]
  }
}

# Resolver Inbound Endpoint - 온프레미스(엣지)에서 VPC DNS 조회용
resource "aws_security_group" "resolver_inbound" {
  name        = "${var.project_name}-resolver-inbound-sg"
  description = "Allow DNS from on-prem sites to Route 53 Inbound Resolver"
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

output "resolver_inbound_ips" {
  description = "Inbound Resolver IPs - 엣지 DNS 포워딩 설정에 사용"
  value       = [for ip in aws_route53_resolver_endpoint.inbound.ip_address : ip.ip]
}
