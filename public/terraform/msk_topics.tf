resource "terraform_data" "msk_topics" {
  count = var.manage_msk_topics ? 1 : 0

  triggers_replace = {
    cluster_arn        = aws_msk_cluster.main.arn
    region             = var.aws_region
    replication_factor = tostring(var.msk_topic_replication_factor)
    topic_configs      = jsonencode(var.msk_topic_configs)
    topics             = jsonencode(var.msk_topics)
  }

  provisioner "local-exec" {
    interpreter = ["/bin/sh", "-c"]

    command = "${path.module}/scripts/sync-msk-topics.sh"

    environment = {
      AWS_REGION                   = var.aws_region
      MSK_CLUSTER_ARN              = aws_msk_cluster.main.arn
      MSK_TOPIC_REPLICATION_FACTOR = tostring(var.msk_topic_replication_factor)
      MSK_TOPIC_CONFIGS_JSON       = jsonencode(var.msk_topic_configs)
      MSK_TOPICS_JSON              = jsonencode(var.msk_topics)
    }
  }
}
