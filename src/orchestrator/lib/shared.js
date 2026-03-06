const crypto = require("crypto");
const { DynamoDBClient, PutItemCommand, QueryCommand, GetItemCommand, UpdateItemCommand } = require("@aws-sdk/client-dynamodb");
const { LambdaClient, InvokeCommand } = require("@aws-sdk/client-lambda");
const { S3Client, GetObjectCommand } = require("@aws-sdk/client-s3");
const { marshall, unmarshall } = require("@aws-sdk/util-dynamodb");

const ddb = new DynamoDBClient({});
const lambda = new LambdaClient({});
const s3 = new S3Client({});

const RAW_BUCKET = process.env.RAW_BUCKET || "";
const ARTIFACT_BUCKET = process.env.ARTIFACT_BUCKET || "";
const FORECAST_RUNS_TABLE = process.env.FORECAST_RUNS_TABLE || "";
const DATA_SNAPSHOTS_TABLE = process.env.DATA_SNAPSHOTS_TABLE || "";
const FORECAST_LAMBDA_ARN = process.env.FORECAST_LAMBDA_ARN || "";
const NOTIFICATIONS_TABLE = process.env.NOTIFICATIONS_TABLE || "";
const TENANTS_TABLE = process.env.TENANTS_TABLE || "";
const ENTITLEMENTS_TABLE = process.env.ENTITLEMENTS_TABLE || "";
const LLM_USAGE_TABLE = process.env.LLM_USAGE_TABLE || "";
const OPENAI_API_KEY = process.env.OPENAI_API_KEY || "";
const OPENAI_MODEL = process.env.OPENAI_MODEL || "gpt-4o-mini";
const ASSISTANT_ENABLED = String(process.env.ASSISTANT_ENABLED || "true").toLowerCase() !== "false";
const ASSISTANT_CACHE_TTL_SECONDS = Number(process.env.ASSISTANT_CACHE_TTL_SECONDS || "1800");
const ASSISTANT_RATE_LIMIT_PER_MINUTE = Number(process.env.ASSISTANT_RATE_LIMIT_PER_MINUTE || "10");
const ASSISTANT_RATE_LIMIT_PER_HOUR = Number(process.env.ASSISTANT_RATE_LIMIT_PER_HOUR || "120");
const ASSISTANT_OPENAI_TIMEOUT_MS = Number(process.env.ASSISTANT_OPENAI_TIMEOUT_MS || "12000");

const requireEnv = (value, name) => {
  if (!value) {
    throw new Error(`Missing ${name}`);
  }
};

const decodeJwtPayload = (token) => {
  const parts = token.split(".");
  if (parts.length < 2) return null;
  const base64 = parts[1].replace(/-/g, "+").replace(/_/g, "/");
  const padded = base64.padEnd(base64.length + (4 - (base64.length % 4)) % 4, "=");
  try {
    return JSON.parse(Buffer.from(padded, "base64").toString("utf8"));
  } catch {
    return null;
  }
};

const getTenantId = (event) => {
  const claims = event?.identity?.claims || {};
  const fromClaims = claims["custom:tenant_id"] || claims["tenant_id"] || claims["cognito:username"];
  if (fromClaims) return fromClaims;

  const headers = event?.request?.headers || {};
  const authHeader = headers.Authorization || headers.authorization || "";
  if (authHeader) {
    const payload = decodeJwtPayload(authHeader);
    const fromToken = payload?.["custom:tenant_id"] || payload?.["tenant_id"] || payload?.["cognito:username"];
    if (fromToken) return fromToken;
  }

  return null;
};

const getTenantSettings = async (tenantId) => {
  if (!TENANTS_TABLE || !tenantId) return null;
  const result = await ddb.send(
    new GetItemCommand({
      TableName: TENANTS_TABLE,
      Key: marshall({ tenantId }),
    })
  );
  if (!result.Item) return null;
  const item = unmarshall(result.Item);
  let assistantSummary = null;
  if (item.assistantSummary) {
    try {
      assistantSummary = typeof item.assistantSummary === "string" ? JSON.parse(item.assistantSummary) : item.assistantSummary;
    } catch {
      assistantSummary = null;
    }
  }
  return {
    tenantId: item.tenantId,
    plan: item.plan || item.tier || item.subscriptionPlan || null,
    model: item.defaultModel || null,
    mode: item.defaultMode || null,
    seasonality: item.defaultSeasonality || null,
    assistantSummary,
    updatedAt: item.updatedAt || null,
  };
};

