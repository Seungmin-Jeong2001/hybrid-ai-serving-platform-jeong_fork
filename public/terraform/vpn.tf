# Virtual Private Gateway (VPC당 1개)
resource "aws_vpn_gateway" "main" {
  count = var.enable_site_to_site_vpn ? 1 : 0

  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-vgw"
  })
}

# Customer Gateway (사이트별)
resource "aws_customer_gateway" "sites" {
  for_each = var.enable_site_to_site_vpn ? var.customer_gateways : {}

  bgp_asn    = each.value.bgp_asn
  ip_address = each.value.ip
  type       = "ipsec.1"

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-cgw-${each.key}"
  })
}

# Site-to-Site VPN (사이트별)
resource "aws_vpn_connection" "sites" {
  for_each = var.enable_site_to_site_vpn ? var.customer_gateways : {}

  customer_gateway_id = aws_customer_gateway.sites[each.key].id
  vpn_gateway_id      = aws_vpn_gateway.main[0].id
  type                = "ipsec.1"
  static_routes_only  = var.vpn_static_routes_only

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-vpn-${each.key}"
  })
}

# VPN 정적 라우트 (사이트별 CIDR 목록을 flat하게 전개)
locals {
  vpn_static_routes = var.enable_site_to_site_vpn && var.vpn_static_routes_only ? flatten([
    for site, cidrs in var.vpn_static_route_cidrs : [
      for cidr in cidrs : {
        site = site
        cidr = cidr
      }
    ]
  ]) : []
}

resource "aws_vpn_connection_route" "sites" {
  for_each = {
    for r in local.vpn_static_routes : "${r.site}/${r.cidr}" => r
  }

  destination_cidr_block = each.value.cidr
  vpn_connection_id      = aws_vpn_connection.sites[each.value.site].id
}

# 라우트 전파 - 프라이빗 라우팅 테이블
resource "aws_vpn_gateway_route_propagation" "private" {
  count = var.enable_site_to_site_vpn ? 1 : 0

  vpn_gateway_id = aws_vpn_gateway.main[0].id
  route_table_id = aws_route_table.private.id
}
