# 아티팩트 버킷
resource "aws_s3_bucket" "artifacts" {
  bucket = var.artifacts_s3_bucket_name != "" ? var.artifacts_s3_bucket_name : lower(var.environment != "" ? "${var.project_name}-${var.environment}-artifacts" : "${var.project_name}-artifacts")

  force_destroy = var.artifacts_s3_force_destroy

  tags = merge(local.common_tags, {
    Name = var.artifacts_s3_bucket_name != "" ? var.artifacts_s3_bucket_name : "${var.project_name}-artifacts"
  })
}

# 버킷 버전 관리
resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}

# 버킷 암호화
resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# 퍼블릭 접근 차단
resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
