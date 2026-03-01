# ---------- IAM: CodeBuild roles ----------
data "aws_iam_policy_document" "codebuild_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
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
      { Effect = "Allow", Action = ["logs:*"], Resource = "*" },
      { Effect = "Allow", Action = ["ecr:*"], Resource = "*" },
      { Effect = "Allow", Action = ["sts:GetCallerIdentity"], Resource = "*" },
      { Effect = "Allow", Action = ["s3:*"], Resource = "*" }
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
      { Effect = "Allow", Action = ["logs:*"], Resource = "*" },
      { Effect = "Allow", Action = ["s3:GetObject", "s3:GetObjectVersion"], Resource = [aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/*"] },
      { Effect = "Allow", Action = ["lambda:UpdateFunctionCode", "lambda:GetFunction", "lambda:PublishVersion"], Resource = "*" }
    ]
  })
}

# ---------- CodeBuild projects ----------
resource "aws_codebuild_project" "build" {
  name         = "${var.project_name}-build"
  service_role = aws_iam_role.cb_build_role.arn
  artifacts { type = "CODEPIPELINE" }
  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/standard:7.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true
    environment_variable {
      name  = "AWS_DEFAULT_REGION"
      value = var.region
    }
  }
  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec-build.yml"
  }
  queued_timeout = 60
}

resource "aws_codebuild_project" "deploy" {
  name         = "${var.project_name}-deploy"
  service_role = aws_iam_role.cb_deploy_role.arn
  artifacts { type = "CODEPIPELINE" }
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
    type      = "CODEPIPELINE"
    buildspec = "buildspec-deploy.yml"
  }
  queued_timeout = 30
}

# ---------- IAM: CodePipeline ----------
data "aws_iam_policy_document" "codepipeline_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
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
      { Effect = "Allow", Action = ["s3:*"], Resource = [aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/*"] },
      { Effect = "Allow", Action = ["codebuild:BatchGetBuilds", "codebuild:StartBuild"], Resource = "*" },
      { Effect = "Allow", Action = ["codestar-connections:UseConnection"], Resource = var.codestar_connection_arn }
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
        ConnectionArn    = var.codestar_connection_arn
        FullRepositoryId = "${var.github_owner}/${var.github_repo}"
        BranchName       = var.github_branch
        DetectChanges    = "true"
      }
    }
  }

  stage {
    name = "Build"
    action {
      name             = "DockerBuild"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["SourceOutput"]
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
      category        = "Build"
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
