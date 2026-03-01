variable "project_name" {
  type    = string
  default = "forecast"
}

variable "region" {
  type    = string
  default = "ap-southeast-2"
}

variable "cognito_user_pool_id" {
  type = string
}

# GitHub (CodeStar connection)
variable "codestar_connection_arn" {
  type = string
}

variable "github_owner" {
  type = string
}

variable "github_repo" {
  type = string
}

variable "github_branch" {
  type    = string
  default = "main"
}

# Lambda
variable "lambda_function_name" {
  type    = string
  default = "forecast-lambda"
}

# Bootstrap image for first create
variable "initial_image_uri" {
  type    = string
  default = ""
}

# Data source worker scheduler (optional; disabled by default)
variable "data_source_worker_run_due_url" {
  type    = string
  default = ""
}

variable "data_source_worker_cron_expression" {
  type    = string
  default = "rate(5 minutes)"
}

variable "data_source_worker_cron_token" {
  type      = string
  default   = ""
  sensitive = true
}
