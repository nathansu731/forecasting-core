variable "project_name" {
  type    = string
  default = "forecast"
}

variable "region" {
  type    = string
  default = "ap-southeast-2"
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
