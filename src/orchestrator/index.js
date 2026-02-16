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
  const fromClaims =
    claims["custom:tenant_id"] ||
    claims["tenant_id"] ||
    claims["cognito:username"];
  if (fromClaims) return fromClaims;

  const headers = event?.request?.headers || {};
  const authHeader = headers.Authorization || headers.authorization || "";
  if (authHeader) {
    const payload = decodeJwtPayload(authHeader);
    const fromToken =
      payload?.["custom:tenant_id"] ||
      payload?.["tenant_id"] ||
      payload?.["cognito:username"];
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
  return {
    tenantId: item.tenantId,
    model: item.defaultModel || null,
    mode: item.defaultMode || null,
    seasonality: item.defaultSeasonality || null,
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

const handleStartForecastRun = async (event) => {
  requireEnv(FORECAST_RUNS_TABLE, "FORECAST_RUNS_TABLE");
  requireEnv(DATA_SNAPSHOTS_TABLE, "DATA_SNAPSHOTS_TABLE");
  requireEnv(FORECAST_LAMBDA_ARN, "FORECAST_LAMBDA_ARN");

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

  if (!s3Bucket || !s3Key) {
    return { status: "error", message: "missing_s3", result: {} };
  }

  const tenantDefaults = await getTenantSettings(tenantId);
  const model = inputModel || tenantDefaults?.model || "arima";
  const mode = inputMode || tenantDefaults?.mode || "local";
  const seasonality = inputSeasonality || tenantDefaults?.seasonality || "auto";

  await setTenantSettings(tenantId, { model, mode, seasonality });

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

  const latestRun = await getLatestRun(tenantId);
  const baseS3OutputPrefix = latestRun?.s3OutputPrefix || null;

  const payload = {
    mode: "forecast_run",
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
  if (!tenantId) return { status: "error", message: "missing_tenant", result: {} };

  const runId = event?.input?.runId || event?.arguments?.runId;
  if (!runId) return { status: "error", message: "missing_runId", result: {} };

  const item = await getRunById(tenantId, runId);
  return { status: "success", run: normalizeRun(item) };
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

      let summary = null;
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
    return { status: "error", result: {} };
  }
};

exports.handler = async (event) => {
  try {
    requireEnv(ARTIFACT_BUCKET, "ARTIFACT_BUCKET");
    requireEnv(FORECAST_RUNS_TABLE, "FORECAST_RUNS_TABLE");

    const identityKeys = event?.identity ? Object.keys(event.identity) : [];
    const claimKeys = event?.identity?.claims ? Object.keys(event.identity.claims) : [];
    const headerKeys = event?.request?.headers ? Object.keys(event.request.headers) : [];
    console.log(
      JSON.stringify({
        msg: "orchestrator_identity_debug",
        identityKeys,
        claimKeys,
        headerKeys,
        authHeaderPresent: Boolean(event?.request?.headers?.Authorization || event?.request?.headers?.authorization),
      })
    );

    const fieldName = event?.info?.fieldName || "";

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
      default:
        return { status: "error", message: "unknown_field", result: {} };
    }
  } catch (err) {
    return {
      status: "error",
      message: err instanceof Error ? err.message : "handler_error",
      result: {},
    };
  }
};
