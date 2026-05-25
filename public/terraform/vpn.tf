# 현재 전부 비활성화

# Virtual Private Gateway
resource "aws_vpn_gateway" "main" {
  count = var.enable_site_to_site_vpn ? 1 : 0

  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-vgw"
  })
}

# Customer Gateway
resource "aws_customer_gateway" "main" {
  count = var.enable_site_to_site_vpn ? 1 : 0

  bgp_asn    = var.customer_gateway_bgp_asn
  ip_address = var.customer_gateway_ip
  type       = "ipsec.1"

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-cgw"
  })
}

# Site-to-Site VPN
resource "aws_vpn_connection" "main" {
  count = var.enable_site_to_site_vpn ? 1 : 0

  customer_gateway_id = aws_customer_gateway.main[0].id
  vpn_gateway_id      = aws_vpn_gateway.main[0].id
  type                = "ipsec.1"
  static_routes_only  = var.vpn_static_routes_only

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-vpn"
  })
}

# VPN 정적 라우트
resource "aws_vpn_connection_route" "main" {
  count = var.enable_site_to_site_vpn && var.vpn_static_routes_only ? length(var.vpn_static_route_cidrs) : 0

  destination_cidr_block = var.vpn_static_route_cidrs[count.index]
  vpn_connection_id      = aws_vpn_connection.main[0].id
}

# 라우트 전파 - 프라이빗 라우팅 테이블
resource "aws_vpn_gateway_route_propagation" "private" {
  count = var.enable_site_to_site_vpn ? 1 : 0

  vpn_gateway_id = aws_vpn_gateway.main[0].id
  route_table_id = aws_route_table.private.id
}

# 라우트 전파 - 퍼블릭 라우팅 테이블 (ALB 응답 경로 확보용)
resource "aws_vpn_gateway_route_propagation" "public" {
  count = var.enable_site_to_site_vpn ? 1 : 0

  vpn_gateway_id = aws_vpn_gateway.main[0].id
  route_table_id = aws_route_table.public.id
}
