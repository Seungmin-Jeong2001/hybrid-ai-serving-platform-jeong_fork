# DynamoDB 테이블 - 고객사 대시보드용 추론 결과 저장
# DynamoDB 테이블 - 장비별 이상 상태 관리 (이메일 알림 중복 방지용)
resource "aws_dynamodb_table" "equipment_alert_state" {
  name         = "${var.project_name}-equipment-alert-state"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "equipment_id"

  attribute {
    name = "equipment_id"
    type = "S"
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-equipment-alert-state"
  })
}


resource "aws_dynamodb_table" "inference_results" {
  name         = "${var.project_name}-inference-results"
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
    Name = "${var.project_name}-inference-results"
  })
}
