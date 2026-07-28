resource "aws_sqs_queue" "forecast_global_failures" {
  name                      = "${var.project_name}-forecast-global-failures"
  message_retention_seconds = 1209600
}

resource "aws_sqs_queue" "forecast_global_runs" {
  name                       = "${var.project_name}-forecast-global-runs"
  visibility_timeout_seconds = 360
  message_retention_seconds  = 1209600

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.forecast_global_failures.arn
    maxReceiveCount     = 3
  })
}

resource "aws_sqs_queue" "forecast_local_runs" {
  name                       = "${var.project_name}-forecast-local-runs"
  visibility_timeout_seconds = 120
  message_retention_seconds  = 1209600
}

resource "aws_sqs_queue" "forecast_local_batches" {
  name                       = "${var.project_name}-forecast-local-batches"
  visibility_timeout_seconds = 360
  message_retention_seconds  = 1209600
}

resource "aws_lambda_event_source_mapping" "forecast_global_runs" {
  event_source_arn = aws_sqs_queue.forecast_global_runs.arn
  function_name    = aws_lambda_function.fn.arn
  batch_size       = 1
  enabled          = true

  scaling_config {
    maximum_concurrency = var.forecast_global_max_concurrency
  }
}

resource "aws_lambda_event_source_mapping" "forecast_local_dispatch" {
  event_source_arn = aws_sqs_queue.forecast_local_runs.arn
  function_name    = aws_lambda_function.orchestrator.arn
  batch_size       = 1
  enabled          = true
}

resource "aws_lambda_event_source_mapping" "forecast_local_batches" {
  event_source_arn = aws_sqs_queue.forecast_local_batches.arn
  function_name    = aws_lambda_function.local_batch_worker.arn
  batch_size       = 1
  enabled          = true

  scaling_config {
    maximum_concurrency = var.local_batch_worker_max_concurrency
  }
}
