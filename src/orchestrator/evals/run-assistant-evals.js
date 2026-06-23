const fs = require("fs");
const path = require("path");

const { generateForecastAssistantResponse } = require("../lib/handlers");
const {
  ddb,
  marshall,
  unmarshall,
  QueryCommand,
  FORECAST_RUNS_TABLE,
  ARTIFACT_BUCKET,
  getTenantSettings,
  getLatestRun,
  getRunById,
  readJsonFromS3,
  normalizeRun,
} = require("../lib/shared");

const DEFAULT_PACK = "offline";
const PACK_PATHS = {
  offline: path.join(__dirname, "assistant-evals.json"),
  staging: path.join(__dirname, "assistant-evals.staging.json"),
};
const LOCAL_EVAL_ENV_PATH = path.join(__dirname, "..", ".env.eval");

const loadLocalEvalEnv = () => {
  if (!fs.existsSync(LOCAL_EVAL_ENV_PATH)) {
    return;
  }

  const lines = fs.readFileSync(LOCAL_EVAL_ENV_PATH, "utf8").split(/\r?\n/);
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const separatorIndex = trimmed.indexOf("=");
    if (separatorIndex <= 0) continue;

    const key = trimmed.slice(0, separatorIndex).trim();
    let value = trimmed.slice(separatorIndex + 1).trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }

    if (!process.env[key]) {
      process.env[key] = value;
    }
  }
};

loadLocalEvalEnv();

const getCliArg = (flag) => {
  const index = process.argv.indexOf(flag);
  if (index < 0) return null;
  return process.argv[index + 1] || null;
};

const selectedPack = getCliArg("--pack") || process.env.ASSISTANT_EVAL_PACK || DEFAULT_PACK;
const packPath = PACK_PATHS[selectedPack] || selectedPack;

const normalizeText = (value) => String(value || "").toLowerCase();

const aggregateResponseText = (response) =>
  [
    response.assistantText,
    ...(response.checklist || []),
    ...(response.suggestedPrompts || []),
    ...(response.warnings || []),
    ...((response.evidence || []).flatMap((item) => [item.title, item.detail, item.source])),
    ...((response.steps || []).flatMap((step) => [step.title, step.description, step.action?.route || "", step.action?.label || ""])),
  ]
    .map((item) => String(item || ""))
    .join("\n")
    .toLowerCase();

const loadPack = () => JSON.parse(fs.readFileSync(packPath, "utf8"));

const listRecentRunsForEval = async (tenantId, limit = 10) => {
  const result = await ddb.send(
    new QueryCommand({
      TableName: FORECAST_RUNS_TABLE,
      KeyConditionExpression: "PK = :pk AND begins_with(SK, :sk)",
      ExpressionAttributeValues: marshall({
        ":pk": `TENANT#${tenantId}`,
        ":sk": "RUN#",
      }),
      ScanIndexForward: false,
      Limit: limit,
    })
  );
  return (result.Items || []).map((item) => normalizeRun(unmarshall(item))).filter(Boolean);
};

const loadArtifactsForRun = async (run) => {
  const prefix = run?.s3OutputPrefix;
  if (!prefix) {
    return {
      summary: null,
      metadata: null,
      monthlyTotals: null,
      replenishmentSignals: null,
      skuForecastValues: null,
    };
  }

  const readSafe = async (keySuffix) => {
    try {
      return await readJsonFromS3(ARTIFACT_BUCKET, `${prefix}/${keySuffix}`);
    } catch {
      return null;
    }
  };

  return {
    summary: (await readSafe("report_summary.json")) || run.summary || null,
    metadata: await readSafe("metadata.json"),
    monthlyTotals: await readSafe("monthly_totals.json"),
    replenishmentSignals: await readSafe("replenishment_signals.json"),
    skuForecastValues: await readSafe("sku_forecast_values.json"),
  };
};

const resolveStagingValue = (runtime, key, fallbackInputValue) => {
  const envKey = runtime?.[key];
  if (!envKey) return fallbackInputValue || null;
  return process.env[envKey] || fallbackInputValue || null;
};

const resolveFixtureData = async (fixture) => {
  if (fixture.mode === "offline") {
    const resolved = fixture.resolvedData || {};
    return {
      tenantId: resolved.tenantId || "offline-tenant",
      tenantSettings: resolved.tenantSettings || null,
      run: resolved.run || null,
      recentRuns: resolved.recentRuns || [],
      summary: resolved.summary || null,
      metadata: resolved.metadata || null,
      monthlyTotals: resolved.monthlyTotals || null,
      replenishmentSignals: resolved.replenishmentSignals || null,
      skuForecastValues: resolved.skuForecastValues || null,
      input: fixture.input,
    };
  }

  const tenantId = process.env[fixture.runtime?.tenantIdEnv || ""];
  if (!tenantId) {
    return { skipped: true, reason: `missing env ${fixture.runtime?.tenantIdEnv}` };
  }

  const runId = resolveStagingValue(fixture.runtime, "runIdEnv", fixture.input?.runId);
  const selectedSku = resolveStagingValue(fixture.runtime, "selectedSkuEnv", fixture.input?.selectedSku);
  const selectedStore = resolveStagingValue(fixture.runtime, "selectedStoreEnv", fixture.input?.selectedStore);
  const run = runId ? await getRunById(tenantId, runId) : await getLatestRun(tenantId);
  const tenantSettings = await getTenantSettings(tenantId);
  const recentRuns = await listRecentRunsForEval(tenantId, 10);
  const artifacts = await loadArtifactsForRun(run);

  return {
    tenantId,
    tenantSettings,
    run,
    recentRuns,
    ...artifacts,
    input: {
      ...fixture.input,
      selectedSku,
      selectedStore,
      runId: run?.runId || runId || null,
    },
  };
};

