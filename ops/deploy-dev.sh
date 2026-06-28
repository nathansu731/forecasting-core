#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export DEPLOY_ENV="dev"
export AWS_PROFILE="${DEPLOY_AWS_PROFILE:-ark-dev}"
export AWS_REGION="${AWS_REGION:-ap-southeast-2}"
export EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID:-323155024975}"
export TF_VARS_FILE="${TF_VARS_FILE:-${SCRIPT_DIR}/../terraform/dev.tfvars}"
export ENABLE_PIPELINE="${ENABLE_PIPELINE:-true}"
export ECR_REPOSITORY_NAME="${ECR_REPOSITORY_NAME:-forecasting-core}"
export LOCAL_IMAGE_NAME="${LOCAL_IMAGE_NAME:-forecasting-core}"
export LAMBDA_FUNCTION_NAME="${LAMBDA_FUNCTION_NAME:-forecasting-core-fn}"

exec "${SCRIPT_DIR}/lib/backend-deploy-common.sh" "$@"
