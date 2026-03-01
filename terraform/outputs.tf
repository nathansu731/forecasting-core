output "ecr_repository_url" { value = aws_ecr_repository.repo.repository_url }
output "artifact_bucket" { value = aws_s3_bucket.artifacts.bucket }
output "pipeline_name" { value = aws_codepipeline.pipeline.name }
output "lambda_function" { value = aws_lambda_function.fn.function_name }
output "appsync_api_url" { value = aws_appsync_graphql_api.api.uris["GRAPHQL"] }
output "raw_bucket_name" { value = aws_s3_bucket.raw.bucket }
output "artifacts_bucket_name" { value = aws_s3_bucket.artifacts.bucket }
output "forecast_runs_table" { value = aws_dynamodb_table.forecast_runs.name }
output "data_snapshots_table" { value = aws_dynamodb_table.data_snapshots.name }
output "tenants_table" { value = aws_dynamodb_table.tenants.name }
output "notifications_table" { value = aws_dynamodb_table.notifications.name }
output "saved_reports_table" { value = aws_dynamodb_table.saved_reports.name }
output "data_sources_table" { value = aws_dynamodb_table.data_sources.name }
output "data_source_worker_schedule_name" {
  value = length(aws_cloudwatch_event_rule.data_source_worker_schedule) > 0 ? aws_cloudwatch_event_rule.data_source_worker_schedule[0].name : null
}
