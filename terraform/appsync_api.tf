# ---------- AppSync ----------
resource "aws_appsync_graphql_api" "api" {
  name                = "${var.project_name}-api"
  authentication_type = "AMAZON_COGNITO_USER_POOLS"

  user_pool_config {
    user_pool_id   = var.cognito_user_pool_id
    aws_region     = var.region
    default_action = "ALLOW"
  }

  xray_enabled = true
  schema       = file("${path.module}/schema.graphql")
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
      type        = "Service"
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
