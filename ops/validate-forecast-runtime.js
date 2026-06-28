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
const sqsTf = read("terraform/sqs.tf");
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
  'FunctionName: FORECAST_LAMBDA_ARN',
  "non-local forecast dispatch is not invoking the forecast Lambda directly"
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
  'function_name    = aws_lambda_function.orchestrator.arn',
  "forecast_local_runs queue is not mapped to the orchestrator Lambda"
);
assertIncludes(
  sqsTf,
  'function_name    = aws_lambda_function.fn.arn',
  "forecast_local_batches queue is not mapped to the forecast runtime Lambda"
);

if (failures.length > 0) {
  console.error("Forecast runtime validation failed:");
  for (const failure of failures) {
    console.error(`- ${failure}`);
  }
  process.exit(1);
}

console.log("Forecast runtime validation passed.");
