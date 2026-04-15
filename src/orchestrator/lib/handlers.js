const crypto = require("crypto");

const {
  ddb,
  lambda,
  marshall,
  unmarshall,
  PutItemCommand,
  GetItemCommand,
  QueryCommand,
  UpdateItemCommand,
  DeleteItemCommand,
  InvokeCommand,
  RAW_BUCKET,
  ARTIFACT_BUCKET,
  FORECAST_RUNS_TABLE,
  DATA_SNAPSHOTS_TABLE,
  FORECAST_LAMBDA_ARN,
  NOTIFICATIONS_TABLE,
  ENTITLEMENTS_TABLE,
  LLM_USAGE_TABLE,
  OPENAI_API_KEY,
  OPENAI_MODEL,
  ASSISTANT_ENABLED,
  ASSISTANT_CACHE_TTL_SECONDS,
  ASSISTANT_RATE_LIMIT_PER_MINUTE,
  ASSISTANT_RATE_LIMIT_PER_HOUR,
  ASSISTANT_OPENAI_TIMEOUT_MS,
  getTenantId,
  getTenantSettings,
  setTenantSettings,
  setTenantAssistantSummary,
  nowIso,
  randomId,
  getLatestRun,
  getRunById,
  readJsonFromS3,
  outputFilesReady,
  normalizeRun,
  normalizeNotification,
  encodeNextToken,
  decodeNextToken,
  upsertNotification,
  updateNotificationStatus,
  updateRunStatus,
  handleGetResultFile,
} = require("./shared");

const clamp = (value, min, max) => Math.max(min, Math.min(max, value));

const round = (value, digits = 2) => {
  if (typeof value !== "number" || Number.isNaN(value)) return null;
  const scale = 10 ** digits;
  return Math.round(value * scale) / scale;
};

const hashText = (value) => crypto.createHash("sha256").update(String(value || "")).digest("hex").slice(0, 12);

const redactCommand = (value) =>
  String(value || "")
    .replace(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi, "[redacted-email]")
    .replace(/https?:\/\/\S+/gi, "[redacted-url]")
    .replace(/\b\d{7,}\b/g, "[redacted-number]")
    .trim();

const estimateTokens = (value) => Math.ceil(String(value || "").length / 4);

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const summarizeMonthlyTotals = (monthlyTotals) => {
  if (!monthlyTotals || typeof monthlyTotals !== "object") return null;
  const keepKeys = ["totalRevenue", "forecastAccuracy", "totalSKUs", "OutOfStockRisk", "AvgLeadTime"];
  const result = {};
  for (const key of keepKeys) {
    if (Object.prototype.hasOwnProperty.call(monthlyTotals, key)) {
      result[key] = monthlyTotals[key];
    }
  }
  return result;
};

const buildContextPayload = ({ run, summary, metadata, monthlyTotals, replenishmentSignals }) => {
  const metrics = summary?.validation?.selectedModel?.metrics || {};
  const topSkus = Object.entries(metadata || {})
    .slice(0, 8)
    .map(([sku, details]) => ({
      sku: `sku_${hashText(sku)}`,
      abcClass: details?.ABCclass || null,
      method: details?.forecastMethod || null,
    }));

  const replenishmentItems = Array.isArray(replenishmentSignals?.items) ? replenishmentSignals.items : [];
  const highRiskItems = replenishmentItems
    .filter((item) => item?.risk === "High")
    .slice(0, 8)
    .map((item) => ({
      sku: item?.sku ? `sku_${hashText(item.sku)}` : null,
      risk: item?.risk || null,
      reorderByDate: item?.reorderByDate || null,
      recommendedReorderQty: item?.recommendedReorderQty || null,
    }));

  const totalRows = Number(summary?.rows || 0);
  const totalSkus = Number(summary?.totalSkus || 0);
  const coverageRatio = totalSkus > 0 ? clamp(round(totalRows / totalSkus, 2) || 0, 0, 999999) : null;

  return {
    run: {
      runId: run?.runId || null,
      status: run?.status || "UNKNOWN",
      createdAt: run?.createdAt || null,
      updatedAt: run?.updatedAt || null,
      dateStart: summary?.dateStart || null,
      dateEnd: summary?.dateEnd || null,
      frequency: summary?.validation?.frequency || null,
      selectedModel: summary?.validation?.selectedModel || null,
      arimaBaseline: summary?.validation?.arimaBaseline || null,
    },
    dataset: {
      totalRows,
      totalSkus,
      avgRowsPerSku: coverageRatio,
    },
    quality: {
      smape: round(metrics?.smape, 3),
      mae: round(metrics?.mae, 3),
      rmse: round(metrics?.rmse, 3),
      modelStrategy: summary?.validation?.selectedModel?.strategy || null,
      windows: summary?.validation?.selectedModel?.windows || null,
    },
    topSkus,
    monthlyTotals: summarizeMonthlyTotals(monthlyTotals),
    replenishment: {
      horizonDays: replenishmentSignals?.horizonDays || null,
      highRiskCount: highRiskItems.length,
      highRiskItems,
    },
  };
};