const evaluateAssertions = (fixture, response) => {
  const failures = [];
  const assertions = fixture.assertions || {};
  const responseText = aggregateResponseText(response);
  const routes = (response.steps || [])
    .map((step) => step?.action?.route)
    .filter((value) => typeof value === "string");

  if (assertions.expectedIntent && response.intent !== assertions.expectedIntent) {
    failures.push(`expected intent ${assertions.expectedIntent}, got ${response.intent}`);
  }

  (assertions.expectedContains || []).forEach((token) => {
    if (!responseText.includes(normalizeText(token))) {
      failures.push(`missing expected text: ${token}`);
    }
  });

  (assertions.forbiddenContains || []).forEach((token) => {
    if (responseText.includes(normalizeText(token))) {
      failures.push(`forbidden text found: ${token}`);
    }
  });

  (assertions.expectedRoutes || []).forEach((route) => {
    if (!routes.includes(route)) {
      failures.push(`missing expected route: ${route}`);
    }
  });

  (assertions.forbiddenRoutes || []).forEach((route) => {
    if (routes.includes(route)) {
      failures.push(`forbidden route found: ${route}`);
    }
  });

  if (Number.isFinite(Number(assertions.minEvidenceCount)) && (response.evidence || []).length < Number(assertions.minEvidenceCount)) {
    failures.push(`expected at least ${assertions.minEvidenceCount} evidence items, got ${(response.evidence || []).length}`);
  }

  if (Number.isFinite(Number(assertions.minWarningsCount)) && (response.warnings || []).length < Number(assertions.minWarningsCount)) {
    failures.push(`expected at least ${assertions.minWarningsCount} warnings, got ${(response.warnings || []).length}`);
  }

  if (Number.isFinite(Number(assertions.minConfidence)) && Number(response.confidence) < Number(assertions.minConfidence)) {
    failures.push(`confidence ${response.confidence} below minimum ${assertions.minConfidence}`);
  }

  if (Number.isFinite(Number(assertions.maxConfidence)) && Number(response.confidence) > Number(assertions.maxConfidence)) {
    failures.push(`confidence ${response.confidence} above maximum ${assertions.maxConfidence}`);
  }

  return failures;
};

const runFixture = async (fixture) => {
  const resolved = await resolveFixtureData(fixture);
  if (resolved.skipped) {
    return { id: fixture.id, status: "SKIPPED", failures: [resolved.reason] };
  }

  const result = await generateForecastAssistantResponse({
    command: resolved.input.command,
    run: resolved.run,
    runId: resolved.input.runId || resolved.run?.runId || null,
    tenantSettings: resolved.tenantSettings,
    pageContext: {
      pageId: resolved.input.pageId || null,
      route: resolved.input.route || null,
      contextMode: resolved.input.contextMode || "analysis",
      selectedSku: resolved.input.selectedSku || null,
      selectedStore: resolved.input.selectedStore || null,
    },
    summary: resolved.summary,
    metadata: resolved.metadata,
    monthlyTotals: resolved.monthlyTotals,
    replenishmentSignals: resolved.replenishmentSignals,
    skuForecastValues: resolved.skuForecastValues,
    recentRuns: resolved.recentRuns,
  });

  const failures = evaluateAssertions(fixture, result.response);
  return {
    id: fixture.id,
    status: failures.length === 0 ? "PASS" : "FAIL",
    failures,
    response: result.response,
  };
};

const main = async () => {
  if (!process.env.OPENAI_API_KEY) {
    throw new Error("OPENAI_API_KEY is required to run assistant evals");
  }
  const pack = loadPack();
  const results = [];
  for (const fixture of pack.fixtures || []) {
    results.push(await runFixture(fixture));
  }

  let passCount = 0;
  let failCount = 0;
  let skipCount = 0;

  results.forEach((result) => {
    if (result.status === "PASS") {
      passCount += 1;
      console.log(`PASS ${result.id}`);
      return;
    }
    if (result.status === "SKIPPED") {
      skipCount += 1;
      console.log(`SKIP ${result.id}: ${result.failures.join("; ")}`);
      return;
    }
    failCount += 1;
    console.log(`FAIL ${result.id}`);
    result.failures.forEach((failure) => console.log(`  - ${failure}`));
    if (result.response?.assistantText) {
      console.log(`  assistantText: ${result.response.assistantText}`);
    }
  });

  console.log(`\nassistant-evals summary: ${passCount} passed, ${failCount} failed, ${skipCount} skipped`);
  if (failCount > 0) {
    process.exitCode = 1;
  }
};

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
