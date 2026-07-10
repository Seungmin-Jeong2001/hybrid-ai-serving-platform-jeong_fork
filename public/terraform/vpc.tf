data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  common_tags = {
    Project   = var.project_name
    ManagedBy = "terraform"
  }
}

# VPC 생성
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-vpc"
  })
}

# 인터넷 게이트웨이
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-igw"
  })
}

# 퍼블릭 서브넷
resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidrs)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name                                            = "${var.project_name}-public-${count.index + 1}"
    "kubernetes.io/role/elb"                        = "1"
    "kubernetes.io/cluster/${var.project_name}-eks" = "shared"
  })
}

# EKS 프라이빗 서브넷
resource "aws_subnet" "eks_private" {
  count = length(var.eks_private_subnet_cidrs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.eks_private_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = merge(local.common_tags, {
    Name                                            = "${var.project_name}-eks-private-${count.index + 1}"
    "kubernetes.io/role/internal-elb"               = "1"
    "kubernetes.io/cluster/${var.project_name}-eks" = "shared"
  })
}

# MSK 프라이빗 서브넷
resource "aws_subnet" "msk_private" {
  count = length(var.msk_private_subnet_cidrs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.msk_private_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-msk-private-${count.index + 1}"
  })
}

# 퍼블릭 라우팅 테이블
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-public-rt"
  })
}

# NAT EIP (AZ별 1개)
resource "aws_eip" "nat" {
  count = length(aws_subnet.public)

  domain = "vpc"

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-nat-eip-${count.index + 1}"
  })
}

# NAT 게이트웨이 (Public Subnet / AZ별 1개)
resource "aws_nat_gateway" "main" {
  count = length(aws_subnet.public)

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-nat-${count.index + 1}"
  })

  depends_on = [aws_internet_gateway.main]
}

# 프라이빗 라우팅 테이블 (AZ별 1개, 동일 AZ NAT로 egress)
resource "aws_route_table" "private" {
  count = length(aws_subnet.eks_private)

  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[count.index].id
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-private-rt-${count.index + 1}"
  })
}

# 퍼블릭 서브넷 연결
resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# EKS 서브넷 연결
resource "aws_route_table_association" "eks_private" {
  count = length(aws_subnet.eks_private)

  subnet_id      = aws_subnet.eks_private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# MSK 서브넷 연결
resource "aws_route_table_association" "msk_private" {
  count = length(aws_subnet.msk_private)

  subnet_id      = aws_subnet.msk_private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

