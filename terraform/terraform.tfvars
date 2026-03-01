codestar_connection_arn = "arn:aws:codeconnections:ap-southeast-2:323155024975:connection/4c46497b-532a-4284-9481-690701315c88"
github_owner            = "nathansu731"
github_repo             = "forecasting-core"
github_branch           = "main"
project_name            = "forecasting"
region                  = "ap-southeast-2"
cognito_user_pool_id    = "ap-southeast-2_H2HTaeDYt"
lambda_function_name    = "forecasting-core-fn"
initial_image_uri       = "323155024975.dkr.ecr.ap-southeast-2.amazonaws.com/forecasting-core:latest"

# Optional: schedule inventory dashboard data-source due sync worker.
data_source_worker_run_due_url   = "https://inventory-dashboard-git-main-nathansu731-2993s-projects.vercel.app/api/internal/data-sources/run-due"
data_source_worker_cron_expression = "rate(5 minutes)"
data_source_worker_cron_token    = "<same-as-WORKER_CRON_TOKEN>"
