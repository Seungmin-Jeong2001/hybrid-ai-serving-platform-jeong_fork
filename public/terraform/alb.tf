# ALB 보안 그룹
resource "aws_security_group" "internal_alb" {
  name        = "${var.project_name}-internal-alb-sg"
  description = "Security group for the internal ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Allow HTTP from within the VPC"
    from_port   = 80
    to_port     = 80
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
    Name = "${var.project_name}-internal-alb-sg"
  })
}

# 내부 ALB
resource "aws_lb" "internal" {
  name               = substr("${var.project_name}-internal-alb", 0, 32)
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.internal_alb.id]
  subnets            = aws_subnet.eks_private[*].id

  enable_deletion_protection = var.internal_alb_deletion_protection

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-internal-alb"
  })
}

# ALB 타깃 그룹
resource "aws_lb_target_group" "internal" {
  name        = substr("${var.project_name}-internal-tg", 0, 32)
  port        = var.internal_alb_target_port
  protocol    = "HTTP"
  target_type = var.internal_alb_target_type
  vpc_id      = aws_vpc.main.id

  health_check {
    enabled             = true
    path                = var.internal_alb_health_check_path
    protocol            = "HTTP"
    matcher             = "200-399"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-internal-tg"
  })
}

# ALB 리스너
resource "aws_lb_listener" "internal_http" {
  load_balancer_arn = aws_lb.internal.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.internal.arn
  }
}
