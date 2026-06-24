data "aws_acm_certificate" "alb" {
  count = trimspace(var.alb_certificate_arn) == "" ? 1 : 0

  domain      = var.alb_certificate_domain
  statuses    = ["ISSUED"]
  most_recent = true
}

locals {
  effective_alb_certificate_arn = trimspace(var.alb_certificate_arn) != "" ? trimspace(var.alb_certificate_arn) : data.aws_acm_certificate.alb[0].arn
}