const defaultAssistantResponse = (context) => ({
  status: "success",
  intent: "forecast_onboarding",
  assistantText:
    "Connect at least one source, upload the latest dataset, run forecasting, then review quality metrics and replenishment risks.",
  context,
  checklist: [
    "Confirm at least one data source is connected.",
    "Upload a clean file with required columns.",
    "Run forecasting and wait for completion in Notifications.",
    "Review summary, forecast outputs, and replenishment risks.",
  ],
  suggestedPrompts: [
    "Guide me through getting my first forecast.",
    "Explain forecast quality for the latest run.",
    "Summarize replenishment risks for this run.",
  ],
  steps: [
    {
      id: "connect-source",
      title: "Connect source",
      description: "Connect Shopify, QuickBooks, BigCommerce, or Amazon and import selected tables.",
      status: "pending",
      action: { id: "go-data-input", label: "Open Data Input", route: "/data-input", kind: "navigate" },
    },
    {
      id: "run-forecast",
      title: "Start forecast run",
      description: "Upload your dataset and launch a forecast run from Data Input.",
      status: "pending",
      action: { id: "go-notifications", label: "Open Notifications", route: "/notifications", kind: "navigate" },
    },
    {
      id: "review-results",
      title: "Review output",
      description: "Inspect summary, SKU forecasts, and replenishment signals to take action.",
      status: "pending",
      action: { id: "go-replenishments", label: "Open Replenishments", route: "/replenishments", kind: "navigate" },
    },
  ],
});

const parseOpenAiContent = (text) => {
  if (!text || typeof text !== "string") return null;
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
};

const sanitizeAction = (value, fallbackId) => {
  if (!value || typeof value !== "object") return null;
  return {
    id: String(value.id || `${fallbackId}-action`),
    label: String(value.label || "Open"),
    route: value.route ? String(value.route) : null,
    kind: String(value.kind || "navigate"),
  };
};

const sanitizeSteps = (steps, fallbackSteps) => {
  if (!Array.isArray(steps) || steps.length === 0) return fallbackSteps;
  return steps.slice(0, 8).map((step, index) => {
    const id = String(step?.id || `step-${index + 1}`);
    const status = String(step?.status || "pending").toLowerCase();
    return {
      id,
      title: String(step?.title || `Step ${index + 1}`),
      description: String(step?.description || "Review this step."),
      status: ["completed", "in_progress", "pending"].includes(status) ? status : "pending",
      action: sanitizeAction(step?.action, id),
    };
  });
};

const PLAN_CAPS = {
  launch: { requestsPerMonth: 100, tokensPerMonth: 200000 },
  professional: { requestsPerMonth: 500, tokensPerMonth: 2000000 },
  enterprise: { requestsPerMonth: 2000, tokensPerMonth: 10000000 },
};

const ALLOWED_MODELS = new Set(["gpt-4o-mini"]);

const RELEVANT_TERMS = [
  "forecast",
  "sku",
  "inventory",
  "demand",
  "replenishment",
  "lead time",
  "stock",
  "run",
  "model",
  "accuracy",
  "smape",
  "mae",
  "rmse",
  "seasonality",
  "data input",
  "onboarding",
  "dashboard",
  "report",
  "anomaly",
  "outlier",
];

const getMonthKey = (now = new Date()) => `${now.getUTCFullYear()}-${String(now.getUTCMonth() + 1).padStart(2, "0")}`;
const getMinuteKey = (now = new Date()) =>
  `${now.getUTCFullYear()}${String(now.getUTCMonth() + 1).padStart(2, "0")}${String(now.getUTCDate()).padStart(2, "0")}${String(
    now.getUTCHours()
  ).padStart(2, "0")}${String(now.getUTCMinutes()).padStart(2, "0")}`;
const getHourKey = (now = new Date()) =>
  `${now.getUTCFullYear()}${String(now.getUTCMonth() + 1).padStart(2, "0")}${String(now.getUTCDate()).padStart(2, "0")}${String(
    now.getUTCHours()
  ).padStart(2, "0")}`;

const normalizePlan = (value) => {
  const plan = String(value || "launch").toLowerCase().trim();
  if (plan.includes("enterprise")) return "enterprise";
  if (plan === "core" || plan.includes("professional") || plan === "pro") return "professional";
  if (plan === "free" || plan.includes("launch")) return "launch";
  return "launch";
};

const PLAN_ALLOWED_MODELS = {
  launch: ["arima"],
  professional: ["arima", "ets", "ses", "theta", "tbats", "dhr_arima", "naive", "snaive", "croston"],
  enterprise: ["arima", "ets", "ses", "theta", "tbats", "dhr_arima", "naive", "snaive", "croston", "pooled_regression"],
};

const normalizeRequestedMode = (value, plan) => {
  const mode = String(value || "").toLowerCase().trim();
  if (mode === "global" && plan === "enterprise") return "global";
  return "local";
};

const normalizeRequestedModel = (value, plan, mode) => {
  if (mode === "global") return "pooled_regression";
  const requested = String(value || "").toLowerCase().trim();
  const allowed = PLAN_ALLOWED_MODELS[plan] || PLAN_ALLOWED_MODELS.launch;
  if (allowed.includes(requested)) return requested;
  return allowed[0] || "arima";
};

const extractNumber = (value, fallback) => {
  const num = Number(value);
  if (!Number.isFinite(num) || num <= 0) return fallback;
  return Math.floor(num);
};

