#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${OPS_DIR}/.." && pwd)"
TERRAFORM_DIR="${REPO_ROOT}/terraform"
SRC_DIR="${REPO_ROOT}/src"
RUNTIME_VALIDATOR="${REPO_ROOT}/ops/validate-forecast-runtime.js"
SMOKE_INVOKE_SCRIPT="${REPO_ROOT}/ops/smoke/invoke-forecast-smoke.js"
DEFAULT_IMAGE_TAG="$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || printf 'latest')"

DEPLOY_ENV="${DEPLOY_ENV:-unknown}"
AWS_REGION="${AWS_REGION:-ap-southeast-2}"
EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID:-}"
ECR_REPOSITORY_NAME="${ECR_REPOSITORY_NAME:-forecasting-core}"
LOCAL_IMAGE_NAME="${LOCAL_IMAGE_NAME:-forecasting-core}"
IMAGE_TAG="${IMAGE_TAG:-${DEFAULT_IMAGE_TAG}}"
LAMBDA_FUNCTION_NAME="${LAMBDA_FUNCTION_NAME:-forecasting-core-fn}"
TF_VARS_FILE="${TF_VARS_FILE:-}"
ENABLE_PIPELINE="${ENABLE_PIPELINE:-true}"

AWS_PAGER=""
export AWS_PAGER AWS_REGION

