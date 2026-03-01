locals {
  enable_data_source_worker_schedule = trimspace(var.data_source_worker_run_due_url) != "" && trimspace(var.data_source_worker_cron_token) != ""
}

data "aws_iam_policy_document" "events_api_destination_assume" {
  count = local.enable_data_source_worker_schedule ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_cloudwatch_event_connection" "data_source_worker" {
  count              = local.enable_data_source_worker_schedule ? 1 : 0
  name               = "${var.project_name}-data-source-worker-conn"
  authorization_type = "API_KEY"
  description        = "Auth for inventory dashboard due-sync worker endpoint"

  auth_parameters {
    api_key {
      key   = "x-worker-token"
      value = var.data_source_worker_cron_token
    }
  }
}

resource "aws_cloudwatch_event_api_destination" "data_source_worker" {
  count                            = local.enable_data_source_worker_schedule ? 1 : 0
  name                             = "${var.project_name}-data-source-worker-destination"
  description                      = "POST /api/internal/data-sources/run-due"
  connection_arn                   = aws_cloudwatch_event_connection.data_source_worker[0].arn
  invocation_endpoint              = var.data_source_worker_run_due_url
  http_method                      = "POST"
  invocation_rate_limit_per_second = 1
}

resource "aws_iam_role" "data_source_worker_scheduler_invoke" {
  count              = local.enable_data_source_worker_schedule ? 1 : 0
  name               = "${var.project_name}-data-source-worker-schedule-role"
  assume_role_policy = data.aws_iam_policy_document.events_api_destination_assume[0].json
}

resource "aws_iam_role_policy" "data_source_worker_scheduler_invoke" {
  count = local.enable_data_source_worker_schedule ? 1 : 0
  role  = aws_iam_role.data_source_worker_scheduler_invoke[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["events:InvokeApiDestination"]
        Resource = [aws_cloudwatch_event_api_destination.data_source_worker[0].arn]
      }
    ]
  })
}

resource "aws_cloudwatch_event_rule" "data_source_worker_schedule" {
  count               = local.enable_data_source_worker_schedule ? 1 : 0
  name                = "${var.project_name}-data-source-worker-schedule"
  description         = "Periodic trigger for inventory data source due sync worker"
  schedule_expression = var.data_source_worker_cron_expression
}

resource "aws_cloudwatch_event_target" "data_source_worker_schedule" {
  count    = local.enable_data_source_worker_schedule ? 1 : 0
  rule     = aws_cloudwatch_event_rule.data_source_worker_schedule[0].name
  arn      = aws_cloudwatch_event_api_destination.data_source_worker[0].arn
  role_arn = aws_iam_role.data_source_worker_scheduler_invoke[0].arn
  input = jsonencode({
    limit = 25
  })
}