const getTenantCaps = async (tenantId) => {
  const defaultPlan = "launch";
  const planFromTenant = await getTenantSettings(tenantId);
  let plan = normalizePlan(planFromTenant?.plan || defaultPlan);
  let requestsPerMonth = PLAN_CAPS[plan].requestsPerMonth;
  let tokensPerMonth = PLAN_CAPS[plan].tokensPerMonth;

  if (ENTITLEMENTS_TABLE) {
    const res = await ddb.send(
      new GetItemCommand({
        TableName: ENTITLEMENTS_TABLE,
        Key: marshall({ tenantId }),
      })
    );
    if (res.Item) {
      const item = unmarshall(res.Item);
      plan = normalizePlan(item?.plan || item?.tier || item?.subscriptionPlan || plan);
      requestsPerMonth = extractNumber(item?.llmRequestsPerMonth || item?.assistantRequestsPerMonth, PLAN_CAPS[plan].requestsPerMonth);
      tokensPerMonth = extractNumber(item?.llmTokensPerMonth || item?.assistantTokensPerMonth, PLAN_CAPS[plan].tokensPerMonth);
    }
  }

  return { plan, requestsPerMonth, tokensPerMonth };
};

const getTenantUsage = async (tenantId, monthKey) => {
  if (!LLM_USAGE_TABLE) {
    return { requestsUsed: 0, inputTokensUsed: 0, outputTokensUsed: 0 };
  }
  const res = await ddb.send(
    new GetItemCommand({
      TableName: LLM_USAGE_TABLE,
      Key: marshall({
        PK: `TENANT#${tenantId}`,
        SK: `MONTH#${monthKey}`,
      }),
    })
  );
  if (!res.Item) {
    return { requestsUsed: 0, inputTokensUsed: 0, outputTokensUsed: 0 };
  }
  const item = unmarshall(res.Item);
  return {
    requestsUsed: Number(item.requestsUsed || 0),
    inputTokensUsed: Number(item.inputTokensUsed || 0),
    outputTokensUsed: Number(item.outputTokensUsed || 0),
  };
};

const incrementTenantUsage = async (tenantId, monthKey, usage) => {
  if (!LLM_USAGE_TABLE) return;
  await ddb.send(
    new UpdateItemCommand({
      TableName: LLM_USAGE_TABLE,
      Key: marshall({
        PK: `TENANT#${tenantId}`,
        SK: `MONTH#${monthKey}`,
      }),
      UpdateExpression:
        "SET #requestsUsed = if_not_exists(#requestsUsed, :zero) + :requestInc, #inputTokensUsed = if_not_exists(#inputTokensUsed, :zero) + :inputInc, #outputTokensUsed = if_not_exists(#outputTokensUsed, :zero) + :outputInc, updatedAt = :updatedAt",
      ExpressionAttributeNames: {
        "#requestsUsed": "requestsUsed",
        "#inputTokensUsed": "inputTokensUsed",
        "#outputTokensUsed": "outputTokensUsed",
      },
      ExpressionAttributeValues: marshall({
        ":zero": 0,
        ":requestInc": Number(usage.requests || 0),
        ":inputInc": Number(usage.inputTokens || 0),
        ":outputInc": Number(usage.outputTokens || 0),
        ":updatedAt": new Date().toISOString(),
      }),
    })
  );
};

const enforceWindowRateLimit = async ({ tenantId, scope, windowKey, limit, ttlSeconds }) => {
  if (!LLM_USAGE_TABLE || !limit || limit <= 0) return { allowed: true, count: 0 };
  const nowIso = new Date().toISOString();
  const expiresAt = Math.floor(Date.now() / 1000) + ttlSeconds;
  try {
    const result = await ddb.send(
      new UpdateItemCommand({
        TableName: LLM_USAGE_TABLE,
        Key: marshall({
          PK: `TENANT#${tenantId}`,
          SK: `RATE#${scope}#${windowKey}`,
        }),
        UpdateExpression: "SET #count = if_not_exists(#count, :zero) + :inc, updatedAt = :updatedAt, expiresAt = :expiresAt",
        ConditionExpression: "attribute_not_exists(#count) OR #count < :limit",
        ExpressionAttributeNames: {
          "#count": "count",
        },
        ExpressionAttributeValues: marshall({
          ":zero": 0,
          ":inc": 1,
          ":limit": Number(limit),
          ":updatedAt": nowIso,
          ":expiresAt": expiresAt,
        }),
        ReturnValues: "ALL_NEW",
      })
    );
    const count = Number(unmarshall(result.Attributes || {}).count || 0);
    return { allowed: true, count };
  } catch (error) {
    const errName = error?.name || "";
    if (errName === "ConditionalCheckFailedException") {
      return { allowed: false, count: limit };
    }
    throw error;
  }
};

const buildAssistantCacheKey = ({ tenantId, runId, command, context }) => {
  const fingerprint = hashText(JSON.stringify({ runId: runId || "latest", command: command.toLowerCase(), context }));
  return {
    PK: `TENANT#${tenantId}`,
    SK: `CACHE#ASSISTANT#${fingerprint}`,
  };
};

const getAssistantCachedResponse = async ({ tenantId, runId, command, context }) => {
  if (!LLM_USAGE_TABLE || ASSISTANT_CACHE_TTL_SECONDS <= 0) return null;
  const key = buildAssistantCacheKey({ tenantId, runId, command, context });
  const result = await ddb.send(
    new GetItemCommand({
      TableName: LLM_USAGE_TABLE,
      Key: marshall(key),
    })
  );
  if (!result.Item) return null;
  const item = unmarshall(result.Item);
  if (!item.responseJson) return null;
  try {
    return JSON.parse(item.responseJson);
  } catch {
    return null;
  }
};