const setTenantSettings = async (tenantId, settings) => {
  if (!TENANTS_TABLE || !tenantId) return null;
  const updateExpressionParts = [];
  const expressionAttributeNames = {};
  const expressionAttributeValues = {
    ":updatedAt": { S: new Date().toISOString() },
  };

  if (settings.model) {
    updateExpressionParts.push("#defaultModel = :defaultModel");
    expressionAttributeNames["#defaultModel"] = "defaultModel";
    expressionAttributeValues[":defaultModel"] = { S: settings.model };
  }
  if (settings.mode) {
    updateExpressionParts.push("#defaultMode = :defaultMode");
    expressionAttributeNames["#defaultMode"] = "defaultMode";
    expressionAttributeValues[":defaultMode"] = { S: settings.mode };
  }
  if (settings.seasonality) {
    updateExpressionParts.push("#defaultSeasonality = :defaultSeasonality");
    expressionAttributeNames["#defaultSeasonality"] = "defaultSeasonality";
    expressionAttributeValues[":defaultSeasonality"] = { S: settings.seasonality };
  }

  updateExpressionParts.push("#updatedAt = :updatedAt");
  expressionAttributeNames["#updatedAt"] = "updatedAt";

  await ddb.send(
    new UpdateItemCommand({
      TableName: TENANTS_TABLE,
      Key: marshall({ tenantId }),
      UpdateExpression: `SET ${updateExpressionParts.join(", ")}`,
      ExpressionAttributeNames: expressionAttributeNames,
      ExpressionAttributeValues: expressionAttributeValues,
    })
  );

  return getTenantSettings(tenantId);
};

const setTenantAssistantSummary = async (tenantId, payload) => {
  if (!TENANTS_TABLE || !tenantId) return null;
  const now = new Date().toISOString();
  await ddb.send(
    new UpdateItemCommand({
      TableName: TENANTS_TABLE,
      Key: marshall({ tenantId }),
      UpdateExpression: "SET assistantSummary = :assistantSummary, updatedAt = :updatedAt",
      ExpressionAttributeValues: marshall({
        ":assistantSummary": JSON.stringify(payload || {}),
        ":updatedAt": now,
      }),
    })
  );
  return now;
};

const nowIso = () => new Date().toISOString();

const randomId = (prefix) => {
  const ts = new Date().toISOString().replace(/[-:.TZ]/g, "");
  const rand = crypto.randomBytes(4).toString("hex");
  return `${prefix}${ts}-${rand}`;
};

const streamToString = async (stream) => {
  const chunks = [];
  for await (const chunk of stream) {
    chunks.push(Buffer.from(chunk));
  }
  return Buffer.concat(chunks).toString("utf8");
};

const getLatestRun = async (tenantId) => {
  const result = await ddb.send(
    new QueryCommand({
      TableName: FORECAST_RUNS_TABLE,
      KeyConditionExpression: "PK = :pk AND begins_with(SK, :sk)",
      ExpressionAttributeValues: marshall({
        ":pk": `TENANT#${tenantId}`,
        ":sk": "RUN#",
      }),
      ScanIndexForward: false,
      Limit: 1,
    })
  );

  const items = result.Items || [];
  if (!items.length) return null;
  return unmarshall(items[0]);
};

const getRunById = async (tenantId, runId) => {
  const result = await ddb.send(
    new GetItemCommand({
      TableName: FORECAST_RUNS_TABLE,
      Key: marshall({
        PK: `TENANT#${tenantId}`,
        SK: `RUN#${runId}`,
      }),
    })
  );
  return result.Item ? unmarshall(result.Item) : null;
};

const readJsonFromS3 = async (bucket, key) => {
  const response = await s3.send(
    new GetObjectCommand({
      Bucket: bucket,
      Key: key,
    })
  );
  const body = await streamToString(response.Body);
  return JSON.parse(body);
};

const outputFilesReady = async (prefix) => {
  const files = [
    "daily_forecasts.json",
    "monthly_forecasts.json",
    "monthly_totals.json",
    "metadata.json",
    "report_summary.json",
    "replenishment_signals.json",
  ];
  try {
    await Promise.all(
      files.map((file) =>
        s3.send(
          new GetObjectCommand({
            Bucket: ARTIFACT_BUCKET,
            Key: `${prefix}/${file}`,
          })
        )
      )
    );
    return true;
  } catch {
    return false;
  }
};

const normalizeRun = (item) => {
  if (!item) return null;
  return {
    runId: item.runId,
    tenantId: item.tenantId,
    snapshotId: item.snapshotId || null,
    status: item.status,
    createdAt: item.createdAt || null,
    updatedAt: item.updatedAt || null,
    s3OutputPrefix: item.s3OutputPrefix || null,
    summary: item.summary || null,
  };
};

const normalizeNotification = (item) => {
  if (!item) return null;
  return {
    notificationId: item.notificationId,
    runId: item.runId,
    tenantId: item.tenantId,
    status: item.status,
    createdAt: item.createdAt || null,
    updatedAt: item.updatedAt || null,
    read: Boolean(item.read),
    summary: item.summary || null,
  };
};

const encodeNextToken = (key) => {
  if (!key) return null;
  return Buffer.from(JSON.stringify(key)).toString("base64");
};

const decodeNextToken = (token) => {
  if (!token) return undefined;
  try {
    return JSON.parse(Buffer.from(token, "base64").toString("utf-8"));
  } catch {
    return undefined;
  }
};

