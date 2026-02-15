terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 5.0" }
    archive = { source = "hashicorp/archive", version = ">= 2.4.0" }
  }
}

provider "aws" {
  region = var.region
}

locals {
  ecr_name        = "forecasting-core"
  artifact_bucket = "${var.project_name}-artifacts-${data.aws_caller_identity.me.account_id}"
  raw_bucket      = "${var.project_name}-raw-${data.aws_caller_identity.me.account_id}"
}

data "aws_caller_identity" "me" {}

# ---------- ECR ----------
resource "aws_ecr_repository" "repo" {
  name = local.ecr_name
  image_scanning_configuration { scan_on_push = true }
  force_delete = true
}
# Allow Lambda to pull images
resource "aws_ecr_repository_policy" "lambda_pull" {
  repository = aws_ecr_repository.repo.name

  policy = jsonencode({
    Version = "2008-10-17"
    Statement = [
      {
        Sid      = "AllowLambdaPull"
        Effect   = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = [
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda_ecr_pull" {
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer"
        ],
        Resource = "*"
      }
    ]
  })
}


# ---------- S3 for artifacts ----------
resource "aws_s3_bucket" "artifacts" {
  bucket        = local.artifact_bucket
  force_destroy = true
}
resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration { status = "Enabled" }
}
resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ---------- S3 for raw uploads ----------
resource "aws_s3_bucket" "raw" {
  bucket        = local.raw_bucket
  force_destroy = true
}
resource "aws_s3_bucket_versioning" "raw" {
  bucket = aws_s3_bucket.raw.id
  versioning_configuration { status = "Enabled" }
}
resource "aws_s3_bucket_server_side_encryption_configuration" "raw" {
  bucket = aws_s3_bucket.raw.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_cors_configuration" "raw" {
  bucket = aws_s3_bucket.raw.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "PUT", "POST", "HEAD"]
    allowed_origins = ["http://localhost:3000"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}

# ---------- DynamoDB ----------
resource "aws_dynamodb_table" "forecast_runs" {
  name         = "${var.project_name}-forecast-runs"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "PK"
  range_key    = "SK"

  attribute {
    name = "PK"
    type = "S"
  }
  attribute {
    name = "SK"
    type = "S"
  }
}

resource "aws_dynamodb_table" "data_snapshots" {
  name         = "${var.project_name}-data-snapshots"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "PK"
  range_key    = "SK"

  attribute {
    name = "PK"
    type = "S"
  }
  attribute {
    name = "SK"
    type = "S"
  }
}

resource "aws_dynamodb_table" "entitlements" {
  name         = "${var.project_name}-entitlements"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "tenantId"

  attribute {
    name = "tenantId"
    type = "S"
  }
}

resource "aws_dynamodb_table" "tenants" {
  name         = "${var.project_name}-tenants"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "tenantId"

  attribute {
    name = "tenantId"
    type = "S"
  }
}

resource "aws_dynamodb_table" "notifications" {
  name         = "${var.project_name}-notifications"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "PK"
  range_key    = "SK"

  attribute {
    name = "PK"
    type = "S"
  }
  attribute {
    name = "SK"
    type = "S"
  }
  attribute {
    name = "GSI1PK"
    type = "S"
  }
  attribute {
    name = "GSI1SK"
    type = "S"
  }

  global_secondary_index {
    name            = "byTenantCreatedAt"
    hash_key        = "GSI1PK"
    range_key       = "GSI1SK"
    projection_type = "ALL"
  }
}


# ---------- IAM: CodeBuild roles ----------
data "aws_iam_policy_document" "codebuild_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cb_build_role" {
  name               = "${var.project_name}-cb-build"
  assume_role_policy = data.aws_iam_policy_document.codebuild_assume.json
}

resource "aws_iam_role_policy" "cb_build_policy" {
  role = aws_iam_role.cb_build_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect="Allow", Action=["logs:*"], Resource="*" },
      { Effect="Allow", Action=["ecr:*"], Resource="*" },
      { Effect="Allow", Action=["sts:GetCallerIdentity"], Resource="*" },
      { Effect="Allow", Action=["s3:*"], Resource="*" }
    ]
  })
}

