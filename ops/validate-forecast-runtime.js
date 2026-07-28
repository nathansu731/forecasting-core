#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");

const repoRoot = path.resolve(__dirname, "..");

const read = (relativePath) => fs.readFileSync(path.join(repoRoot, relativePath), "utf8");

const forecastR = read("src/scripts/forecast.R");
const sharedJs = read("src/orchestrator/lib/shared.js");
const handlersJs = read("src/orchestrator/lib/handlers.js");
const entrypointR = read("src/entrypoint.R");
const localUnivariateModelsR = read("src/scripts/models/local_univariate_models.R");
const sqsTf = read("terraform/sqs.tf");
const lambdaTf = read("terraform/lambda.tf");
const dockerfile = read("src/Dockerfile");
const buildspecBuild = read("buildspec-build.yml");

const requiredArtifacts = [
  "daily_forecasts.json",
  "monthly_totals.json",
  "report_summary.json",
  "replenishment_signals.json",
  "sku_forecast_values.json",
];

const failures = [];

const assertIncludes = (haystack, needle, message) => {
  if (!haystack.includes(needle)) {
    failures.push(message);
  }
};

for (const artifact of requiredArtifacts) {
  assertIncludes(
    forecastR,
    `write_json(paste0(output_prefix, "/${artifact}")`,
    `base forecast output is missing required artifact ${artifact}`
  );
}

assertIncludes(
  forecastR,
  'write_json(paste0(s3_output_prefix, "/sku_forecast_values.json"), base_values)',
  "scenario flow does not republish sku_forecast_values.json"
);

for (const artifact of requiredArtifacts.filter((artifact) => artifact !== "sku_forecast_values.json")) {
  assertIncludes(
    forecastR,
    `"${artifact}"`,
    `scenario flow does not reference required artifact ${artifact}`
  );
}

for (const artifact of requiredArtifacts) {
  assertIncludes(
    sharedJs,
    `"${artifact}"`,
    `orchestrator readiness check does not include ${artifact}`
  );
}

assertIncludes(
  handlersJs,
  'QueueUrl: FORECAST_LOCAL_RUNS_QUEUE_URL',
  "local forecast dispatch is not sending work to the forecast_local_runs queue"
);
assertIncludes(
  handlersJs,
  'QueueUrl: FORECAST_GLOBAL_RUNS_QUEUE_URL',
  "global forecast dispatch is not sending work to the forecast_global_runs queue"
);
assertIncludes(
  entrypointR,
  "is_sqs_event <- !is.null(event$Records)",
  "R entrypoint is not checking for SQS events"
);
assertIncludes(
  entrypointR,
  "run_forecast_pipeline(payload)",
  "R entrypoint is not routing SQS payloads into run_forecast_pipeline"
);
assertIncludes(
  forecastR,
  "assert_runtime_context()",
  "forecast runtime is not revalidating async context against DynamoDB"
);
assertIncludes(
  localUnivariateModelsR,
  'inherits(time_series, "msts")',
  "ARIMA sanitization does not preserve msts seasonal metadata"
);
assertIncludes(
  localUnivariateModelsR,
  'forecast:::msts(numeric_values, seasonal.periods = attr(time_series, "msts"))',
  "ARIMA sanitization does not reconstruct msts inputs with their seasonal periods"
);
if (localUnivariateModelsR.includes("time_series <- as.numeric(time_series)")) {
  failures.push("ARIMA sanitization strips msts seasonal metadata before auto.arima fitting");
}
assertIncludes(
  localUnivariateModelsR,
  "forecast:::forecast.Arima(fit, h = forecast_horizon, biasadj = TRUE)",
  "log-scale ARIMA forecasts are not bias-adjusted after back-transformation"
);
assertIncludes(
  dockerfile,
  "COPY requirements.lock /tmp/requirements.lock",
  "Docker build does not copy the locked package manifest"
);
assertIncludes(
  dockerfile,
  "Using locked CRAN snapshot repo",
  "Docker build does not use the locked CRAN snapshot configuration"
);
assertIncludes(
  buildspecBuild,
  '"gitShaTag":"%s","releaseTag":"%s","prodTag":"%s"',
  "buildspec image metadata does not emit git/release/prod promotion tags"
);
if (buildspecBuild.includes(":latest")) {
  failures.push("buildspec still tags or pushes latest instead of explicit promoted tags");
}
assertIncludes(
  sqsTf,
  'resource "aws_lambda_event_source_mapping" "forecast_global_runs"',
  "global forecast queue is not mapped to the forecast runtime"
);
assertIncludes(
  sqsTf,
  "maximum_concurrency = var.forecast_global_max_concurrency",
  "global forecast queue does not have a bounded consumer concurrency"
);
assertIncludes(
  sqsTf,
  'function_name    = aws_lambda_function.orchestrator.arn',
  "forecast_local_runs queue is not mapped to the orchestrator Lambda"
);
assertIncludes(
  sqsTf,
  'function_name    = aws_lambda_function.local_batch_worker.arn',
  "forecast_local_batches queue is not mapped to the dedicated local batch worker"
);
assertIncludes(
  lambdaTf,
  'resource "aws_lambda_function" "local_batch_worker"',
  "dedicated local batch worker Lambda is missing"
);
assertIncludes(
  sqsTf,
  "maximum_concurrency = var.local_batch_worker_max_concurrency",
  "local batch worker does not have an independent consumer concurrency limit"
);
assertIncludes(
  sqsTf,
  "deadLetterTargetArn = aws_sqs_queue.forecast_global_failures.arn",
  "global forecast failure queue is not configured as a dead-letter queue"
);
assertIncludes(
  sqsTf,
  'resource "aws_sqs_queue" "forecast_global_failures"',
  "global forecast failure queue is missing"
);

if (failures.length > 0) {
  console.error("Forecast runtime validation failed:");
  for (const failure of failures) {
    console.error(`- ${failure}`);
  }
  process.exit(1);
}

console.log("Forecast runtime validation passed.");