const upsertNotification = async ({ tenantId, runId, status, createdAt, updatedAt, summary }) => {
  if (!NOTIFICATIONS_TABLE || !tenantId || !runId) return;
  const now = updatedAt || new Date().toISOString();
  const created = createdAt || now;

  try {
    await ddb.send(
      new PutItemCommand({
        TableName: NOTIFICATIONS_TABLE,
        Item: marshall(
          {
            PK: `TENANT#${tenantId}`,
            SK: `RUN#${runId}`,
            GSI1PK: `TENANT#${tenantId}`,
            GSI1SK: created,
            notificationId: runId,
            runId,
            tenantId,
            status,
            createdAt: created,
            updatedAt: now,
            read: false,
            summary: summary ? JSON.stringify(summary) : undefined,
          },
          { removeUndefinedValues: true }
        ),
        ConditionExpression: "attribute_not_exists(PK) AND attribute_not_exists(SK)",
      })
    );
  } catch {
    // Ignore if notification already exists
  }
};

const updateNotificationStatus = async ({ tenantId, runId, status, summary }) => {
  if (!NOTIFICATIONS_TABLE || !tenantId || !runId) return;

  const updateExpression = summary
    ? "SET #status = :status, updatedAt = :updatedAt, #summary = :summary"
    : "SET #status = :status, updatedAt = :updatedAt";

  const expressionAttributeNames = {
    "#status": "status",
  };

  const expressionAttributeValues = {
    ":status": { S: status },
    ":updatedAt": { S: new Date().toISOString() },
  };

  if (summary) {
    expressionAttributeNames["#summary"] = "summary";
    expressionAttributeValues[":summary"] = { S: JSON.stringify(summary) };
  }

  await ddb.send(
    new UpdateItemCommand({
      TableName: NOTIFICATIONS_TABLE,
      Key: marshall({
        PK: `TENANT#${tenantId}`,
        SK: `RUN#${runId}`,
      }),
      UpdateExpression: updateExpression,
      ExpressionAttributeNames: expressionAttributeNames,
      ExpressionAttributeValues: expressionAttributeValues,
    })
  );
};

const updateRunStatus = async (tenantId, runId, status, summary) => {
  if (!tenantId || !runId) return;
  const updateExpression = summary
    ? "SET #status = :status, updatedAt = :updatedAt, #summary = :summary"
    : "SET #status = :status, updatedAt = :updatedAt";

  const expressionAttributeNames = {
    "#status": "status",
  };

  const expressionAttributeValues = {
    ":status": { S: status },
    ":updatedAt": { S: new Date().toISOString() },
  };

  if (summary) {
    expressionAttributeNames["#summary"] = "summary";
    expressionAttributeValues[":summary"] = { S: JSON.stringify(summary) };
  }

  await ddb.send(
    new UpdateItemCommand({
      TableName: FORECAST_RUNS_TABLE,
      Key: marshall({
        PK: `TENANT#${tenantId}`,
        SK: `RUN#${runId}`,
      }),
      UpdateExpression: updateExpression,
      ExpressionAttributeNames: expressionAttributeNames,
      ExpressionAttributeValues: expressionAttributeValues,
    })
  );

  await updateNotificationStatus({ tenantId, runId, status, summary });
};

const handleGetResultFile = async (event, keySuffix) => {
  const tenantId = getTenantId(event);
  if (!tenantId) {
    return { status: "error", result: {} };
  }

  const latestRun = await getLatestRun(tenantId);
  if (!latestRun?.s3OutputPrefix) {
    return { status: "empty", result: {} };
  }

  const key = `${latestRun.s3OutputPrefix}/${keySuffix}`;
  try {
    const data = await readJsonFromS3(ARTIFACT_BUCKET, key);
    if (latestRun.status !== "DONE") {
      const ready = await outputFilesReady(latestRun.s3OutputPrefix);
      if (ready) {
        if (keySuffix === "report_summary.json") {
          await updateRunStatus(tenantId, latestRun.runId, "DONE", data);
        } else {
          await updateRunStatus(tenantId, latestRun.runId, "DONE");
        }
      }
    }
    return { status: "success", result: data };
  } catch (err) {
    if (keySuffix === "replenishment_signals.json") {
      return { status: "empty", result: { generatedAt: null, horizonDays: 0, items: [] } };
    }
    return { status: "error", result: {} };
  }
};

module.exports = {
  ddb,
  lambda,
  marshall,
  unmarshall,
  PutItemCommand,
  GetItemCommand,
  QueryCommand,
  UpdateItemCommand,
  InvokeCommand,
  RAW_BUCKET,
  ARTIFACT_BUCKET,
  FORECAST_RUNS_TABLE,
  DATA_SNAPSHOTS_TABLE,
  FORECAST_LAMBDA_ARN,
  NOTIFICATIONS_TABLE,
  TENANTS_TABLE,
  ENTITLEMENTS_TABLE,
  LLM_USAGE_TABLE,
  OPENAI_API_KEY,
  OPENAI_MODEL,
  ASSISTANT_ENABLED,
  ASSISTANT_CACHE_TTL_SECONDS,
  ASSISTANT_RATE_LIMIT_PER_MINUTE,
  ASSISTANT_RATE_LIMIT_PER_HOUR,
  ASSISTANT_OPENAI_TIMEOUT_MS,
  requireEnv,
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
};
