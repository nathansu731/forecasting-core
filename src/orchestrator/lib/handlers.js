const {
  ddb,
  lambda,
  marshall,
  unmarshall,
  PutItemCommand,
  QueryCommand,
  UpdateItemCommand,
  InvokeCommand,
  RAW_BUCKET,
  ARTIFACT_BUCKET,
  FORECAST_RUNS_TABLE,
  DATA_SNAPSHOTS_TABLE,
  FORECAST_LAMBDA_ARN,
  NOTIFICATIONS_TABLE,
  getTenantId,
  getTenantSettings,
  setTenantSettings,
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
    default:
      return { status: "error", message: "unknown_field", result: {} };
  }
};

module.exports = {
  dispatchField,
};