const setAssistantCachedResponse = async ({ tenantId, runId, command, context, response }) => {
  if (!LLM_USAGE_TABLE || ASSISTANT_CACHE_TTL_SECONDS <= 0) return;
  const key = buildAssistantCacheKey({ tenantId, runId, command, context });
  const expiresAt = Math.floor(Date.now() / 1000) + Number(ASSISTANT_CACHE_TTL_SECONDS);
  await ddb.send(
    new PutItemCommand({
      TableName: LLM_USAGE_TABLE,
      Item: marshall({
        ...key,
        responseJson: JSON.stringify(response),
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString(),
        expiresAt,
      }),
    })
  );
};

const isForecastRelatedCommand = (command) => {
  const normalized = String(command || "")
    .toLowerCase()
    .replace(/\s+/g, " ")
    .trim();
  if (!normalized) return true;
  return RELEVANT_TERMS.some((term) => normalized.includes(term));
};

const isLikelyFollowUpCommand = (command) => {
  const normalized = String(command || "")
    .toLowerCase()
    .replace(/\s+/g, " ")
    .trim();
  if (!normalized) return false;
  const words = normalized.split(" ").filter(Boolean);
  const hasFollowUpCue = [
    "this",
    "that",
    "it",
    "these",
    "those",
    "explain",
    "why",
    "how",
    "clarify",
    "more",
    "hike",
    "drop",
    "spike",
    "change",
  ].some((cue) => normalized.includes(cue));
  return words.length <= 8 && hasFollowUpCue;
};

const hasRecentForecastAssistantContext = (assistantSummary) => {
  if (!assistantSummary || typeof assistantSummary !== "object") return false;
  const blockedIntents = new Set(["unsupported_request", "quota_exceeded", "assistant_disabled", "rate_limited"]);
  const intent = String(assistantSummary.intent || "").trim();
  if (!intent || blockedIntents.has(intent)) return false;
  const generatedAt = new Date(String(assistantSummary.generatedAt || ""));
  if (Number.isNaN(generatedAt.getTime())) return false;
  const ageMs = Date.now() - generatedAt.getTime();
  return ageMs >= 0 && ageMs <= 1000 * 60 * 60 * 24;
};

const callAssistantModel = async ({ command, contextPayload }) => {
  if (!OPENAI_API_KEY) return { response: null, usage: { inputTokens: 0, outputTokens: 0 } };
  const model = ALLOWED_MODELS.has(OPENAI_MODEL) ? OPENAI_MODEL : "gpt-4o-mini";
  const systemPrompt = [
    "You are an inventory forecasting copilot.",
    "Return ONLY valid JSON with keys: intent, assistantText, checklist, suggestedPrompts, steps.",
    "steps must be an array of {id,title,description,status,action}.",
    "status values must be one of completed|in_progress|pending.",
    "action must be null or {id,label,route,kind}.",
    "Keep text concise and action-oriented.",
  ].join(" ");

  const userPayload = {
    userCommand: command,
    context: contextPayload,
  };
  const requestBody = {
    model,
    temperature: 0.2,
    max_tokens: 900,
    response_format: { type: "json_object" },
    messages: [
      { role: "system", content: systemPrompt },
      { role: "user", content: JSON.stringify(userPayload) },
    ],
  };

  let lastError = null;
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), Number(ASSISTANT_OPENAI_TIMEOUT_MS || 12000));
    try {
      const response = await fetch("https://api.openai.com/v1/chat/completions", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${OPENAI_API_KEY}`,
        },
        body: JSON.stringify(requestBody),
        signal: controller.signal,
      });
      clearTimeout(timer);

      if (!response.ok) {
        const detail = await response.text();
        const retryable = response.status === 429 || response.status >= 500;
        if (retryable && attempt < 2) {
          await sleep(250 * (attempt + 1));
          continue;
        }
        console.error(JSON.stringify({ msg: "openai_call_failed", status: response.status, detail }));
        return { response: null, usage: { inputTokens: 0, outputTokens: 0 } };
      }

      const payload = await response.json();
      const content = payload?.choices?.[0]?.message?.content || "";
      const usage = {
        inputTokens: Number(payload?.usage?.prompt_tokens || 0),
        outputTokens: Number(payload?.usage?.completion_tokens || 0),
      };
      return { response: parseOpenAiContent(content), usage };
    } catch (error) {
      clearTimeout(timer);
      lastError = error;
      if (attempt < 2) {
        await sleep(250 * (attempt + 1));
        continue;
      }
    }
  }

  if (lastError) {
    console.error(JSON.stringify({ msg: "openai_call_exception", error: String(lastError) }));
  }
  return { response: null, usage: { inputTokens: 0, outputTokens: 0 } };
};

const handleStartForecastRun = async (event) => {
  const tenantId = getTenantId(event);
  if (!tenantId) {
    return { status: "error", message: "missing_tenant", result: {} };
  }

  const input = event?.input?.input || event?.arguments?.input || {};
  const s3Bucket = input.s3Bucket || RAW_BUCKET;
  const s3Key = input.s3Key;
  const originalFilename = input.originalFilename || null;
  const adjustmentsKey = input.adjustmentsKey || null;
  const sku = input.sku || null;
  const store = input.store || null;
  const frequency = input.frequency || null;
  const inputModel = input.model || null;
  const inputMode = input.mode || null;
  const inputSeasonality = input.seasonality || null;
  const inputDateFormat = input.dateFormat || null;
  const inputTargetVariable = input.targetVariable || null;
  const inputPriceColumnName = input.priceColumnName || null;

  if (!s3Bucket || !s3Key) {
    return { status: "error", message: "missing_s3", result: {} };
  }

  const tenantDefaults = await getTenantSettings(tenantId);
  const { plan } = await getTenantCaps(tenantId);
  const requestedMode = inputMode || tenantDefaults?.mode || "local";
  const mode = normalizeRequestedMode(requestedMode, plan);
  const requestedModel = inputModel || tenantDefaults?.model || "arima";
  const model = normalizeRequestedModel(requestedModel, plan, mode);
  const seasonality = inputSeasonality || tenantDefaults?.seasonality || "auto";
  const dateFormat = inputDateFormat || tenantDefaults?.dateFormat || "dd/mm/yyyy";
  const targetVariable = inputTargetVariable || tenantDefaults?.targetVariable || "quantity";
  const priceColumnName = inputPriceColumnName || tenantDefaults?.priceColumnName || "price";

  await setTenantSettings(tenantId, { model, mode, seasonality, dateFormat, targetVariable, priceColumnName });

  const previousRun = await getLatestRun(tenantId);
  const snapshotId = randomId("SNAPSHOT-");
  const runId = randomId("RUN-");
  const createdAt = nowIso();

  await ddb.send(
    new PutItemCommand({
      TableName: DATA_SNAPSHOTS_TABLE,
      Item: marshall({
        PK: `TENANT#${tenantId}`,
        SK: `SNAPSHOT#${snapshotId}`,
        tenantId,
        snapshotId,
        s3Bucket,
        s3Key,
        originalFilename,
        createdAt,
        status: "READY",
      }),
    })
  );

  const s3OutputPrefix = `tenant-artifacts/${tenantId}/runs/${runId}`;

  await ddb.send(
    new PutItemCommand({
      TableName: FORECAST_RUNS_TABLE,
      Item: marshall({
        PK: `TENANT#${tenantId}`,
        SK: `RUN#${runId}`,
        tenantId,
        runId,
        snapshotId,
        s3OutputPrefix,
        status: "QUEUED",
        createdAt,
        updatedAt: createdAt,
      }),
    })
  );

  const baseS3OutputPrefix = previousRun?.s3OutputPrefix || null;

  const payload = {
    invocationType: "forecast_run",
    tenantId,
    runId,
    snapshotId,
    s3Bucket,
    s3Key,
    s3OutputPrefix,
    adjustmentsKey,
    sku,
    store,
    frequency,
    model,
    mode,
    seasonality,
    dateFormat,
    targetVariable,
    priceColumnName,
    baseS3OutputPrefix,
  };

  await lambda.send(
    new InvokeCommand({
      FunctionName: FORECAST_LAMBDA_ARN,
      InvocationType: "Event",
      Payload: Buffer.from(JSON.stringify(payload)),
    })
  );

  await updateRunStatus(tenantId, runId, "RUNNING");

  await upsertNotification({
    tenantId,
    runId,
    status: "RUNNING",
    createdAt,
    updatedAt: createdAt,
  });

  return {
    status: "queued",
    run: normalizeRun({
      runId,
      tenantId,
      snapshotId,
      status: "QUEUED",
      createdAt,
      updatedAt: createdAt,
      s3OutputPrefix,
    }),
  };
};

