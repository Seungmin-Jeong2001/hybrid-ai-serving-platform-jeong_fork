terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "tls_certificate" "gitlab_oidc" {
  url = var.gitlab_oidc_url
}

locals {
  ecr_repository_arn = "arn:aws:ecr:${var.aws_region}:${var.aws_account_id}:repository/${var.ecr_repository_name}"
}

resource "aws_iam_openid_connect_provider" "gitlab" {
  url = var.gitlab_oidc_url

  client_id_list = [
    "sts.amazonaws.com",
  ]

  thumbprint_list = [
    data.tls_certificate.gitlab_oidc.certificates[0].sha1_fingerprint,
  ]
}

data "aws_iam_policy_document" "gitlab_oidc_assume_role" {
  statement {
    effect = "Allow"

    actions = [
      "sts:AssumeRoleWithWebIdentity",
    ]

    principals {
      type = "Federated"

      identifiers = [
        aws_iam_openid_connect_provider.gitlab.arn,
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.gitlab_oidc_host}:aud"

      values = [
        "sts.amazonaws.com",
      ]
    }

    condition {
      test     = "StringLike"
      variable = "${var.gitlab_oidc_host}:sub"

      values = [
        var.gitlab_project_sub,
      ]
    }
  }
}

resource "aws_iam_role" "gitlab_ecr_promotion" {
  name               = var.role_name
  assume_role_policy = data.aws_iam_policy_document.gitlab_oidc_assume_role.json
}

data "aws_iam_policy_document" "gitlab_ecr_promotion" {
  statement {
    sid    = "AllowEcrAuthorizationToken"
    effect = "Allow"

    actions = [
      "ecr:GetAuthorizationToken",
    ]

    resources = [
      "*",
    ]
  }

  statement {
    sid    = "AllowPredictiveModelRepositoryPush"
    effect = "Allow"

    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:ListImages",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]

    resources = [
      local.ecr_repository_arn,
    ]
  }
}

resource "aws_iam_role_policy" "gitlab_ecr_promotion" {
  name   = "${var.role_name}-policy"
  role   = aws_iam_role.gitlab_ecr_promotion.id
  policy = data.aws_iam_policy_document.gitlab_ecr_promotion.json
}
