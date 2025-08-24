output "ecr_repository_url" { value = aws_ecr_repository.repo.repository_url }
output "artifact_bucket"   { value = aws_s3_bucket.artifacts.bucket }
output "pipeline_name"     { value = aws_codepipeline.pipeline.name }
output "lambda_function"   { value = aws_lambda_function.fn.function_name }