const handleGetForecastRun = async (event) => {
  const tenantId = getTenantId(event);
  if (!tenantId) return null;

  const runId = event?.input?.runId || event?.arguments?.runId;
  if (!runId) return null;

  const item = await getRunById(tenantId, runId);
  const run = normalizeRun(item);
  if (!run) return null;

  if (run.status !== "DONE" && run.s3OutputPrefix) {
    const ready = await outputFilesReady(run.s3OutputPrefix);
    if (ready) {
      let summary;
      try {
        summary = await readJsonFromS3(ARTIFACT_BUCKET, `${run.s3OutputPrefix}/report_summary.json`);
      } catch {
        summary = null;
      }

      await updateRunStatus(tenantId, run.runId, "DONE", summary);
      return {
        ...run,
        status: "DONE",
        summary: summary ?? run.summary ?? null,
        updatedAt: new Date().toISOString(),
      };
    }
  }

  return run;
};

const handleListForecastRuns = async (event) => {
  const tenantId = getTenantId(event);
  if (!tenantId) return { items: [], nextToken: null };

  const limit = event?.input?.limit || event?.arguments?.limit || 20;
  const nextToken = event?.input?.nextToken || event?.arguments?.nextToken || null;

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
      ExclusiveStartKey: decodeNextToken(nextToken),
    })
  );

  const items = (result.Items || []).map((item) => normalizeRun(unmarshall(item)));

  const updatedItems = await Promise.all(
    items.map(async (item) => {
      if (!item || item.status === "DONE" || !item.s3OutputPrefix) {
        return item;
      }
      const ready = await outputFilesReady(item.s3OutputPrefix);
      if (!ready) return item;

      let summary;
      try {
        summary = await readJsonFromS3(ARTIFACT_BUCKET, `${item.s3OutputPrefix}/report_summary.json`);
      } catch {
        summary = null;
      }

      await updateRunStatus(tenantId, item.runId, "DONE", summary);
      return {
        ...item,
        status: "DONE",
        summary: summary ?? item.summary ?? null,
        updatedAt: new Date().toISOString(),
      };
    })
  );

  return { items: updatedItems, nextToken: encodeNextToken(result.LastEvaluatedKey) };
};

