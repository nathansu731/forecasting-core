# Forecasting Core

## Node Version

This repo now standardizes on Node 24 for local scripts, CodeBuild, and the managed Node Lambda runtime.

If you use `nvm`:

`nvm use`

## Prod Deploy Runbook

First-time prod bootstrap is still a two-step flow because the Lambda image function needs an image in ECR before Terraform can create the function.

1. Create the prod ECR repo with a targeted Terraform apply.
   - If `503492729080` is a brand new prod account, use a separate local Terraform workspace first so you do not reuse another account's local state:
     `cd terraform`
     `terraform workspace new prod || terraform workspace select prod`
     `cd ..`
   - Verify the wrapper is using the expected prod AWS identity:
     `./ops/deploy-prod.sh whoami`
   - Review the resolved prod settings:
     `./ops/deploy-prod.sh show-config`
   - Initialize Terraform for the prod wrapper:
     `./ops/deploy-prod.sh terraform-init`
   - Create only the ECR repository and pull policy first:
     `./ops/deploy-prod.sh terraform-apply -target=aws_ecr_repository.repo -target=aws_ecr_repository_policy.lambda_pull`

2. Push the image with `docker-build`, `ecr-login`, `docker-push`.
   - For the first bootstrap only, use the same tag as `initial_image_uri` in `terraform/prod.tfvars`:
     `IMAGE_TAG=latest ./ops/deploy-prod.sh docker-build`
   - Validate the forecast runtime contract before building:
     `./ops/deploy-prod.sh validate-runtime`
   - Build the image:
     `IMAGE_TAG=latest ./ops/deploy-prod.sh docker-build`
   - Authenticate Docker to prod ECR:
     `IMAGE_TAG=latest ./ops/deploy-prod.sh ecr-login`
     `IMAGE_TAG=latest ./ops/deploy-prod.sh whoami`
   - Push the image:
     `IMAGE_TAG=latest ./ops/deploy-prod.sh docker-push`

3. Run full prod `terraform-apply`.
   - Apply the full stack now that the image exists:
       `terraform workspace select prod`
       `./ops/deploy-prod.sh terraform-apply`
   - This is the step that creates the Lambda and the rest of the prod infrastructure.

4. After the Lambdas exist, use `backend-deploy` for normal updates.
   - The normal update flow now defaults the image tag to the current git SHA.
   - Build, push, and update both forecast-runtime Lambda images in one flow:
     `DEPLOY_AWS_PROFILE=ark-prod ./ops/deploy-prod.sh backend-deploy`
   - Promote a tested git-sha image to a release tag:
     `./ops/deploy-prod.sh promote-release <git-sha-tag> <release-tag>`
   - Promote a tested release tag to the prod tag:
     `./ops/deploy-prod.sh promote-prod <release-tag> prod`
   - Roll the Lambda to the promoted prod tag:
     `IMAGE_TAG=prod ./ops/deploy-prod.sh lambda-update`

The local batch worker is capped independently from global forecast runs. If a global asynchronous invocation exhausts its retry window, Lambda writes its invocation record to the `forecasting-forecast-global-failures` SQS queue; this queue has no poller and therefore creates no idle SQS traffic.

For the dev account, use the same identity check pattern with:
`./ops/deploy-dev.sh whoami`

The forecast runtime smoke payload fixture lives at:
`ops/smoke/forecast-run-payload.json`

To run a live smoke invoke against the deployed forecast Lambda:
`./ops/deploy-prod.sh smoke-forecast ops/smoke/forecast-run-payload.json`
