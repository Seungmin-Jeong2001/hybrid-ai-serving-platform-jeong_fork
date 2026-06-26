# === IRSA: argocd-image-updater-controller가 private ECR 태그를 조회하기 위한 IAM 구성 ===

locals {
  predictive_model_ecr_repository_arn = format(
    "arn:aws:ecr:%s:%s:repository/predictive-model",
    var.aws_region,
    data.aws_caller_identity.current.account_id,
  )
}

data "aws_iam_policy_document" "argocd_image_updater_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.eks_oidc_provider}:sub"
      values   = ["system:serviceaccount:argocd:argocd-image-updater-controller"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.eks_oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "argocd_image_updater" {
  name               = "${var.project_name}-argocd-image-updater"
  assume_role_policy = data.aws_iam_policy_document.argocd_image_updater_assume.json

  tags = local.common_tags
}

data "aws_iam_policy_document" "argocd_image_updater_ecr" {
  statement {
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
      "ecr:GetDownloadUrlForLayer",
      "ecr:ListImages",
    ]
    resources = [local.predictive_model_ecr_repository_arn]
  }
}

resource "aws_iam_policy" "argocd_image_updater_ecr" {
  name   = "${var.project_name}-argocd-image-updater-ecr"
  policy = data.aws_iam_policy_document.argocd_image_updater_ecr.json

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "argocd_image_updater_ecr" {
  role       = aws_iam_role.argocd_image_updater.name
  policy_arn = aws_iam_policy.argocd_image_updater_ecr.arn
}