die() {
  echo "error: $*" 1>&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

require_file() {
  [[ -f "$1" ]] || die "required file not found: $1"
}

show_config() {
  cat <<EOF
Environment:           ${DEPLOY_ENV}
AWS profile:           ${AWS_PROFILE:-<default>}
AWS region:            ${AWS_REGION}
Expected account:      ${EXPECTED_ACCOUNT_ID}
Terraform vars file:   ${TF_VARS_FILE}
Enable pipeline:       ${ENABLE_PIPELINE}
Lambda function name:  ${LAMBDA_FUNCTION_NAME}
ECR repository:        ${ECR_REPOSITORY_NAME}
Image tag:             ${IMAGE_TAG}
Default release tag:   release-${IMAGE_TAG}
Default prod tag:      prod
EOF
}

current_account_id() {
  aws sts get-caller-identity --query Account --output text
}

whoami() {
  require_command aws
  aws sts get-caller-identity
}

assert_account() {
  require_command aws
  [[ -n "${EXPECTED_ACCOUNT_ID}" ]] || die "EXPECTED_ACCOUNT_ID is not set"

  local actual_account
  actual_account="$(current_account_id)"
  if [[ "${actual_account}" != "${EXPECTED_ACCOUNT_ID}" ]]; then
    die "authenticated account ${actual_account} does not match expected ${EXPECTED_ACCOUNT_ID} for ${DEPLOY_ENV}"
  fi
}

terraform_args() {
  require_command terraform
  [[ -n "${TF_VARS_FILE}" ]] || die "TF_VARS_FILE is not set"
  require_file "${TF_VARS_FILE}"
  TERRAFORM_ARGS=(
    "-var-file=${TF_VARS_FILE}"
    "-var=enable_pipeline=${ENABLE_PIPELINE}"
  )
}

terraform_init() {
  assert_account
  require_command terraform
  terraform -chdir="${TERRAFORM_DIR}" init
}

terraform_plan() {
  assert_account
  require_command terraform
  require_file "${TF_VARS_FILE}"

  local -a TERRAFORM_ARGS
  terraform_args
  terraform -chdir="${TERRAFORM_DIR}" plan "${TERRAFORM_ARGS[@]}" "$@"
}

terraform_apply() {
  assert_account
  require_command terraform
  require_file "${TF_VARS_FILE}"

  local -a TERRAFORM_ARGS
  terraform_args
  terraform -chdir="${TERRAFORM_DIR}" apply "${TERRAFORM_ARGS[@]}" "$@"
}

validate_runtime() {
  require_command node
  require_file "${RUNTIME_VALIDATOR}"
  node "${RUNTIME_VALIDATOR}"
}

ecr_promote() {
  assert_account
  require_command aws

  local source_tag="${1:-}"
  local target_tag="${2:-}"
  [[ -n "${source_tag}" ]] || die "source image tag is required"
  [[ -n "${target_tag}" ]] || die "target image tag is required"

  local manifest
  manifest="$(aws ecr batch-get-image \
    --repository-name "${ECR_REPOSITORY_NAME}" \
    --image-ids imageTag="${source_tag}" \
    --query 'images[0].imageManifest' \
    --output text)"
  [[ -n "${manifest}" && "${manifest}" != "None" ]] || die "image tag not found in ECR: ${source_tag}"

  aws ecr put-image \
    --repository-name "${ECR_REPOSITORY_NAME}" \
    --image-tag "${target_tag}" \
    --image-manifest "${manifest}" >/dev/null

  echo "Promoted ${ECR_REPOSITORY_NAME}:${source_tag} -> ${ECR_REPOSITORY_NAME}:${target_tag}"
}

promote_release() {
  local source_tag="${1:-${IMAGE_TAG}}"
  local target_tag="${2:-release-${source_tag}}"
  ecr_promote "${source_tag}" "${target_tag}"
}

promote_prod() {
  local source_tag="${1:-}"
  local target_tag="${2:-prod}"
  [[ -n "${source_tag}" ]] || die "source image tag is required for promote-prod"
  ecr_promote "${source_tag}" "${target_tag}"
}

smoke_forecast() {
  assert_account
  require_command node
  require_command aws
  require_file "${SMOKE_INVOKE_SCRIPT}"

  local payload_file="${1:-${REPO_ROOT}/ops/smoke/forecast-run-payload.json}"
  require_file "${payload_file}"

  node "${SMOKE_INVOKE_SCRIPT}" \
    --function-name "${LAMBDA_FUNCTION_NAME}" \
    --payload-file "${payload_file}"
}

ecr_repository_uri() {
  printf '%s.dkr.ecr.%s.amazonaws.com/%s' "${EXPECTED_ACCOUNT_ID}" "${AWS_REGION}" "${ECR_REPOSITORY_NAME}"
}

docker_build() {
  assert_account
  require_command docker
  require_file "${SRC_DIR}/Dockerfile"
  validate_runtime
  docker build -f "${SRC_DIR}/Dockerfile" -t "${LOCAL_IMAGE_NAME}:${IMAGE_TAG}" "${SRC_DIR}"
}

ecr_login() {
  assert_account
  require_command aws
  require_command docker
  local repo_uri
  repo_uri="$(ecr_repository_uri)"
  aws ecr get-login-password --region "${AWS_REGION}" \
    | docker login --username AWS --password-stdin "${repo_uri}"
}

docker_push() {
  assert_account
  require_command docker
  local repo_uri
  repo_uri="$(ecr_repository_uri)"
  docker tag "${LOCAL_IMAGE_NAME}:${IMAGE_TAG}" "${repo_uri}:${IMAGE_TAG}"
  docker push "${repo_uri}:${IMAGE_TAG}"
}

lambda_update() {
  assert_account
  require_command aws
  local repo_uri
  repo_uri="$(ecr_repository_uri)"
  aws lambda update-function-code \
    --function-name "${LAMBDA_FUNCTION_NAME}" \
    --image-uri "${repo_uri}:${IMAGE_TAG}"
}

backend_deploy() {
  docker_build
  ecr_login
  docker_push
  lambda_update
}

usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [args...]

Commands:
  show-config             Print resolved deploy configuration
  whoami                  Print the AWS identity resolved by this wrapper
  validate-runtime        Validate forecast runtime contract checks before build/release
  promote-release [src] [tag]
                          Promote an existing ECR image tag to a tested release tag
  promote-prod <src> [tag]
                          Promote an existing ECR image tag to the prod tag (default: prod)
  smoke-forecast [file]   Invoke the deployed Lambda with a smoke-test payload
  terraform-init          Run terraform init in ${TERRAFORM_DIR}
  terraform-plan [args]   Run terraform plan with the environment tfvars
  terraform-apply [args]  Run terraform apply with the environment tfvars
  docker-build            Build the forecasting Lambda image from ${SRC_DIR}
  ecr-login               Authenticate Docker to the target account ECR repo
  docker-push             Tag and push the image to the target account ECR repo
  lambda-update           Update the Lambda image to the pushed tag
  backend-deploy          Build, push, and update the Lambda image

Environment overrides:
  DEPLOY_AWS_PROFILE
  AWS_REGION
  IMAGE_TAG
  LAMBDA_FUNCTION_NAME
  TF_VARS_FILE
  ENABLE_PIPELINE
EOF
}

main() {
  local command="${1:-help}"
  shift || true

  case "${command}" in
    show-config)
      show_config
      ;;
    whoami)
      whoami
      ;;
    validate-runtime)
      validate_runtime
      ;;
    promote-release)
      promote_release "$@"
      ;;
    promote-prod)
      promote_prod "$@"
      ;;
    smoke-forecast)
      smoke_forecast "$@"
      ;;
    terraform-init)
      terraform_init
      ;;
    terraform-plan)
      terraform_plan "$@"
      ;;
    terraform-apply)
      terraform_apply "$@"
      ;;
    docker-build)
      docker_build
      ;;
    ecr-login)
      ecr_login
      ;;
    docker-push)
      docker_push
      ;;
    lambda-update)
      lambda_update
      ;;
    backend-deploy)
      backend_deploy
      ;;
    help|-h|--help)
      usage
      ;;
    *)
      usage
      die "unknown command: ${command}"
      ;;
  esac
}

main "$@"