resource "aws_iam_role" "cb_deploy_role" {
  name               = "${var.project_name}-cb-deploy"
  assume_role_policy = data.aws_iam_policy_document.codebuild_assume.json
}
resource "aws_iam_role_policy" "cb_deploy_policy" {
  role = aws_iam_role.cb_deploy_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect="Allow", Action=["logs:*"], Resource="*" },
      { Effect="Allow", Action=["s3:GetObject","s3:GetObjectVersion"], Resource=[aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/*"] },
      { Effect="Allow", Action=["lambda:UpdateFunctionCode","lambda:GetFunction","lambda:PublishVersion"], Resource="*" }
    ]
  })
}

# ---------- CodeBuild projects ----------
resource "aws_codebuild_project" "build" {
  name          = "${var.project_name}-build"
  service_role  = aws_iam_role.cb_build_role.arn
  artifacts     { type = "CODEPIPELINE" }
  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:7.0"
    type                        = "LINUX_CONTAINER"
    privileged_mode             = true # docker-in-docker
    environment_variable {
      name  = "AWS_DEFAULT_REGION"
      value = var.region
    }
  }
  source {
    type = "CODEPIPELINE"
    buildspec   = "buildspec-build.yml"

  }
  queued_timeout  = 60
}

resource "aws_codebuild_project" "deploy" {
  name          = "${var.project_name}-deploy"
  service_role  = aws_iam_role.cb_deploy_role.arn
  artifacts     { type = "CODEPIPELINE" }
  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/standard:7.0"
    type         = "LINUX_CONTAINER"
    environment_variable {
      name  = "LAMBDA_FUNCTION_NAME"
      value = var.lambda_function_name
    }
  }
  source {
    type = "CODEPIPELINE"
    buildspec   = "buildspec-deploy.yml"
  }
  queued_timeout  = 30
}

# ---------- IAM: CodePipeline ----------
data "aws_iam_policy_document" "codepipeline_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type = "Service"
      identifiers = ["codepipeline.amazonaws.com"]
    }
  }
}
resource "aws_iam_role" "cp_role" {
  name               = "${var.project_name}-codepipeline"
  assume_role_policy = data.aws_iam_policy_document.codepipeline_assume.json
}
resource "aws_iam_role_policy" "cp_policy" {
  role = aws_iam_role.cp_role.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      { Effect="Allow", Action=["s3:*"], Resource=[aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/*"] },
      { Effect="Allow", Action=["codebuild:BatchGetBuilds","codebuild:StartBuild"], Resource="*" },
      { Effect="Allow", Action=["codestar-connections:UseConnection"], Resource=var.codestar_connection_arn }
    ]
  })
}

# ---------- CodePipeline ----------
resource "aws_codepipeline" "pipeline" {
  name     = "${var.project_name}-pipeline"
  role_arn = aws_iam_role.cp_role.arn

  artifact_store {
    type     = "S3"
    location = aws_s3_bucket.artifacts.bucket
  }

  stage {
    name = "Source"
    action {
      name             = "GitHub"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["SourceOutput"]
      configuration = {
        ConnectionArn        = var.codestar_connection_arn
        FullRepositoryId     = "${var.github_owner}/${var.github_repo}"
        BranchName           = var.github_branch
        DetectChanges        = "true"
      }
    }
  }

  stage {
    name = "Build"
    action {
      name            = "DockerBuild"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["SourceOutput"]
      output_artifacts = ["BuildOutput"]
      configuration = {
        ProjectName = aws_codebuild_project.build.name
      }
    }
  }

  stage {
    name = "Deploy"
    action {
      name            = "UpdateLambdaImage"
      category        = "Build"     # using CodeBuild to run CLI
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["BuildOutput"]
      configuration = {
        ProjectName = aws_codebuild_project.deploy.name
      }
    }
  }
}

# ---------- Lambda (container image) ----------
resource "aws_lambda_function" "fn" {
  function_name = var.lambda_function_name
  package_type  = "Image"
  image_uri     = var.initial_image_uri
  role          = aws_iam_role.lambda_exec.arn
  timeout       = 120
  memory_size   = 1024
  architectures = ["x86_64"]
  environment {
    variables = {
      RAW_BUCKET           = aws_s3_bucket.raw.bucket
      ARTIFACT_BUCKET      = aws_s3_bucket.artifacts.bucket
      FORECAST_RUNS_TABLE  = aws_dynamodb_table.forecast_runs.name
      DATA_SNAPSHOTS_TABLE = aws_dynamodb_table.data_snapshots.name
      NOTIFICATIONS_TABLE  = aws_dynamodb_table.notifications.name
    }
  }
}

# ---------- Orchestrator Lambda (Node.js) ----------
data "archive_file" "orchestrator_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../src/orchestrator"
  output_path = "${path.module}/orchestrator.zip"
}

data "aws_iam_policy_document" "orchestrator_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "orchestrator_exec" {
  name               = "${var.project_name}-orchestrator-exec"
  assume_role_policy = data.aws_iam_policy_document.orchestrator_assume.json
}

resource "aws_iam_role_policy_attachment" "orchestrator_logs" {
  role       = aws_iam_role.orchestrator_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "orchestrator_data_access" {
  role = aws_iam_role.orchestrator_exec.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.raw.arn,
          "${aws_s3_bucket.raw.arn}/*",
          aws_s3_bucket.artifacts.arn,
          "${aws_s3_bucket.artifacts.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:Query"
        ]
        Resource = [
          aws_dynamodb_table.forecast_runs.arn,
          aws_dynamodb_table.data_snapshots.arn,
          aws_dynamodb_table.entitlements.arn,
          aws_dynamodb_table.tenants.arn,
          aws_dynamodb_table.notifications.arn
        ]
      },
      {
        Effect = "Allow"
        Action = ["lambda:InvokeFunction"]
        Resource = [
          aws_lambda_function.fn.arn,
          "${aws_lambda_function.fn.arn}:*"
        ]
      }
    ]
  })
}

resource "aws_lambda_function" "orchestrator" {
  function_name = "${var.project_name}-orchestrator"
  filename      = data.archive_file.orchestrator_zip.output_path
  source_code_hash = data.archive_file.orchestrator_zip.output_base64sha256
  handler       = "index.handler"
  runtime       = "nodejs18.x"
  role          = aws_iam_role.orchestrator_exec.arn
  timeout       = 30
  memory_size   = 512

  environment {
    variables = {
      RAW_BUCKET           = aws_s3_bucket.raw.bucket
      ARTIFACT_BUCKET      = aws_s3_bucket.artifacts.bucket
      FORECAST_RUNS_TABLE  = aws_dynamodb_table.forecast_runs.name
      DATA_SNAPSHOTS_TABLE = aws_dynamodb_table.data_snapshots.name
      FORECAST_LAMBDA_ARN  = aws_lambda_function.fn.arn
      NOTIFICATIONS_TABLE  = aws_dynamodb_table.notifications.name
    }
  }
}

# Lambda execution role
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}
resource "aws_iam_role" "lambda_exec" {
  name               = "${var.project_name}-lambda-exec"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}
resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
resource "aws_iam_role_policy_attachment" "lambda_ecr" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy" "lambda_data_access" {
  role = aws_iam_role.lambda_exec.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.raw.arn,
          "${aws_s3_bucket.raw.arn}/*",
          aws_s3_bucket.artifacts.arn,
          "${aws_s3_bucket.artifacts.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:Query"
        ]
        Resource = [
          aws_dynamodb_table.forecast_runs.arn,
          aws_dynamodb_table.data_snapshots.arn,
          aws_dynamodb_table.entitlements.arn,
          aws_dynamodb_table.tenants.arn,
          aws_dynamodb_table.notifications.arn
        ]
      }
    ]
  })
}

# ---------- AppSync ----------
resource "aws_appsync_graphql_api" "api" {
  name                = "${var.project_name}-api"
  authentication_type = "AMAZON_COGNITO_USER_POOLS"

  user_pool_config {
    user_pool_id = var.cognito_user_pool_id
    aws_region   = var.region
    default_action = "ALLOW"
  }

  xray_enabled = true
  schema = file("${path.module}/schema.graphql")
}

# Lambda datasource
resource "aws_appsync_datasource" "lambda" {
  api_id           = aws_appsync_graphql_api.api.id
  name             = "LambdaSource"
  type             = "AWS_LAMBDA"
  service_role_arn = aws_iam_role.appsync_lambda_role.arn

  lambda_config {
    function_arn = aws_lambda_function.fn.arn
  }
}

resource "aws_appsync_datasource" "orchestrator" {
  api_id           = aws_appsync_graphql_api.api.id
  name             = "OrchestratorSource"
  type             = "AWS_LAMBDA"
  service_role_arn = aws_iam_role.appsync_lambda_role.arn

  lambda_config {
    function_arn = aws_lambda_function.orchestrator.arn
  }
}

# IAM role for AppSync to invoke Lambda
data "aws_iam_policy_document" "appsync_lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type = "Service"
      identifiers = ["appsync.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "appsync_lambda_role" {
  name               = "${var.project_name}-appsync-lambda"
  assume_role_policy = data.aws_iam_policy_document.appsync_lambda_assume.json
}

resource "aws_iam_role_policy" "appsync_lambda_invoke" {
  role = aws_iam_role.appsync_lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["lambda:InvokeFunction"]
        Resource = [
          aws_lambda_function.fn.arn,
          "${aws_lambda_function.fn.arn}:*",
          aws_lambda_function.orchestrator.arn,
          "${aws_lambda_function.orchestrator.arn}:*"
        ]
      }
    ]
  })
}

# ----------------- Appsync Resolvers -------------------------
resource "aws_appsync_resolver" "run_forecast_test" {
  api_id      = aws_appsync_graphql_api.api.id
  type        = "Query"
  field       = "runForecastTest"
  data_source = aws_appsync_datasource.lambda.name
  kind        = "UNIT"

  request_template = <<EOF
{
  "version": "2018-05-29",
  "operation": "Invoke",
  "payload": {
    "info": {
      "fieldName": "runForecastTest"
    },
    "input": $util.toJson($context.arguments)
  }
}
EOF

  response_template = <<EOF
$util.toJson($context.result)
EOF
}

resource "aws_appsync_resolver" "get_skus_metadata" {
  api_id      = aws_appsync_graphql_api.api.id
  type        = "Query"
  field       = "getSKUsMetadata"
  data_source = aws_appsync_datasource.orchestrator.name
  kind        = "UNIT"

  request_template = <<EOF
{
  "version": "2018-05-29",
  "operation": "Invoke",
  "payload": {
    "info": {
      "fieldName": "getSKUsMetadata"
    },
    "identity": $util.toJson($context.identity),
    "request": {
      "headers": $util.toJson($context.request.headers)
    }
  }
}
EOF

  response_template = <<EOF
$util.toJson($context.result)
EOF
}

resource "aws_appsync_resolver" "get_report_summary" {
  api_id      = aws_appsync_graphql_api.api.id
  type        = "Query"
  field       = "getReportSummary"
  data_source = aws_appsync_datasource.orchestrator.name
  kind        = "UNIT"

  request_template = <<EOF
{
  "version": "2018-05-29",
  "operation": "Invoke",
  "payload": {
    "info": {
      "fieldName": "getReportSummary"
    },
    "identity": $util.toJson($context.identity),
    "request": {
      "headers": $util.toJson($context.request.headers)
    }
  }
}
EOF

  response_template = <<EOF
$util.toJson($context.result)
EOF
}

resource "aws_appsync_resolver" "get_sku_forecasts" {
  api_id      = aws_appsync_graphql_api.api.id
  type        = "Query"
  field       = "getSKUForecasts"
  data_source = aws_appsync_datasource.orchestrator.name
  kind        = "UNIT"

  request_template = <<EOF
{
  "version": "2018-05-29",
  "operation": "Invoke",
  "payload": {
    "info": {
      "fieldName": "getSKUForecasts"
    },
    "identity": $util.toJson($context.identity),
    "request": {
      "headers": $util.toJson($context.request.headers)
    }
  }
}
EOF

  response_template = <<EOF
$util.toJson($context.result)
EOF
}

resource "aws_appsync_resolver" "get_monthly_totals" {
  api_id      = aws_appsync_graphql_api.api.id
  type        = "Query"
  field       = "getMonthlyTotals"
  data_source = aws_appsync_datasource.orchestrator.name
  kind        = "UNIT"

  request_template = <<EOF
{
  "version": "2018-05-29",
  "operation": "Invoke",
  "payload": {
    "info": {
      "fieldName": "getMonthlyTotals"
    },
    "identity": $util.toJson($context.identity),
    "request": {
      "headers": $util.toJson($context.request.headers)
    }
  }
}
EOF

  response_template = <<EOF
$util.toJson($context.result)
EOF
}

resource "aws_appsync_resolver" "get_daily_forecasts" {
  api_id      = aws_appsync_graphql_api.api.id
  type        = "Query"
  field       = "getDailyForecasts"
  data_source = aws_appsync_datasource.orchestrator.name
  kind        = "UNIT"

  request_template = <<EOF
{
  "version": "2018-05-29",
  "operation": "Invoke",
  "payload": {
    "info": {
      "fieldName": "getDailyForecasts"
    },
    "identity": $util.toJson($context.identity),
    "request": {
      "headers": $util.toJson($context.request.headers)
    }
  }
}
EOF

  response_template = <<EOF
$util.toJson($context.result)
EOF
}

resource "aws_appsync_resolver" "get_sku_forecast_values" {
  api_id      = aws_appsync_graphql_api.api.id
  type        = "Query"
  field       = "getSkuForecastValues"
  data_source = aws_appsync_datasource.orchestrator.name
  kind        = "UNIT"

  request_template = <<EOF
{
  "version": "2018-05-29",
  "operation": "Invoke",
  "payload": {
    "info": {
      "fieldName": "getSkuForecastValues"
    },
    "identity": $util.toJson($context.identity),
    "request": {
      "headers": $util.toJson($context.request.headers)
    }
  }
}
EOF

  response_template = <<EOF
$util.toJson($context.result)
EOF
}

resource "aws_appsync_resolver" "start_forecast_run" {
  api_id      = aws_appsync_graphql_api.api.id
  type        = "Mutation"
  field       = "startForecastRun"
  data_source = aws_appsync_datasource.orchestrator.name
  kind        = "UNIT"

  request_template = <<EOF
{
  "version": "2018-05-29",
  "operation": "Invoke",
  "payload": {
    "info": {
      "fieldName": "startForecastRun"
    },
    "input": $util.toJson($context.arguments),
    "identity": $util.toJson($context.identity),
    "request": {
      "headers": $util.toJson($context.request.headers)
    }
  }
}
EOF

  response_template = <<EOF
$util.toJson($context.result)
EOF
}

resource "aws_appsync_resolver" "get_forecast_run" {
  api_id      = aws_appsync_graphql_api.api.id
  type        = "Query"
  field       = "getForecastRun"
  data_source = aws_appsync_datasource.orchestrator.name
  kind        = "UNIT"

  request_template = <<EOF
{
  "version": "2018-05-29",
  "operation": "Invoke",
  "payload": {
    "info": {
      "fieldName": "getForecastRun"
    },
    "input": $util.toJson($context.arguments),
    "identity": $util.toJson($context.identity),
    "request": {
      "headers": $util.toJson($context.request.headers)
    }
  }
}
EOF

  response_template = <<EOF
$util.toJson($context.result)
EOF
}

resource "aws_appsync_resolver" "list_forecast_runs" {
  api_id      = aws_appsync_graphql_api.api.id
  type        = "Query"
  field       = "listForecastRuns"
  data_source = aws_appsync_datasource.orchestrator.name
  kind        = "UNIT"

  request_template = <<EOF
{
  "version": "2018-05-29",
  "operation": "Invoke",
  "payload": {
    "info": {
      "fieldName": "listForecastRuns"
    },
    "input": $util.toJson($context.arguments),
    "identity": $util.toJson($context.identity),
    "request": {
      "headers": $util.toJson($context.request.headers)
    }
  }
}
EOF

  response_template = <<EOF
$util.toJson($context.result)
EOF
}

resource "aws_appsync_resolver" "list_notifications" {
  api_id      = aws_appsync_graphql_api.api.id
  type        = "Query"
  field       = "listNotifications"
  data_source = aws_appsync_datasource.orchestrator.name
  kind        = "UNIT"

  request_template = <<EOF
{
  "version": "2018-05-29",
  "operation": "Invoke",
  "payload": {
    "info": {
      "fieldName": "listNotifications"
    },
    "input": $util.toJson($context.arguments),
    "identity": $util.toJson($context.identity),
    "request": {
      "headers": $util.toJson($context.request.headers)
    }
  }
}
EOF

  response_template = <<EOF
$util.toJson($context.result)
EOF
}

resource "aws_appsync_resolver" "mark_notification_read" {
  api_id      = aws_appsync_graphql_api.api.id
  type        = "Mutation"
  field       = "markNotificationRead"
  data_source = aws_appsync_datasource.orchestrator.name
  kind        = "UNIT"

  request_template = <<EOF
{
  "version": "2018-05-29",
  "operation": "Invoke",
  "payload": {
    "info": {
      "fieldName": "markNotificationRead"
    },
    "input": $util.toJson($context.arguments),
    "identity": $util.toJson($context.identity),
    "request": {
      "headers": $util.toJson($context.request.headers)
    }
  }
}
EOF

  response_template = <<EOF
$util.toJson($context.result)
EOF
}

# ------------------ /Appsync Resolvers -------------------------

output "appsync_api_url" {
  value = aws_appsync_graphql_api.api.uris["GRAPHQL"]
}
output "raw_bucket_name" {
  value = aws_s3_bucket.raw.bucket
}

output "artifacts_bucket_name" {
  value = aws_s3_bucket.artifacts.bucket
}

output "forecast_runs_table" {
  value = aws_dynamodb_table.forecast_runs.name
}

output "data_snapshots_table" {
  value = aws_dynamodb_table.data_snapshots.name
}

output "tenants_table" {
  value = aws_dynamodb_table.tenants.name
}

output "notifications_table" {
  value = aws_dynamodb_table.notifications.name
}
