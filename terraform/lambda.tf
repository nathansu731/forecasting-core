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
      RAW_BUCKET                      = aws_s3_bucket.raw.bucket
      ARTIFACT_BUCKET                 = aws_s3_bucket.artifacts.bucket
      FORECAST_RUNS_TABLE             = aws_dynamodb_table.forecast_runs.name
      DATA_SNAPSHOTS_TABLE            = aws_dynamodb_table.data_snapshots.name
      NOTIFICATIONS_TABLE             = aws_dynamodb_table.notifications.name
      TENANTS_TABLE                   = aws_dynamodb_table.tenants.name
      ENTITLEMENTS_TABLE              = aws_dynamodb_table.entitlements.name
      LLM_USAGE_TABLE                 = aws_dynamodb_table.llm_usage.name
      ASSISTANT_ENABLED               = tostring(var.assistant_enabled)
      ASSISTANT_CACHE_TTL_SECONDS     = tostring(var.assistant_cache_ttl_seconds)
      ASSISTANT_RATE_LIMIT_PER_MINUTE = tostring(var.assistant_rate_limit_per_minute)
      ASSISTANT_RATE_LIMIT_PER_HOUR   = tostring(var.assistant_rate_limit_per_hour)
      ASSISTANT_OPENAI_TIMEOUT_MS     = tostring(var.assistant_openai_timeout_ms)
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
          aws_dynamodb_table.notifications.arn,
          aws_dynamodb_table.llm_usage.arn
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
  function_name    = "${var.project_name}-orchestrator"
  filename         = data.archive_file.orchestrator_zip.output_path
  source_code_hash = data.archive_file.orchestrator_zip.output_base64sha256
  handler          = "index.handler"
  runtime          = "nodejs18.x"
  role             = aws_iam_role.orchestrator_exec.arn
  timeout          = 30
  memory_size      = 512

  environment {
    variables = {
      RAW_BUCKET                      = aws_s3_bucket.raw.bucket
      ARTIFACT_BUCKET                 = aws_s3_bucket.artifacts.bucket
      FORECAST_RUNS_TABLE             = aws_dynamodb_table.forecast_runs.name
      DATA_SNAPSHOTS_TABLE            = aws_dynamodb_table.data_snapshots.name
      FORECAST_LAMBDA_ARN             = aws_lambda_function.fn.arn
      NOTIFICATIONS_TABLE             = aws_dynamodb_table.notifications.name
      TENANTS_TABLE                   = aws_dynamodb_table.tenants.name
      ENTITLEMENTS_TABLE              = aws_dynamodb_table.entitlements.name
      LLM_USAGE_TABLE                 = aws_dynamodb_table.llm_usage.name
      OPENAI_API_KEY                  = var.openai_api_key
      OPENAI_MODEL                    = var.openai_model
      ASSISTANT_ENABLED               = tostring(var.assistant_enabled)
      ASSISTANT_CACHE_TTL_SECONDS     = tostring(var.assistant_cache_ttl_seconds)
      ASSISTANT_RATE_LIMIT_PER_MINUTE = tostring(var.assistant_rate_limit_per_minute)
      ASSISTANT_RATE_LIMIT_PER_HOUR   = tostring(var.assistant_rate_limit_per_hour)
      ASSISTANT_OPENAI_TIMEOUT_MS     = tostring(var.assistant_openai_timeout_ms)
    }
  }
}

# Lambda execution role
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
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
          aws_dynamodb_table.notifications.arn,
          aws_dynamodb_table.llm_usage.arn
        ]
      }
    ]
  })
}
