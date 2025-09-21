terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 5.0" }
  }
}

provider "aws" {
  region = var.region
}

locals {
  ecr_name        = "forecasting-core" # <-- corrected ECR repo name
  artifact_bucket = "${var.project_name}-artifacts-${data.aws_caller_identity.me.account_id}"
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
    buildspec   = "buildspec-build.yml"
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

# ---------- AppSync ----------
resource "aws_appsync_graphql_api" "api" {
  name                = "${var.project_name}-api"
  authentication_type = "API_KEY"

  additional_authentication_provider {
    authentication_type = "AWS_IAM"
  }

  xray_enabled = true
  schema = file("${path.module}/schema.graphql")
}

resource "aws_appsync_api_key" "key" {
  api_id = aws_appsync_graphql_api.api.id
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
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = aws_lambda_function.fn.arn
      }
    ]
  })
}

# Example resolver
resource "aws_appsync_resolver" "forecast" {
  api_id            = aws_appsync_graphql_api.api.id
  type              = "Query"
  field             = "forecast"
  data_source       = aws_appsync_datasource.lambda.name
  kind              = "UNIT"

  request_template  = <<EOF
{
  "version": "2018-05-29",
  "operation": "Invoke",
  "payload": $util.toJson($context.arguments)
}
EOF

  response_template = <<EOF
$util.toJson($context.result)
EOF
}
