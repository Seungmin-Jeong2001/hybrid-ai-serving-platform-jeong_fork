# SES - 이상 감지 시 고객사 이메일 알림
resource "aws_ses_email_identity" "alert_sender" {
  email = var.ses_alert_sender_email
}
