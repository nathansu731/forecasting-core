terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws     = { source = "hashicorp/aws", version = ">= 5.0" }
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
