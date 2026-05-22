# DynamoDB 테이블
resource "aws_dynamodb_table" "inference_jobs" {
  name         = "${var.project_name}-inference-jobs"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "request_id"

  attribute {
    name = "request_id"
    type = "S"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-inference-jobs"
  })
}