const handleListNotifications = async (event) => {
  const tenantId = getTenantId(event);
  if (!tenantId || !NOTIFICATIONS_TABLE) return { items: [], nextToken: null };

  const limit = event?.input?.limit || event?.arguments?.limit || 10;
  const nextToken = event?.input?.nextToken || event?.arguments?.nextToken || null;

  const result = await ddb.send(
    new QueryCommand({
      TableName: NOTIFICATIONS_TABLE,
      IndexName: "byTenantCreatedAt",
      KeyConditionExpression: "GSI1PK = :pk",
      ExpressionAttributeValues: marshall({
        ":pk": `TENANT#${tenantId}`,
      }),
      ScanIndexForward: false,
      Limit: limit,
      ExclusiveStartKey: decodeNextToken(nextToken),
    })
  );

  const items = (result.Items || []).map((item) => normalizeNotification(unmarshall(item)));

  const syncedItems = await Promise.all(
    items.map(async (notification) => {
      if (!notification?.runId) return notification;
      const run = await getRunById(tenantId, notification.runId);
      if (!run) return notification;
      if (run.status && run.status !== notification.status) {
        await updateNotificationStatus({
          tenantId,
          runId: notification.runId,
          status: run.status,
          summary: run.summary || null,
        });
        return {
          ...notification,
          status: run.status,
          summary: run.summary || notification.summary || null,
          updatedAt: run.updatedAt || notification.updatedAt,
        };
      }
      return notification;
    })
  );

  return { items: syncedItems, nextToken: encodeNextToken(result.LastEvaluatedKey) };
};

const handleMarkNotificationRead = async (event) => {
  const tenantId = getTenantId(event);
  if (!tenantId || !NOTIFICATIONS_TABLE) {
    return { notificationId: "", runId: "", tenantId: "", status: "", read: false };
  }

  const notificationId = event?.input?.notificationId || event?.arguments?.notificationId;
  if (!notificationId) {
    return { notificationId: "", runId: "", tenantId: "", status: "", read: false };
  }

  const result = await ddb.send(
    new UpdateItemCommand({
      TableName: NOTIFICATIONS_TABLE,
      Key: marshall({
        PK: `TENANT#${tenantId}`,
        SK: `RUN#${notificationId}`,
      }),
      UpdateExpression: "SET #read = :read, updatedAt = :updatedAt",
      ExpressionAttributeNames: {
        "#read": "read",
      },
      ExpressionAttributeValues: {
        ":read": { BOOL: true },
        ":updatedAt": { S: new Date().toISOString() },
      },
      ReturnValues: "ALL_NEW",
    })
  );

  return normalizeNotification(result.Attributes ? unmarshall(result.Attributes) : null);
};

const listTenantNotificationItems = async (tenantId) => {
  const items = [];
  let cursor = null;

  do {
    const result = await ddb.send(
      new QueryCommand({
        TableName: NOTIFICATIONS_TABLE,
        KeyConditionExpression: "PK = :pk AND begins_with(SK, :sk)",
        ExpressionAttributeValues: marshall({
          ":pk": `TENANT#${tenantId}`,
          ":sk": "RUN#",
        }),
        ExclusiveStartKey: cursor || undefined,
      })
    );

    for (const item of result.Items || []) {
      items.push(unmarshall(item));
    }
    cursor = result.LastEvaluatedKey || null;
  } while (cursor);

  return items;
};

const handleMarkAllNotificationsRead = async (event) => {
  const tenantId = getTenantId(event);
  if (!tenantId || !NOTIFICATIONS_TABLE) return { affectedCount: 0 };

  const items = await listTenantNotificationItems(tenantId);
  const unread = items.filter((item) => !item.read);
  const updatedAt = new Date().toISOString();

  await Promise.all(
    unread.map((item) =>
      ddb.send(
        new UpdateItemCommand({
          TableName: NOTIFICATIONS_TABLE,
          Key: marshall({
            PK: `TENANT#${tenantId}`,
            SK: String(item.SK || ""),
          }),
          UpdateExpression: "SET #read = :read, updatedAt = :updatedAt",
          ExpressionAttributeNames: {
            "#read": "read",
          },
          ExpressionAttributeValues: {
            ":read": { BOOL: true },
            ":updatedAt": { S: updatedAt },
          },
        })
      )
    )
  );

  return { affectedCount: unread.length };
};

const handleClearCompletedNotifications = async (event) => {
  const tenantId = getTenantId(event);
  if (!tenantId || !NOTIFICATIONS_TABLE) return { affectedCount: 0 };

  const items = await listTenantNotificationItems(tenantId);
  const completed = items.filter((item) => String(item.status || "").toUpperCase() === "DONE");

  await Promise.all(
    completed.map((item) =>
      ddb.send(
        new DeleteItemCommand({
          TableName: NOTIFICATIONS_TABLE,
          Key: marshall({
            PK: `TENANT#${tenantId}`,
            SK: String(item.SK || ""),
          }),
        })
      )
    )
  );

  return { affectedCount: completed.length };
};

const handleUpdateForecastRunStatus = async (event) => {
  const input = event?.input?.input || event?.arguments?.input || {};
  const tenantId = String(input?.tenantId || "").trim();
  const runId = String(input?.runId || "").trim();
  const status = String(input?.status || "").trim().toUpperCase();
  const s3OutputPrefix = typeof input?.s3OutputPrefix === "string" ? input.s3OutputPrefix : null;
  const summaryJson = typeof input?.summaryJson === "string" ? input.summaryJson : "";

  if (!tenantId || !runId || !status) return null;

  let summary = null;
  if (summaryJson) {
    try {
      summary = JSON.parse(summaryJson);
    } catch {
      summary = null;
    }
  }

  await updateRunStatus(tenantId, runId, status, summary);
  const item = await getRunById(tenantId, runId);
  const normalized = normalizeRun(item);
  if (!normalized) return null;
  if (s3OutputPrefix && !normalized.s3OutputPrefix) normalized.s3OutputPrefix = s3OutputPrefix;
  return normalized;
};

