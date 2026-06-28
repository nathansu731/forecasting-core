output "ecr_repository_url" { value = aws_ecr_repository.repo.repository_url }
output "artifact_bucket" { value = aws_s3_bucket.artifacts.bucket }
output "pipeline_name" { value = var.enable_pipeline ? aws_codepipeline.pipeline[0].name : null }
output "lambda_function" { value = aws_lambda_function.fn.function_name }
output "appsync_api_url" { value = aws_appsync_graphql_api.api.uris["GRAPHQL"] }
output "raw_bucket_name" { value = aws_s3_bucket.raw.bucket }
output "artifacts_bucket_name" { value = aws_s3_bucket.artifacts.bucket }
output "forecast_runs_table" { value = aws_dynamodb_table.forecast_runs.name }
output "data_snapshots_table" { value = aws_dynamodb_table.data_snapshots.name }
output "entitlements_table" { value = aws_dynamodb_table.entitlements.name }
output "tenants_table" { value = aws_dynamodb_table.tenants.name }
output "notifications_table" { value = aws_dynamodb_table.notifications.name }
output "saved_reports_table" { value = aws_dynamodb_table.saved_reports.name }
output "data_sources_table" { value = aws_dynamodb_table.data_sources.name }
output "llm_usage_table" { value = aws_dynamodb_table.llm_usage.name }
output "data_source_worker_schedule_name" {
  value = length(aws_cloudwatch_event_rule.data_source_worker_schedule) > 0 ? aws_cloudwatch_event_rule.data_source_worker_schedule[0].name : null
}
output "dashboard_backend_env" {
  value = {
    APPSYNC_API_URL              = aws_appsync_graphql_api.api.uris["GRAPHQL"]
    AWS_REGION                   = var.region
    COGNITO_REGION               = var.region
    COGNITO_USER_POOL_ID         = var.cognito_user_pool_id
    DATA_SOURCES_TABLE           = aws_dynamodb_table.data_sources.name
    ENTITLEMENTS_TABLE           = aws_dynamodb_table.entitlements.name
    LLM_USAGE_TABLE              = aws_dynamodb_table.llm_usage.name
    NEXT_PUBLIC_GRAPHQL_ENDPOINT = aws_appsync_graphql_api.api.uris["GRAPHQL"]
    NOTIFICATIONS_TABLE          = aws_dynamodb_table.notifications.name
    S3_RAW_BUCKET                = aws_s3_bucket.raw.bucket
    SAVED_REPORTS_TABLE          = aws_dynamodb_table.saved_reports.name
    TENANTS_TABLE                = aws_dynamodb_table.tenants.name
    WORKER_CRON_TOKEN            = var.data_source_worker_cron_token
  }
  sensitive = true
}
