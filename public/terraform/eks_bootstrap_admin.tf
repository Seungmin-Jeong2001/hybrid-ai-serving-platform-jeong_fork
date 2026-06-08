data "aws_iam_policy_document" "eks_bootstrap_admin_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.eks_node_group.arn]
    }
  }
}

resource "aws_iam_role" "eks_bootstrap_admin" {
  name               = "${var.project_name}-eks-bootstrap-admin"
  assume_role_policy = data.aws_iam_policy_document.eks_bootstrap_admin_assume.json

  tags = local.common_tags
}

data "aws_iam_policy_document" "eks_bootstrap_admin_describe_cluster" {
  statement {
    effect    = "Allow"
    actions   = ["eks:DescribeCluster"]
    resources = [aws_eks_cluster.main.arn]
  }
}

resource "aws_iam_role_policy" "eks_bootstrap_admin_describe_cluster" {
  name   = "${var.project_name}-eks-bootstrap-admin-describe-cluster"
  role   = aws_iam_role.eks_bootstrap_admin.id
  policy = data.aws_iam_policy_document.eks_bootstrap_admin_describe_cluster.json
}

data "aws_iam_policy_document" "eks_bootstrap_admin_tfstate_access" {
  statement {
    effect  = "Allow"
    actions = ["s3:ListBucket"]
    resources = [
      "arn:aws:s3:::sgs-hasp-tfstate",
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = [
      "arn:aws:s3:::sgs-hasp-tfstate/terraform/*",
    ]
  }
}

resource "aws_iam_role_policy" "eks_bootstrap_admin_tfstate_access" {
  name   = "${var.project_name}-eks-bootstrap-admin-tfstate-access"
  role   = aws_iam_role.eks_bootstrap_admin.id
  policy = data.aws_iam_policy_document.eks_bootstrap_admin_tfstate_access.json
}

data "aws_iam_policy_document" "eks_node_group_assume_bootstrap_admin" {
  statement {
    effect    = "Allow"
    actions   = ["sts:AssumeRole"]
    resources = [aws_iam_role.eks_bootstrap_admin.arn]
  }
}

resource "aws_iam_role_policy" "eks_node_group_assume_bootstrap_admin" {
  name   = "${var.project_name}-eks-node-group-assume-bootstrap-admin"
  role   = aws_iam_role.eks_node_group.id
  policy = data.aws_iam_policy_document.eks_node_group_assume_bootstrap_admin.json
}

resource "aws_eks_access_entry" "eks_bootstrap_admin" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_iam_role.eks_bootstrap_admin.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "eks_bootstrap_admin" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_iam_role.eks_bootstrap_admin.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.eks_bootstrap_admin]
}