const handleForecastAssistant = async (event) => {
  const tenantId = getTenantId(event);
  if (!tenantId) {
    return {
      ...defaultAssistantResponse(null),
      status: "error",
      assistantText: "Tenant context is missing. Please sign in again.",
    };
  }

  const input = event?.input?.input || event?.arguments?.input || {};
  const command = redactCommand(String(input?.command || "").slice(0, 600));
  const runId = input?.runId || null;
  const monthKey = getMonthKey();
  const tenantSettings = await getTenantSettings(tenantId);

  let run = null;
  if (runId) {
    run = await getRunById(tenantId, runId);
  }
  if (!run) {
    run = await getLatestRun(tenantId);
  }

  if (!ASSISTANT_ENABLED) {
    return {
      ...defaultAssistantResponse(null),
      status: "disabled",
      intent: "assistant_disabled",
      assistantText: "Forecast assistant is currently disabled for this environment.",
      checklist: [],
      suggestedPrompts: [],
      steps: [],
    };
  }

  const directRelevant = isForecastRelatedCommand(command);
  const followUpAllowed =
    isLikelyFollowUpCommand(command) &&
    (Boolean(run) || hasRecentForecastAssistantContext(tenantSettings?.assistantSummary || null));

  if (!directRelevant && !followUpAllowed) {
    return {
      ...defaultAssistantResponse(null),
      status: "blocked",
      intent: "unsupported_request",
      assistantText:
        "I can only answer forecasting questions (onboarding, run status, forecast quality, demand/replenishment, and model settings).",
      checklist: [
        "Ask about running forecasts, forecast outputs, or replenishment.",
        "Use specific terms like SKU, run status, model, or accuracy.",
      ],
      suggestedPrompts: [
        "Guide me through getting my first forecast.",
        "Is my latest forecast run ready?",
        "Summarize replenishment risks for this run.",
      ],
      steps: [],
    };
  }

  const caps = await getTenantCaps(tenantId);
  const usageBefore = await getTenantUsage(tenantId, monthKey);
  const tokensUsedBefore = usageBefore.inputTokensUsed + usageBefore.outputTokensUsed;
  if (usageBefore.requestsUsed >= caps.requestsPerMonth || tokensUsedBefore >= caps.tokensPerMonth) {
    return {
      ...defaultAssistantResponse(null),
      status: "quota_exceeded",
      intent: "quota_exceeded",
      assistantText: `Assistant quota reached for ${monthKey}. Used ${usageBefore.requestsUsed}/${caps.requestsPerMonth} requests and ${tokensUsedBefore}/${caps.tokensPerMonth} tokens.`,
      checklist: [
        "Wait for quota reset next month.",
        "Upgrade plan or raise tenant assistant limits in entitlements.",
      ],
      suggestedPrompts: [],
      steps: [],
    };
  }

  const minuteRate = await enforceWindowRateLimit({
    tenantId,
    scope: "MINUTE",
    windowKey: getMinuteKey(),
    limit: Number(ASSISTANT_RATE_LIMIT_PER_MINUTE || 10),
    ttlSeconds: 120,
  });
  if (!minuteRate.allowed) {
    return {
      ...defaultAssistantResponse(null),
      status: "rate_limited",
      intent: "rate_limited",
      assistantText: "Rate limit exceeded. Please wait and retry in about a minute.",
      checklist: ["Retry after one minute.", "Avoid repeated duplicate prompts."],
      suggestedPrompts: [],
      steps: [],
    };
  }

  const hourRate = await enforceWindowRateLimit({
    tenantId,
    scope: "HOUR",
    windowKey: getHourKey(),
    limit: Number(ASSISTANT_RATE_LIMIT_PER_HOUR || 120),
    ttlSeconds: 7200,
  });
  if (!hourRate.allowed) {
    return {
      ...defaultAssistantResponse(null),
      status: "rate_limited",
      intent: "rate_limited",
      assistantText: "Hourly assistant rate limit reached. Please retry later.",
      checklist: ["Retry in the next hour window."],
      suggestedPrompts: [],
      steps: [],
    };
  }

  let summary = null;
  let metadata = null;
  let monthlyTotals = null;
  let replenishmentSignals = null;
  const prefix = run?.s3OutputPrefix;

  if (prefix) {
    try {
      summary = await readJsonFromS3(ARTIFACT_BUCKET, `${prefix}/report_summary.json`);
    } catch {
      if (run?.summary && typeof run.summary === "string") {
        try {
          summary = JSON.parse(run.summary);
        } catch {
          summary = null;
        }
      } else {
        summary = run?.summary || null;
      }
    }
    try {
      metadata = await readJsonFromS3(ARTIFACT_BUCKET, `${prefix}/metadata.json`);
    } catch {
      metadata = null;
    }
    try {
      monthlyTotals = await readJsonFromS3(ARTIFACT_BUCKET, `${prefix}/monthly_totals.json`);
    } catch {
      monthlyTotals = null;
    }
    try {
      replenishmentSignals = await readJsonFromS3(ARTIFACT_BUCKET, `${prefix}/replenishment_signals.json`);
    } catch {
      replenishmentSignals = null;
    }
  }

  const context = buildContextPayload({
    run,
    summary,
    metadata,
    monthlyTotals,
    replenishmentSignals,
  });

  const cached = await getAssistantCachedResponse({ tenantId, runId: run?.runId || runId, command, context });
  if (cached) {
    return cached;
  }

  const estimatedInputTokens = estimateTokens(command) + estimateTokens(JSON.stringify(context)) + 180;
  if (tokensUsedBefore + estimatedInputTokens >= caps.tokensPerMonth) {
    return {
      ...defaultAssistantResponse(context),
      status: "quota_exceeded",
      intent: "quota_exceeded",
      assistantText: `Insufficient token budget remaining for ${monthKey}. Estimated input tokens (${estimatedInputTokens}) exceed remaining allocation.`,
      checklist: ["Use a shorter prompt or retry next month.", "Increase tenant token limits in entitlements."],
      suggestedPrompts: [],
      steps: [],
    };
  }

  const fallback = defaultAssistantResponse(context);
  const llmResult = await callAssistantModel({ command, contextPayload: context });
  const llm = llmResult?.response || null;

  const response = {
    ...fallback,
    intent: typeof llm?.intent === "string" ? llm.intent : fallback.intent,
    assistantText: typeof llm?.assistantText === "string" ? llm.assistantText : fallback.assistantText,
    checklist: Array.isArray(llm?.checklist) ? llm.checklist.map((item) => String(item)) : fallback.checklist,
    suggestedPrompts: Array.isArray(llm?.suggestedPrompts)
      ? llm.suggestedPrompts.map((item) => String(item))
      : fallback.suggestedPrompts,
    steps: sanitizeSteps(llm?.steps, fallback.steps),
  };

  await setTenantAssistantSummary(tenantId, {
    tenantId,
    runId: run?.runId || null,
    command,
    generatedAt: new Date().toISOString(),
    intent: response.intent,
    assistantText: response.assistantText,
    checklist: response.checklist,
    suggestedPrompts: response.suggestedPrompts,
  });

  await incrementTenantUsage(tenantId, monthKey, {
    requests: 1,
    inputTokens: llmResult?.usage?.inputTokens || 0,
    outputTokens: llmResult?.usage?.outputTokens || 0,
  });

  await setAssistantCachedResponse({
    tenantId,
    runId: run?.runId || runId,
    command,
    context,
    response,
  });

  return response;
};

