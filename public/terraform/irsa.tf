# === IRSA: inference-worker 파드가 DynamoDB(inference-jobs)에 접근하기 위한 IAM 구성 ===
# 흐름: EKS OIDC -> AssumeRoleWithWebIdentity -> 임시 자격증명 -> DynamoDB
# 신뢰 주체는 inference 네임스페이스의 inference-worker ServiceAccount 하나로 한정.

# EKS 클러스터 OIDC 발급자 인증서 (OIDC provider thumbprint 용)
data "tls_certificate" "eks_oidc" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

# IAM OIDC provider 등록 (IRSA의 전제)
resource "aws_iam_openid_connect_provider" "eks" {
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]

  tags = local.common_tags
}

# 신뢰정책 조건 키 prefix (issuer URL에서 https:// 제거)
locals {
  eks_oidc_provider = replace(aws_iam_openid_connect_provider.eks.url, "https://", "")
}

# inference:inference-worker SA만 이 Role을 빌릴 수 있도록 신뢰정책
data "aws_iam_policy_document" "inference_worker_assume" {
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
      values   = ["system:serviceaccount:inference:inference-worker"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.eks_oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "inference_worker" {
  name               = "${var.project_name}-inference-worker"
  assume_role_policy = data.aws_iam_policy_document.inference_worker_assume.json

  tags = local.common_tags
}

# DynamoDB 최소권한: 코드가 실제 쓰는 Get/Put/Update 만, 해당 테이블로 한정
data "aws_iam_policy_document" "inference_worker_dynamodb" {
  statement {
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
    ]
    resources = [aws_dynamodb_table.inference_jobs.arn]
  }
}

resource "aws_iam_policy" "inference_worker_dynamodb" {
  name   = "${var.project_name}-inference-worker-dynamodb"
  policy = data.aws_iam_policy_document.inference_worker_dynamodb.json

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "inference_worker_dynamodb" {
  role       = aws_iam_role.inference_worker.name
  policy_arn = aws_iam_policy.inference_worker_dynamodb.arn
}