const handleGetAssistantUsage = async (event) => {
  const tenantId = getTenantId(event);
  const monthKey = getMonthKey();
  if (!tenantId) {
    return {
      monthKey,
      requestsUsed: 0,
      requestsLimit: 0,
      tokensUsed: 0,
      tokensLimit: 0,
      rateMinuteLimit: Number(ASSISTANT_RATE_LIMIT_PER_MINUTE || 10),
      rateHourLimit: Number(ASSISTANT_RATE_LIMIT_PER_HOUR || 120),
    };
  }

  const caps = await getTenantCaps(tenantId);
  const usage = await getTenantUsage(tenantId, monthKey);
  const tokensUsed = Number(usage.inputTokensUsed || 0) + Number(usage.outputTokensUsed || 0);

  return {
    monthKey,
    requestsUsed: Number(usage.requestsUsed || 0),
    requestsLimit: Number(caps.requestsPerMonth || 0),
    tokensUsed,
    tokensLimit: Number(caps.tokensPerMonth || 0),
    rateMinuteLimit: Number(ASSISTANT_RATE_LIMIT_PER_MINUTE || 10),
    rateHourLimit: Number(ASSISTANT_RATE_LIMIT_PER_HOUR || 120),
  };
};

const dispatchField = async (fieldName, event) => {
  switch (fieldName) {
    case "startForecastRun":
      return handleStartForecastRun(event);
    case "getForecastRun":
      return handleGetForecastRun(event);
    case "listForecastRuns":
      return handleListForecastRuns(event);
    case "listNotifications":
      return handleListNotifications(event);
    case "markNotificationRead":
      return handleMarkNotificationRead(event);
    case "markAllNotificationsRead":
      return handleMarkAllNotificationsRead(event);
    case "clearCompletedNotifications":
      return handleClearCompletedNotifications(event);
    case "updateForecastRunStatus":
      return handleUpdateForecastRunStatus(event);
    case "getSKUsMetadata":
      return handleGetResultFile(event, "metadata.json");
    case "getSKUForecasts":
      return handleGetResultFile(event, "monthly_forecasts.json");
    case "getMonthlyTotals":
      return handleGetResultFile(event, "monthly_totals.json");
    case "getDailyForecasts":
      return handleGetResultFile(event, "daily_forecasts.json");
    case "getReportSummary":
      return handleGetResultFile(event, "report_summary.json");
    case "getSkuForecastValues":
      return handleGetResultFile(event, "sku_forecast_values.json");
    case "getReplenishmentSignals":
      return handleGetResultFile(event, "replenishment_signals.json");
    case "getTenantSettings": {
      const tenantId = getTenantId(event);
      if (!tenantId) return null;
      return getTenantSettings(tenantId);
    }
    case "setTenantSettings": {
      const tenantId = getTenantId(event);
      if (!tenantId) return null;
      const input = event?.input?.input || event?.arguments?.input || {};
      return setTenantSettings(tenantId, input);
    }
    case "forecastAssistant":
      return handleForecastAssistant(event);
    case "getAssistantUsage":
      return handleGetAssistantUsage(event);
    default:
      return { status: "error", message: "unknown_field", result: {} };
  }
};

module.exports = {
  dispatchField,
};
