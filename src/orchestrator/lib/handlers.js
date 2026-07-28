const crypto = require("crypto");
const { searchKnowledgeBase } = require("./assistant-kb");

const {
  ddb,
  sqs,
  marshall,
  unmarshall,
  PutItemCommand,
  GetItemCommand,
  QueryCommand,
  UpdateItemCommand,
  DeleteItemCommand,
  SendMessageCommand,
  RAW_BUCKET,
  ARTIFACT_BUCKET,
  FORECAST_RUNS_TABLE,
  DATA_SNAPSHOTS_TABLE,
  FORECAST_GLOBAL_RUNS_QUEUE_URL,
  FORECAST_LOCAL_RUNS_QUEUE_URL,
  FORECAST_LOCAL_BATCH_QUEUE_URL,
  FORECAST_LOCAL_BATCH_SIZE,
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
  getTenantForecastApprovals,
  setTenantForecastApproval,
  setTenantAssistantSummary,
  nowIso,
  randomId,
  getLatestRun,
  getRunById,
  readJsonFromS3,
  readTextFromS3,
  writeJsonToS3,
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
const MAX_UPLOAD_COLUMNS = 40;
const MAX_CELL_CHARACTERS = 2000;
const PLAN_UPLOAD_LIMITS = {
  launch: {
    maxRows: 50000,
    maxSeries: 250,
    maxHistoryDays: 365,
    maxSeriesPoints: 365,
  },
  professional: {
    maxRows: 150000,
    maxSeries: 1500,
    maxHistoryDays: 730,
    maxSeriesPoints: 730,
  },
  enterprise: {
    maxRows: 300000,
    maxSeries: 5000,
    maxHistoryDays: 730,
    maxSeriesPoints: 730,
  },
};

const round = (value, digits = 2) => {
  if (typeof value !== "number" || Number.isNaN(value)) return null;
  const scale = 10 ** digits;
  return Math.round(value * scale) / scale;
};

const hashText = (value) => crypto.createHash("sha256").update(String(value || "")).digest("hex").slice(0, 12);

const normalizeColumnKey = (value) => String(value || "").trim().toLowerCase().replace(/[^a-z0-9]+/g, "");

const parseCsvLine = (line) => {
  const values = [];
  let current = "";
  let inQuotes = false;

  for (let index = 0; index < line.length; index += 1) {
    const char = line[index];
    if (char === '"') {
      if (inQuotes && line[index + 1] === '"') {
        current += '"';
        index += 1;
      } else {
        inQuotes = !inQuotes;
      }
      continue;
    }
    if (char === "," && !inQuotes) {
      values.push(current.trim());
      current = "";
      continue;
    }
    current += char;
  }

  values.push(current.trim());
  return values;
};

const parseCsvRecords = (raw) => {
  const lines = String(raw || "")
    .split(/\r?\n/)
    .filter((line) => line.trim().length > 0);
  if (!lines.length) return { headers: [], records: [] };

  const headers = parseCsvLine(lines[0]).filter((value) => value.length > 0);
  const records = lines.slice(1).map((line) => {
    const values = parseCsvLine(line);
    return headers.reduce((acc, header, index) => {
      acc[header] = values[index] || "";
      return acc;
    }, {});
  });

  return { headers, records };
};

const hasUnsafeControlCharacters = (raw) => /[\x00-\x08\x0B\x0C\x0E-\x1F]/.test(String(raw || ""));

const parseDateByFormat = (value, format) => {
  const trimmed = String(value || "").trim();
  if (!trimmed) return null;

  const normalized = normalizeColumnKey(format || "dd/mm/yyyy");
  const parts = trimmed.split(/[/-]/);
  const buildDate = (year, month, day) => {
    const date = new Date(Date.UTC(year, month - 1, day));
    return Number.isNaN(date.getTime()) ? null : date;
  };

  if (normalized === "ddmmyyyy" && parts.length === 3) {
    return buildDate(Number(parts[2]), Number(parts[1]), Number(parts[0]));
  }
  if (normalized === "mmddyyyy" && parts.length === 3) {
    return buildDate(Number(parts[2]), Number(parts[0]), Number(parts[1]));
  }
  if (normalized === "yyyymmdd" && parts.length === 3) {
    return buildDate(Number(parts[0]), Number(parts[1]), Number(parts[2]));
  }

  const fallback = new Date(trimmed);
  return Number.isNaN(fallback.getTime()) ? null : fallback;
};

const validateCsvStructure = (raw, plan = "launch") => {
  const limits = getPlanUploadLimits(plan);
  if (!String(raw || "").trim()) {
    return { ok: false, code: "EMPTY_UPLOAD", message: "The uploaded CSV is empty." };
  }
  if (hasUnsafeControlCharacters(raw)) {
    return {
      ok: false,
      code: "UNSAFE_CONTROL_CHARACTERS",
      message: "The uploaded file contains unsupported control characters or binary content.",
    };
  }

  const { headers, records } = parseCsvRecords(raw);
  if (!headers.length || !records.length) {
    return {
      ok: false,
      code: "CSV_HEADERS_OR_ROWS_MISSING",
      message: "The uploaded CSV must include a header row and at least one data row.",
    };
  }
  if (headers.length > MAX_UPLOAD_COLUMNS) {
    return {
      ok: false,
      code: "UPLOAD_COLUMNS_LIMIT_EXCEEDED",
      message: `The uploaded CSV has ${headers.length} columns. Limit uploads to ${MAX_UPLOAD_COLUMNS} columns or fewer.`,
      headers,
      records,
    };
  }
  if (records.length > limits.maxRows) {
    return {
      ok: false,
      code: "UPLOAD_ROWS_LIMIT_EXCEEDED",
      message: `This ${normalizePlan(plan)} plan supports up to ${limits.maxRows.toLocaleString("en-US")} rows per upload. Reduce the file and try again.`,
      headers,
      records,
    };
  }
  if (headers.some((header) => String(header || "").length > 120)) {
    return {
      ok: false,
      code: "UPLOAD_HEADER_LENGTH_EXCEEDED",
      message: "One or more column headers are unusually long. Clean the file before uploading.",
      headers,
      records,
    };
  }

  for (const record of records) {
    for (const value of Object.values(record)) {
      if (String(value || "").length > MAX_CELL_CHARACTERS) {
        return {
          ok: false,
          code: "UPLOAD_CELL_LENGTH_EXCEEDED",
          message: `The uploaded CSV contains cell values longer than ${MAX_CELL_CHARACTERS} characters. Remove unrelated text fields before uploading.`,
          headers,
          records,
        };
      }
    }
  }

  return { ok: true, headers, records };
};

const findMatchingHeader = (headers, candidates) => {
  const headerMap = new Map(headers.map((header) => [normalizeColumnKey(header), header]));
  for (const candidate of candidates.filter(Boolean)) {
    const match = headerMap.get(normalizeColumnKey(candidate));
    if (match) return match;
  }
  return "";
};

const resolvePreferredHeader = (headers, explicitValue, candidates) => {
  if (explicitValue && headers.includes(explicitValue)) return explicitValue;
  return findMatchingHeader(headers, [explicitValue, ...candidates]);
};

const inspectTargetColumnFromCsv = (raw, { targetVariable, skuColumnName, storeColumnName }) => {
  const { headers, records } = parseCsvRecords(raw);
  if (!headers.length || !records.length) {
    throw new Error("Uploaded CSV is empty or missing headers");
  }

  const resolvedTargetColumn = resolvePreferredHeader(headers, targetVariable, [
    "quantity",
    "qty",
    "demand",
    "sales",
    "units",
    "volume",
  ]);
  const resolvedSkuColumn = resolvePreferredHeader(headers, skuColumnName, [
    "sku",
    "sku_id",
    "skuid",
    "product",
    "productid",
    "product_id",
    "item",
    "itemid",
    "item_id",
  ]);
  const resolvedStoreColumn = resolvePreferredHeader(headers, storeColumnName, [
    "location",
    "store",
    "storeid",
    "store_id",
    "storename",
    "store_name",
    "shop",
    "shopid",
    "shop_id",
    "outlet",
    "outletid",
    "outlet_id",
    "branch",
    "branchid",
    "branch_id",
  ]);

  if (!resolvedTargetColumn) {
    return {
      targetColumnName: null,
      totalRows: records.length,
      validRows: 0,
      invalidRowCount: records.length,
      exampleInvalidRows: [],
    };
  }

  let validRows = 0;
  const exampleInvalidRows = [];

  records.forEach((record, index) => {
    const rawValue = String(record[resolvedTargetColumn] || "").trim();
    const parsedValue = Number(rawValue);
    if (rawValue && Number.isFinite(parsedValue)) {
      validRows += 1;
      return;
    }

    if (exampleInvalidRows.length < 5) {
      exampleInvalidRows.push({
        rowNumber: index + 2,
        rawValue,
        sku: resolvedSkuColumn ? String(record[resolvedSkuColumn] || "").trim() || null : null,
        store: resolvedStoreColumn ? String(record[resolvedStoreColumn] || "").trim() || null : null,
        reason: rawValue ? "non-numeric or infinite" : "blank",
      });
    }
  });

  return {
    targetColumnName: resolvedTargetColumn,
    totalRows: records.length,
    validRows,
    invalidRowCount: records.length - validRows,
    exampleInvalidRows,
  };
};

const estimateSeriesCountFromCsv = (raw, { skuColumnName, storeColumnName }) => {
  const { headers, records } = parseCsvRecords(raw);
  if (!headers.length || !records.length) {
    throw new Error("Uploaded CSV is empty or missing headers");
  }

  const resolvedSkuColumn = resolvePreferredHeader(headers, skuColumnName, [
    "sku",
    "sku_id",
    "skuid",
    "product",
    "productid",
    "product_id",
    "item",
    "itemid",
    "item_id",
  ]);
  const resolvedStoreColumn = resolvePreferredHeader(headers, storeColumnName, [
    "location",
    "store",
    "storeid",
    "store_id",
    "storename",
    "store_name",
    "shop",
    "shopid",
    "shop_id",
    "outlet",
    "outletid",
    "outlet_id",
    "branch",
    "branchid",
    "branch_id",
  ]);

  const seriesKeys = new Set(
    records.map((record) => {
      const skuValue = resolvedSkuColumn ? String(record[resolvedSkuColumn] || "").trim() : "";
      const storeValue = resolvedStoreColumn ? String(record[resolvedStoreColumn] || "").trim() : "";
      return `${skuValue || "SKU-1"}::${storeValue || "location-1"}`;
    })
  );

  return {
    seriesCount: seriesKeys.size,
    seriesKeys: Array.from(seriesKeys).sort(),
    skuColumnName: resolvedSkuColumn || null,
    storeColumnName: resolvedStoreColumn || null,
  };
};

const validateSalesCsvScope = (raw, { dateFormat, skuColumnName, storeColumnName, plan = "launch" }) => {
  const structural = validateCsvStructure(raw, plan);
  if (!structural.ok) return structural;

  const limits = getPlanUploadLimits(plan);
  const { headers, records } = structural;
  const dateHeader = findMatchingHeader(headers, ["date"]);
  if (!dateHeader) {
    return {
      ok: false,
      code: "DATE_COLUMN_MISSING",
      message: "The uploaded CSV must include a date column for forecasting history.",
    };
  }

  const resolvedSkuColumn = resolvePreferredHeader(headers, skuColumnName, [
    "sku",
    "sku_id",
    "skuid",
    "product",
    "productid",
    "product_id",
    "item",
    "itemid",
    "item_id",
  ]);
  const resolvedStoreColumn = resolvePreferredHeader(headers, storeColumnName, [
    "location",
    "store",
    "storeid",
    "store_id",
    "storename",
    "store_name",
    "shop",
    "shopid",
    "shop_id",
    "outlet",
    "outletid",
    "outlet_id",
    "branch",
    "branchid",
    "branch_id",
  ]);

  let minDateMs = null;
  let maxDateMs = null;
  let validDateCount = 0;
  const seriesCounts = new Map();

  records.forEach((record) => {
    const parsedDate = parseDateByFormat(record[dateHeader], dateFormat);
    if (!parsedDate) return;

    const timestamp = parsedDate.getTime();
    validDateCount += 1;
    minDateMs = minDateMs === null ? timestamp : Math.min(minDateMs, timestamp);
    maxDateMs = maxDateMs === null ? timestamp : Math.max(maxDateMs, timestamp);

    const skuValue = resolvedSkuColumn ? String(record[resolvedSkuColumn] || "").trim() || "SKU-1" : "SKU-1";
    const storeValue = resolvedStoreColumn ? String(record[resolvedStoreColumn] || "").trim() || "location-1" : "location-1";
    const seriesKey = `${skuValue}::${storeValue}`;
    seriesCounts.set(seriesKey, (seriesCounts.get(seriesKey) || 0) + 1);
  });

  if (!validDateCount || minDateMs === null || maxDateMs === null) {
    return {
      ok: false,
      code: "NO_VALID_DATES",
      message: `No valid dates were found using the selected ${dateFormat} format.`,
    };
  }

  const historySpanDays = Math.floor((maxDateMs - minDateMs) / (24 * 60 * 60 * 1000));
  if (historySpanDays > limits.maxHistoryDays) {
    return {
      ok: false,
      code: "HISTORY_WINDOW_EXCEEDED",
      message: `The uploaded history spans ${historySpanDays} days. Limit uploads to the most recent ${limits.maxHistoryDays} days for the ${normalizePlan(plan)} plan.`,
      historySpanDays,
    };
  }

  if (seriesCounts.size > limits.maxSeries) {
    return {
      ok: false,
      code: "PLAN_SERIES_LIMIT_EXCEEDED",
      message: `This ${normalizePlan(plan)} plan supports up to ${limits.maxSeries.toLocaleString("en-US")} SKU-location series per run. Reduce the file scope and try again.`,
      seriesCount: seriesCounts.size,
    };
  }

  const maxSeriesPoints = Array.from(seriesCounts.values()).reduce((max, count) => Math.max(max, count), 0);
  if (maxSeriesPoints > limits.maxSeriesPoints) {
    return {
      ok: false,
      code: "SERIES_POINTS_LIMIT_EXCEEDED",
      message: `At least one SKU-location series contains ${maxSeriesPoints} data points. Limit each series to ${limits.maxSeriesPoints} rows or fewer for the ${normalizePlan(plan)} plan.`,
      maxSeriesPoints,
    };
  }

  return { ok: true };
};

const chunkArray = (items, chunkSize) => {
  const chunks = [];
  for (let index = 0; index < items.length; index += chunkSize) {
    chunks.push(items.slice(index, index + chunkSize));
  }
  return chunks;
};

const normalizePositiveInteger = (value, fallbackValue, { min = 1, max = Number.MAX_SAFE_INTEGER } = {}) => {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return fallbackValue;
  return Math.max(min, Math.min(max, Math.floor(parsed)));
};

const resolveLocalBatchSize = ({ configuredBatchSize, model, seriesCount }) => {
  const safeSeriesCount = normalizePositiveInteger(seriesCount, 1, { min: 1, max: 100 });
  if (Number.isFinite(Number(configuredBatchSize)) && Number(configuredBatchSize) > 0) {
    return normalizePositiveInteger(configuredBatchSize, 2, { min: 1, max: safeSeriesCount });
  }

  if (model === "regression_arima") {
    return safeSeriesCount <= 4 ? 2 : 4;
  }

  if (model === "arima") {
    return safeSeriesCount <= 10 ? 5 : 10;
  }

  return Math.min(5, safeSeriesCount);
};

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

const parseRunSummaryObject = (summary) => {
  if (!summary) return null;
  if (typeof summary === "string") {
    try {
      return JSON.parse(summary);
    } catch {
      return null;
    }
  }
  return typeof summary === "object" ? summary : null;
};

const toFiniteNumberOrNull = (value) => {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
};

const sumFiniteValues = (values) =>
  values.reduce((sum, value) => (Number.isFinite(Number(value)) ? sum + Number(value) : sum), 0);

const ROUTE_TO_PAGE_ID = {
  "/data-input": "data-input",
  "/dashboard": "dashboard",
  "/overview": "overview",
  "/kpis": "kpis",
  "/reports": "reports",
  "/replenishments": "replenishments",
  "/notifications": "notifications",
  "/forecasts/forecasting-summary": "forecasting-summary",
  "/forecasts/forecast-navigator": "forecast-navigator",
  "/forecasts/forecast-editor": "forecast-editor",
};

const normalizePageId = ({ pageId, route }) => {
  const routeValue = String(route || "").trim();
  if (pageId) return String(pageId).trim().toLowerCase();
  if (!routeValue) return "dashboard";
  return ROUTE_TO_PAGE_ID[routeValue] || routeValue.replace(/^\//, "").replace(/\//g, "-") || "dashboard";
};

const buildPageContext = (input = {}) => {
  const route = String(input?.route || "").trim() || null;
  return {
    pageId: normalizePageId({ pageId: input?.pageId, route }),
    route,
    contextMode: String(input?.contextMode || "analysis").trim().toLowerCase() || "analysis",
    selectedSku: String(input?.selectedSku || "").trim() || null,
    selectedStore: String(input?.selectedStore || "").trim() || null,
  };
};

const formatSeriesLabel = (sku, store) => {
  if (sku && store) return `${sku} @ ${store}`;
  return sku || store || null;
};

const buildSeriesFacts = (metadata) =>
  Object.values(metadata || {})
    .slice(0, 8)
    .map((details) => ({
      series: formatSeriesLabel(details?.sku || null, details?.store || null),
      abcClass: details?.ABCclass || null,
      forecastMethod: details?.forecastMethod || null,
      approved: typeof details?.isApproved === "boolean" ? details.isApproved : null,
    }))
    .filter((item) => item.series);

const findSelectedSeriesDiagnostics = ({ summary, metadata, replenishmentSignals, pageContext }) => {
  const sku = String(pageContext?.selectedSku || "").trim();
  const store = String(pageContext?.selectedStore || "").trim();
  if (!sku) return null;
  const perSeries = Array.isArray(summary?.validation?.selectedModel?.perSeries) ? summary.validation.selectedModel.perSeries : [];
  const selectedValidation =
    perSeries.find((item) => String(item?.sku || "").trim() === sku && (!store || String(item?.store || "").trim() === store)) ||
    perSeries.find((item) => String(item?.seriesKey || "").trim() === `${sku}::${store}`) ||
    null;

  const metadataEntry =
    Object.values(metadata || {}).find((item) => String(item?.sku || "").trim() === sku && (!store || String(item?.store || "").trim() === store)) ||
    null;

  const replenishmentItem =
    (Array.isArray(replenishmentSignals?.items) ? replenishmentSignals.items : []).find(
      (item) => String(item?.sku || "").trim() === sku && (!store || String(item?.store || "").trim() === store)
    ) || null;

  return {
    sku,
    store: store || metadataEntry?.store || selectedValidation?.store || replenishmentItem?.store || null,
    seriesLabel: formatSeriesLabel(sku, store || metadataEntry?.store || selectedValidation?.store || replenishmentItem?.store || null),
    method:
      metadataEntry?.forecastMethod ||
      selectedValidation?.modelUsed ||
      selectedValidation?.plannedMethod ||
      summary?.validation?.selectedModel?.model ||
      null,
    abcClass: metadataEntry?.ABCclass || null,
    metrics: {
      smape: round(selectedValidation?.metrics?.smape, 3),
      mae: round(selectedValidation?.metrics?.mae, 3),
      rmse: round(selectedValidation?.metrics?.rmse, 3),
      windows: Number.isFinite(Number(selectedValidation?.windows)) ? Number(selectedValidation.windows) : null,
    },
    replenishment: replenishmentItem
      ? {
          risk: replenishmentItem?.risk || null,
          daysOfCover: Number.isFinite(Number(replenishmentItem?.daysOfCover)) ? Number(replenishmentItem.daysOfCover) : null,
          reorderByDate: replenishmentItem?.reorderByDate || null,
          predictedStockoutDate: replenishmentItem?.predictedStockoutDate || null,
          recommendedReorderQty: Number.isFinite(Number(replenishmentItem?.recommendedReorderQty))
            ? Number(replenishmentItem.recommendedReorderQty)
            : null,
          onHandSource: replenishmentItem?.onHandSource || null,
        }
      : null,
  };
};

const summarizeSelectedSeriesForecast = ({ skuForecastValues, pageContext }) => {
  const sku = String(pageContext?.selectedSku || "").trim();
  const store = String(pageContext?.selectedStore || "").trim();
  if (!sku) return null;

  const items = Array.isArray(skuForecastValues?.items) ? skuForecastValues.items : [];
  const selectedItem =
    items.find((item) => String(item?.sku || "").trim() === sku && (!store || String(item?.store || "").trim() === store)) ||
    null;

  if (!selectedItem) return null;

  const periods = Array.isArray(selectedItem?.periods) ? selectedItem.periods : [];
  const demandEntries = periods
    .map((period) => ({ period, value: selectedItem?.demand?.[period] }))
    .filter((entry) => typeof entry.value === "number" && Number.isFinite(entry.value));
  const forecastEntries = periods
    .map((period) => ({
      period,
      baseline: toFiniteNumberOrNull(selectedItem?.forecastBaseline?.[period]),
      adjustment: toFiniteNumberOrNull(selectedItem?.forecastAdjustment?.[period]) ?? 0,
      lower80: toFiniteNumberOrNull(selectedItem?.lower80?.[period]),
      upper80: toFiniteNumberOrNull(selectedItem?.upper80?.[period]),
    }))
    .filter((entry) => entry.baseline !== null);

  const futureForecasts = forecastEntries.map((entry) => ({
    period: entry.period,
    adjustedForecast: round((entry.baseline || 0) + (entry.adjustment || 0), 3),
    baseline: round(entry.baseline, 3),
    adjustment: round(entry.adjustment, 3),
    lower80: round(entry.lower80, 3),
    upper80: round(entry.upper80, 3),
  }));

  const totalForecast = round(sumFiniteValues(futureForecasts.map((entry) => entry.adjustedForecast)), 3);
  const totalAdjustment = round(sumFiniteValues(futureForecasts.map((entry) => entry.adjustment)), 3);
  const lastActual = demandEntries.length > 0 ? demandEntries[demandEntries.length - 1] : null;
  const nextForecast = futureForecasts.length > 0 ? futureForecasts[0] : null;
  const maxForecast =
    futureForecasts.length > 0
      ? futureForecasts.reduce((best, entry) => (entry.adjustedForecast > best.adjustedForecast ? entry : best), futureForecasts[0])
      : null;

  return {
    seriesLabel: formatSeriesLabel(selectedItem.sku || sku, selectedItem.store || store || null),
    frequency: selectedItem?.frequency || skuForecastValues?.frequency || null,
    historicalPeriods: demandEntries.length,
    forecastPeriods: futureForecasts.length,
    lastActual: lastActual ? { period: lastActual.period, value: round(lastActual.value, 3) } : null,
    nextForecast,
    maxForecast: maxForecast ? { period: maxForecast.period, value: maxForecast.adjustedForecast } : null,
    totalForecast,
    totalAdjustment,
    recentForecasts: futureForecasts.slice(0, 6),
  };
};

const buildReplenishmentFacts = (replenishmentSignals) => {
  const replenishmentItems = Array.isArray(replenishmentSignals?.items) ? replenishmentSignals.items : [];
  const highRiskItems = replenishmentItems
    .filter((item) => item?.risk === "High")
    .slice(0, 6)
    .map((item) => ({
      series: formatSeriesLabel(item?.sku || null, item?.store || null),
      risk: item?.risk || null,
      daysOfCover: Number.isFinite(Number(item?.daysOfCover)) ? Number(item.daysOfCover) : null,
      reorderByDate: item?.reorderByDate || null,
      predictedStockoutDate: item?.predictedStockoutDate || null,
      recommendedReorderQty: Number.isFinite(Number(item?.recommendedReorderQty)) ? Number(item.recommendedReorderQty) : null,
      onHandSource: item?.onHandSource || null,
    }))
    .filter((item) => item.series);

  return {
    horizonDays: replenishmentSignals?.horizonDays || null,
    highRiskCount: highRiskItems.length,
    highRiskItems,
  };
};

const summarizeRecentRuns = (runs) => {
  const parsedRuns = (runs || [])
    .map((run) => {
      const summary = parseRunSummaryObject(run?.summary);
      const smape = Number(summary?.validation?.selectedModel?.metrics?.smape);
      const accuracy = Number.isFinite(smape) ? Math.max(0, 100 - smape) : null;
      return {
        runId: run?.runId || null,
        createdAt: run?.createdAt || null,
        status: run?.status || null,
        model:
          summary?.validation?.selectedModel?.model ||
          summary?.runConfig?.executedModel ||
          null,
        smape: Number.isFinite(smape) ? round(smape, 3) : null,
        accuracy: Number.isFinite(accuracy) ? round(accuracy, 3) : null,
      };
    })
    .filter((item) => item.runId);

  const latest = parsedRuns[0] || null;
  const previous = parsedRuns[1] || null;
  const bestAccuracy = parsedRuns
    .filter((item) => Number.isFinite(item.accuracy))
    .sort((left, right) => (right.accuracy || 0) - (left.accuracy || 0))[0] || null;
  const worstSmape = parsedRuns
    .filter((item) => Number.isFinite(item.smape))
    .sort((left, right) => (right.smape || 0) - (left.smape || 0))[0] || null;

  return {
    latest,
    previous,
    bestAccuracy,
    worstSmape,
    deltaSmape:
      latest && previous && Number.isFinite(latest.smape) && Number.isFinite(previous.smape)
        ? round((latest.smape || 0) - (previous.smape || 0), 3)
        : null,
    trendPoints: parsedRuns.slice(0, 10),
  };
};

const buildContextPayload = ({ run, summary, metadata, monthlyTotals, replenishmentSignals, skuForecastValues, tenantSettings, pageContext }) => {
  const metrics = summary?.validation?.selectedModel?.metrics || {};
  const totalRows = Number(summary?.rows || 0);
  const totalSkus = Number(summary?.totalSkus || 0);
  const totalSeries = Number(summary?.totalSeries || 0);
  const coverageRatio = totalSkus > 0 ? clamp(round(totalRows / totalSkus, 2) || 0, 0, 999999) : null;
  const selectedSeries = findSelectedSeriesDiagnostics({ summary, metadata, replenishmentSignals, pageContext });
  const selectedSeriesForecast = summarizeSelectedSeriesForecast({ skuForecastValues, pageContext });

  return {
    page: pageContext,
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
      totalSeries,
      avgRowsPerSku: coverageRatio,
    },
    settings: {
      defaultModel: tenantSettings?.model || null,
      defaultMode: tenantSettings?.mode || null,
      defaultSeasonality: tenantSettings?.seasonality || null,
      defaultForecastHorizon: tenantSettings?.forecastHorizon || null,
      skuColumnName: tenantSettings?.skuColumnName || null,
      storeColumnName: tenantSettings?.storeColumnName || null,
      targetVariable: tenantSettings?.targetVariable || null,
      onHandColumnName: tenantSettings?.onHandColumnName || null,
      priceColumnName: tenantSettings?.priceColumnName || null,
      holidayColumnName: tenantSettings?.holidayColumnName || null,
      promotionColumnName: tenantSettings?.promotionColumnName || null,
      openStatusColumnName: tenantSettings?.openStatusColumnName || null,
    },
    quality: {
      smape: round(metrics?.smape, 3),
      mae: round(metrics?.mae, 3),
      rmse: round(metrics?.rmse, 3),
      modelStrategy: summary?.validation?.selectedModel?.strategy || null,
      windows: summary?.validation?.selectedModel?.windows || null,
    },
    selectedSeries,
    selectedSeriesForecast,
    series: buildSeriesFacts(metadata),
    monthlyTotals: summarizeMonthlyTotals(monthlyTotals),
    replenishment: buildReplenishmentFacts(replenishmentSignals),
  };
};

const defaultAssistantResponse = (context) => ({
  status: "success",
  intent: "forecast_onboarding",
  assistantText:
    "Connect a source (or upload CSV), set model and forecast horizon in Advanced Settings, run forecasting, then review quality metrics and replenishment risks.",
  context,
  confidence: context?.run?.runId ? 0.52 : 0.32,
  evidence: [],
  warnings: [],
  usedTools: [],
  answerVersion: "v2",
  checklist: [
    "Confirm at least one data source is connected.",
    "Upload a clean file with required columns.",
    "Set forecast horizon in Advanced Settings (default: 30).",
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
      description: "Upload your dataset, confirm model and forecast horizon, then launch a forecast run from Data Input.",
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

const parseAssistantResponsePayload = (payload) => {
  if (!payload || typeof payload !== "object") return null;
  if (typeof payload.output_text === "string" && payload.output_text.trim()) {
    return parseOpenAiContent(payload.output_text);
  }

  const outputItems = Array.isArray(payload.output) ? payload.output : [];
  for (const item of outputItems) {
    const contents = Array.isArray(item?.content) ? item.content : [];
    for (const content of contents) {
      const possibleText =
        content?.text ||
        content?.output_text ||
        content?.json ||
        (typeof content === "string" ? content : null);
      if (typeof possibleText === "string") {
        const parsed = parseOpenAiContent(possibleText);
        if (parsed) return parsed;
      }
      if (possibleText && typeof possibleText === "object") {
        return possibleText;
      }
    }
  }
  return null;
};

const ALLOWED_ASSISTANT_ROUTES = [
  "/data-input",
  "/dashboard",
  "/notifications",
  "/overview",
  "/kpis",
  "/reports",
  "/replenishments",
  "/forecasts/forecasting-summary",
  "/forecasts/forecast-navigator",
  "/forecasts/forecast-editor",
];

const sanitizeActionRoute = (value) => {
  if (!value || typeof value !== "string") return null;
  const route = String(value).trim();
  if (!route.startsWith("/")) return null;
  if (ALLOWED_ASSISTANT_ROUTES.some((allowed) => route === allowed || route.startsWith(`${allowed}?`))) {
    return route;
  }
  return null;
};

const sanitizeAction = (value, fallbackId) => {
  if (!value || typeof value !== "object") return null;
  return {
    id: String(value.id || `${fallbackId}-action`),
    label: String(value.label || "Open"),
    route: sanitizeActionRoute(value.route),
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

const sanitizeEvidence = (evidence) => {
  if (!Array.isArray(evidence)) return [];
  return evidence
    .slice(0, 6)
    .map((item) => ({
      source: String(item?.source || "unknown"),
      title: String(item?.title || "Evidence"),
      detail: String(item?.detail || "").trim(),
    }))
    .filter((item) => item.detail);
};

const sanitizeWarnings = (warnings) =>
  Array.isArray(warnings) ? warnings.map((item) => String(item || "").trim()).filter(Boolean).slice(0, 6) : [];

const sanitizeUsedTools = (usedTools) =>
  Array.isArray(usedTools) ? usedTools.map((item) => String(item || "").trim()).filter(Boolean).slice(0, 12) : [];

const PLAN_CAPS = {
  launch: { requestsPerMonth: 100, tokensPerMonth: 200000 },
  professional: { requestsPerMonth: 500, tokensPerMonth: 2000000 },
  enterprise: { requestsPerMonth: 2000, tokensPerMonth: 10000000 },
};

const ALLOWED_MODELS = new Set(["gpt-4o-mini", "gpt-4.1-mini", "gpt-4.1"]);

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
  "kpi",
  "editor",
  "navigator",
  "summary",
  "quickbooks",
  "shopify",
  "bigcommerce",
  "amazon",
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

const PLAN_ALLOWED_LOCAL_MODELS = {
  launch: ["arima", "regression_arima"],
  professional: ["arima", "regression_arima", "ets", "ses", "theta", "tbats", "dhr_arima", "naive", "snaive", "croston"],
  enterprise: ["arima", "regression_arima", "ets", "ses", "theta", "tbats", "dhr_arima", "naive", "snaive", "croston"],
};

const PLAN_ALLOWED_GLOBAL_MODELS = {
  launch: ["xgboost"],
  professional: ["xgboost"],
  enterprise: ["xgboost", "pooled_regression"],
};

const normalizeRequestedMode = (value, plan) => {
  const mode = String(value || "").toLowerCase().trim();
  const allowedGlobal = PLAN_ALLOWED_GLOBAL_MODELS[plan] || PLAN_ALLOWED_GLOBAL_MODELS.launch;
  if (mode === "global" && allowedGlobal.length > 0) return "global";
  return "local";
};

const normalizeRequestedModel = (value, plan, mode) => {
  const requested = String(value || "").toLowerCase().trim();
  const allowed = mode === "global"
    ? (PLAN_ALLOWED_GLOBAL_MODELS[plan] || PLAN_ALLOWED_GLOBAL_MODELS.launch)
    : (PLAN_ALLOWED_LOCAL_MODELS[plan] || PLAN_ALLOWED_LOCAL_MODELS.launch);
  if (allowed.includes(requested)) return requested;
  return allowed[0] || "arima";
};

const normalizeRequestedHorizon = (value, fallback = 30) => {
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed <= 0) return fallback;
  return Math.max(1, Math.min(365, Math.floor(parsed)));
};

const getPlanUploadLimits = (plan) => PLAN_UPLOAD_LIMITS[normalizePlan(plan)] || PLAN_UPLOAD_LIMITS.launch;

const ACTIVE_TENANT_STATUSES = new Set(["active", "past_due", "unpaid"]);
const PROTECTED_FIELDS = new Set([
  "startForecastRun",
  "getForecastRun",
  "listForecastRuns",
  "listNotifications",
  "markNotificationRead",
  "markAllNotificationsRead",
  "clearCompletedNotifications",
  "getSKUsMetadata",
  "getSKUForecasts",
  "getMonthlyTotals",
  "getDailyForecasts",
  "getReportSummary",
  "getSkuForecastValues",
  "getMergedSkuForecastValues",
  "getReplenishmentSignals",
  "getTenantSettings",
  "setTenantSettings",
  "getForecastApprovals",
  "setForecastApproval",
  "forecastAssistant",
  "getAssistantUsage",
]);

const normalizeTenantStatus = (value) => String(value || "").trim().toLowerCase();

const getTenantAccessState = async (tenantId) => {
  const tenantSettings = await getTenantSettings(tenantId);
  const tenantStatus = normalizeTenantStatus(tenantSettings?.status);
  const trialEndsAt = typeof tenantSettings?.trialEndsAt === "string" ? tenantSettings.trialEndsAt : "";
  const trialEndMs = Date.parse(trialEndsAt);
  const trialWindowActive = Number.isFinite(trialEndMs) && trialEndMs > Date.now();
  const trialWindowExpired = Number.isFinite(trialEndMs) && trialEndMs <= Date.now();

  let entitlementIsActive = null;
  if (ENTITLEMENTS_TABLE) {
    const res = await ddb.send(
      new GetItemCommand({
        TableName: ENTITLEMENTS_TABLE,
        Key: marshall({ tenantId }),
      })
    );
    if (res.Item) {
      const item = unmarshall(res.Item);
      if (typeof item?.isActive === "boolean") {
        entitlementIsActive = item.isActive;
      }
    }
  }

  const paidAccessActive =
    ACTIVE_TENANT_STATUSES.has(tenantStatus) || entitlementIsActive === true;
  const trialRestricted =
    (tenantStatus === "trial_expired") ||
    ((tenantStatus === "trialing" || tenantStatus === "trial_expired") && trialWindowExpired && !paidAccessActive);
  const activeTrial = tenantStatus === "trialing" && trialWindowActive;
  const restricted =
    trialRestricted ||
    (!activeTrial && !paidAccessActive && (entitlementIsActive === false || tenantStatus === "canceled" || tenantStatus === "inactive"));

  return {
    activeTrial,
    paidAccessActive,
    restricted,
    status: tenantStatus,
    tenantSettings,
    trialEndsAt,
  };
};

const assertTenantAccess = async (fieldName, event) => {
  if (!PROTECTED_FIELDS.has(fieldName)) return;
  const tenantId = getTenantId(event);
  if (!tenantId) {
    throw new Error("missing_tenant");
  }
  const accessState = await getTenantAccessState(tenantId);
  if (accessState.restricted) {
    throw new Error("trial_expired");
  }
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

const buildAssistantKnowledgeAndFacts = ({ command, contextPayload, tenantSettings, recentRuns }) => {
  const usedTools = [];
  const evidence = [];
  const warnings = [];
  const pageId = contextPayload?.page?.pageId || null;

  if (contextPayload?.run?.runId) {
    usedTools.push("get_run_summary");
    evidence.push({
      source: "run_summary",
      title: "Selected run",
      detail: `${contextPayload.run.selectedModel?.model || "Forecast model"} ran in ${contextPayload.run.selectedModel?.mode || contextPayload.settings?.defaultMode || "configured"} mode with status ${contextPayload.run.status}.`,
    });
  } else {
    warnings.push("No completed forecast run is selected, so the answer is based mainly on product guidance.")
  }

  if (contextPayload?.selectedSeries?.seriesLabel) {
    usedTools.push("get_series_diagnostics");
    evidence.push({
      source: "series_diagnostics",
      title: `Focused series: ${contextPayload.selectedSeries.seriesLabel}`,
      detail: `Model ${contextPayload.selectedSeries.method || "not available"}, sMAPE ${
        contextPayload.selectedSeries.metrics?.smape ?? "not available"
      }, MAE ${contextPayload.selectedSeries.metrics?.mae ?? "not available"}, risk ${
        contextPayload.selectedSeries.replenishment?.risk || "not available"
      }.`,
    });
    if (contextPayload.selectedSeries.replenishment?.onHandSource === "estimated") {
      warnings.push(`Inventory for ${contextPayload.selectedSeries.seriesLabel} is estimated rather than provided.`)
    }
  }

  if (contextPayload?.selectedSeriesForecast?.seriesLabel) {
    usedTools.push("get_series_forecast_values");
    const forecast = contextPayload.selectedSeriesForecast;
    const nextForecastText = forecast.nextForecast
      ? `Next forecast is ${forecast.nextForecast.adjustedForecast} for ${forecast.nextForecast.period}`
      : "No future forecast periods are available";
    const adjustmentText =
      forecast.totalAdjustment && Math.abs(forecast.totalAdjustment) > 0
        ? `Total forecast adjustment is ${forecast.totalAdjustment}.`
        : "No material forecast adjustments are applied.";
    evidence.push({
      source: "series_forecast",
      title: `Forecast shape for ${forecast.seriesLabel}`,
      detail: `${nextForecastText}. Total forecast across ${forecast.forecastPeriods} forecast periods is ${forecast.totalForecast ?? "not available"}. ${adjustmentText}`,
    });
    if (forecast.maxForecast) {
      evidence.push({
        source: "series_forecast",
        title: "Peak forecast period",
        detail: `The highest projected period is ${forecast.maxForecast.period} at ${forecast.maxForecast.value}.`,
      });
    }
  }

  if (Number.isFinite(contextPayload?.quality?.smape)) {
    usedTools.push("get_forecast_quality");
    evidence.push({
      source: "forecast_quality",
      title: "Validation quality",
      detail: `sMAPE is ${contextPayload.quality.smape} and MAE is ${contextPayload.quality.mae ?? "not available"} for the selected run. sMAPE is error, so lower is better.`,
    });
  } else {
    warnings.push("Forecast validation metrics are not available for this run.")
  }

  if (contextPayload?.replenishment?.highRiskCount > 0) {
    usedTools.push("get_replenishment_overview");
    const firstRisk = contextPayload.replenishment.highRiskItems?.[0];
    evidence.push({
      source: "replenishment",
      title: "Replenishment risk",
      detail: `${contextPayload.replenishment.highRiskCount} high-risk SKU-location pair${contextPayload.replenishment.highRiskCount === 1 ? "" : "s"} are flagged. ${
        firstRisk?.series ? `${firstRisk.series} is one of the urgent items.` : "The assistant should prioritize exceptions."
      }`,
    });
    if (contextPayload.replenishment.highRiskItems.some((item) => item?.onHandSource === "estimated")) {
      warnings.push("Some replenishment signals still depend on estimated on-hand inventory rather than a provided stock snapshot.")
    }
  }

  const runHistory = summarizeRecentRuns(recentRuns);
  if (runHistory.latest) {
    usedTools.push("get_run_history");
    if (pageId === "reports") {
      evidence.push({
        source: "run_history",
        title: "Recent run history",
        detail: `Recent runs include ${runHistory.trendPoints.length} tracked run${runHistory.trendPoints.length === 1 ? "" : "s"}. Best accuracy run is ${
          runHistory.bestAccuracy?.runId || "not available"
        } and worst sMAPE run is ${runHistory.worstSmape?.runId || "not available"}.`,
      });
    } else if (pageId === "kpis") {
      evidence.push({
        source: "run_history",
        title: "Run comparison",
        detail:
          runHistory.deltaSmape === null
            ? `Latest run is ${runHistory.latest.runId}. No comparable previous sMAPE trend is available.`
            : `Latest run ${runHistory.latest.runId} changed sMAPE by ${runHistory.deltaSmape} versus ${runHistory.previous?.runId}. Negative means the latest run improved.`,
      });
    }
  }

  if (contextPayload?.page?.pageId) {
    usedTools.push("get_page_help");
  }

  if (/(edit|override|change forecast)/i.test(command || "") || contextPayload?.page?.pageId === "forecast-editor") {
    usedTools.push("get_editing_rules");
  }

  usedTools.push("get_subscription_guardrails");
  if (tenantSettings?.status && !["active", "trialing", "past_due", "unpaid"].includes(String(tenantSettings.status).toLowerCase())) {
    warnings.push(`Tenant access state is ${tenantSettings.status}. Some recommendations may be restricted by plan or subscription status.`)
  }

  const knowledge = searchKnowledgeBase({
    command,
    pageId: contextPayload?.page?.pageId,
    route: contextPayload?.page?.route,
    limit: 4,
  });
  if (knowledge.length > 0) {
    usedTools.push("search_knowledge_base");
    knowledge.forEach((item) => {
      evidence.push({
        source: `kb:${item.source}`,
        title: item.title,
        detail: item.text.length > 220 ? `${item.text.slice(0, 217)}...` : item.text,
      });
    });
  }

  const confidence =
    contextPayload?.selectedSeries?.seriesLabel && Number.isFinite(contextPayload?.selectedSeries?.metrics?.smape)
      ? 0.9
      : contextPayload?.run?.runId && Number.isFinite(contextPayload?.quality?.smape)
        ? 0.84
        : contextPayload?.run?.runId
          ? 0.68
          : 0.44;

  return {
    confidence,
    evidence: sanitizeEvidence(evidence),
    warnings: sanitizeWarnings(warnings),
    usedTools: sanitizeUsedTools(usedTools),
    knowledge,
  };
};

const buildResponseSchema = () => ({
  type: "object",
  additionalProperties: false,
  required: [
    "intent",
    "assistantText",
    "checklist",
    "suggestedPrompts",
    "steps",
    "confidence",
    "evidence",
    "warnings",
    "usedTools",
  ],
  properties: {
    intent: { type: "string" },
    assistantText: { type: "string" },
    checklist: {
      type: "array",
      items: { type: "string" },
    },
    suggestedPrompts: {
      type: "array",
      items: { type: "string" },
    },
    confidence: { type: "number" },
    warnings: {
      type: "array",
      items: { type: "string" },
    },
    usedTools: {
      type: "array",
      items: { type: "string" },
    },
    evidence: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["source", "title", "detail"],
        properties: {
          source: { type: "string" },
          title: { type: "string" },
          detail: { type: "string" },
        },
      },
    },
    steps: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["id", "title", "description", "status", "action"],
        properties: {
          id: { type: "string" },
          title: { type: "string" },
          description: { type: "string" },
          status: { type: "string", enum: ["completed", "in_progress", "pending"] },
          action: {
            anyOf: [
              { type: "null" },
              {
                type: "object",
                additionalProperties: false,
                required: ["id", "label", "route", "kind"],
                properties: {
                  id: { type: "string" },
                  label: { type: "string" },
                  route: { anyOf: [{ type: "string" }, { type: "null" }] },
                  kind: { type: "string" },
                },
              },
            ],
          },
        },
      },
    },
  },
});

const buildAssistantSystemPrompt = () =>
  [
    "You are an inventory forecasting copilot for ARK Forecasting.",
    "Answer only from the supplied facts and retrieved product knowledge.",
    "If evidence is missing, explicitly say the information is unavailable or partial.",
    "Do not invent page controls, rerun behavior, calculations, or provider permissions.",
    "sMAPE is an error metric, not a direct accuracy percentage.",
    "Prefer SKU-location wording when more than one store exists.",
    "Allowed action routes: /data-input, /dashboard, /notifications, /overview, /kpis, /reports, /replenishments, /forecasts/forecasting-summary, /forecasts/forecast-navigator, /forecasts/forecast-editor.",
    "For onboarding and setup actions such as choosing model, selecting forecast horizon, reviewing settings, uploading data, or running forecast, use /data-input.",
    "Return concise, user-facing language and valid JSON that matches the schema.",
  ].join(" ");

const callAssistantViaResponsesApi = async ({ model, systemPrompt, userPayload }) => {
  const requestBody = {
    model,
    temperature: 0.2,
    max_output_tokens: 1200,
    input: [
      {
        role: "system",
        content: [{ type: "input_text", text: systemPrompt }],
      },
      {
        role: "user",
        content: [{ type: "input_text", text: JSON.stringify(userPayload) }],
      },
    ],
    text: {
      format: {
        type: "json_schema",
        name: "forecast_assistant_response",
        strict: true,
        schema: buildResponseSchema(),
      },
    },
  };

  const response = await fetch("https://api.openai.com/v1/responses", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${OPENAI_API_KEY}`,
    },
    body: JSON.stringify(requestBody),
  });

  if (!response.ok) {
    const detail = await response.text();
    throw new Error(`responses_api_failed:${response.status}:${detail}`);
  }

  const payload = await response.json();
  return {
    response: parseAssistantResponsePayload(payload),
    usage: {
      inputTokens: Number(payload?.usage?.input_tokens || 0),
      outputTokens: Number(payload?.usage?.output_tokens || 0),
    },
  };
};

const callAssistantViaChatCompletions = async ({ model, systemPrompt, userPayload }) => {
  const requestBody = {
    model,
    temperature: 0.2,
    max_tokens: 1200,
    response_format: { type: "json_object" },
    messages: [
      { role: "system", content: systemPrompt },
      { role: "user", content: JSON.stringify(userPayload) },
    ],
  };

  const response = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${OPENAI_API_KEY}`,
    },
    body: JSON.stringify(requestBody),
  });

  if (!response.ok) {
    const detail = await response.text();
    throw new Error(`chat_completions_failed:${response.status}:${detail}`);
  }

  const payload = await response.json();
  const content = payload?.choices?.[0]?.message?.content || "";
  return {
    response: parseOpenAiContent(content),
    usage: {
      inputTokens: Number(payload?.usage?.prompt_tokens || 0),
      outputTokens: Number(payload?.usage?.completion_tokens || 0),
    },
  };
};

const callAssistantModel = async ({ command, contextPayload, tenantSettings, recentRuns }) => {
  if (!OPENAI_API_KEY) return { response: null, usage: { inputTokens: 0, outputTokens: 0 } };
  const model = ALLOWED_MODELS.has(OPENAI_MODEL) ? OPENAI_MODEL : "gpt-4.1-mini";
  const systemPrompt = buildAssistantSystemPrompt();
  const facts = buildAssistantKnowledgeAndFacts({ command, contextPayload, tenantSettings, recentRuns });
  const userPayload = {
    userCommand: command,
    context: contextPayload,
    facts: {
      confidence: facts.confidence,
      evidence: facts.evidence,
      warnings: facts.warnings,
      usedTools: facts.usedTools,
      knowledgeMatches: facts.knowledge,
    },
  };

  let lastError = null;
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), Number(ASSISTANT_OPENAI_TIMEOUT_MS || 12000));
    try {
      const result = await Promise.race([
        callAssistantViaResponsesApi({ model, systemPrompt, userPayload }),
        new Promise((_, reject) =>
          controller.signal.addEventListener("abort", () => reject(new Error("assistant_timeout")), { once: true })
        ),
      ]);
      clearTimeout(timer);
      if (result?.response) return result;
      return {
        response: {
          confidence: facts.confidence,
          evidence: facts.evidence,
          warnings: facts.warnings,
          usedTools: facts.usedTools,
        },
        usage: result?.usage || { inputTokens: 0, outputTokens: 0 },
      };
    } catch (error) {
      clearTimeout(timer);
      lastError = error;
      const errorText = String(error || "");
      if (errorText.includes("responses_api_failed")) {
        try {
          const fallbackResult = await callAssistantViaChatCompletions({ model, systemPrompt, userPayload });
          if (fallbackResult?.response) return fallbackResult;
        } catch (fallbackError) {
          lastError = fallbackError;
        }
      }
      if (attempt < 2) {
        await sleep(250 * (attempt + 1));
        continue;
      }
    }
  }

  if (lastError) {
    console.error(JSON.stringify({ msg: "openai_call_exception", error: String(lastError) }));
  }
  return {
    response: {
      confidence: facts.confidence,
      evidence: facts.evidence,
      warnings: facts.warnings,
      usedTools: facts.usedTools,
    },
    usage: { inputTokens: 0, outputTokens: 0 },
  };
};

const generateForecastAssistantResponse = async ({
  command,
  run,
  runId,
  tenantSettings,
  pageContext,
  summary,
  metadata,
  monthlyTotals,
  replenishmentSignals,
  skuForecastValues,
  recentRuns,
}) => {
  const context = buildContextPayload({
    run,
    summary,
    metadata,
    monthlyTotals,
    replenishmentSignals,
    skuForecastValues,
    tenantSettings,
    pageContext,
  });

  const fallback = defaultAssistantResponse(context);
  const llmResult = await callAssistantModel({ command, contextPayload: context, tenantSettings, recentRuns });
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
    confidence: Number.isFinite(Number(llm?.confidence)) ? Number(llm.confidence) : fallback.confidence,
    evidence: sanitizeEvidence(llm?.evidence?.length ? llm.evidence : fallback.evidence),
    warnings: sanitizeWarnings(llm?.warnings?.length ? llm.warnings : fallback.warnings),
    usedTools: sanitizeUsedTools(llm?.usedTools?.length ? llm.usedTools : fallback.usedTools),
    answerVersion: typeof llm?.answerVersion === "string" ? llm.answerVersion : fallback.answerVersion,
  };

  return {
    context,
    response,
    usage: llmResult?.usage || { inputTokens: 0, outputTokens: 0 },
    resolvedRunId: run?.runId || runId || null,
  };
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
  const parentRunId = typeof input.parentRunId === "string" ? input.parentRunId.trim() || null : null;
  const scenarioLabel = typeof input.scenarioLabel === "string" ? input.scenarioLabel.trim() || null : null;
  const editedCellCount = Number.isFinite(Number(input.editedCellCount)) ? Number(input.editedCellCount) : null;
  const sku = input.sku || null;
  const store = input.store || null;
  const frequency = input.frequency || null;
  const inputModel = input.model || null;
  const inputMode = input.mode || null;
  const inputSeasonality = input.seasonality || null;
  const inputDateFormat = input.dateFormat || null;
  const inputSkuColumnName = input.skuColumnName || null;
  const inputStoreColumnName = input.storeColumnName || null;
  const inputTargetVariable = input.targetVariable || null;
  const inputPriceColumnName = input.priceColumnName || null;
  const inputHolidayColumnName = input.holidayColumnName || null;
  const inputPromotionColumnName = input.promotionColumnName || null;
  const inputOpenStatusColumnName = input.openStatusColumnName || null;
  const inputForecastHorizon = input.forecastHorizon || null;
  const inputFutureAssumptionsJson = input.futureAssumptionsJson || null;

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
  const skuColumnName = inputSkuColumnName || tenantDefaults?.skuColumnName || "";
  const storeColumnName = inputStoreColumnName || tenantDefaults?.storeColumnName || "";
  const targetVariable = inputTargetVariable || tenantDefaults?.targetVariable || "quantity";
  const priceColumnName = inputPriceColumnName || tenantDefaults?.priceColumnName || "price";
  const holidayColumnName = inputHolidayColumnName || tenantDefaults?.holidayColumnName || "";
  const promotionColumnName = inputPromotionColumnName || tenantDefaults?.promotionColumnName || "";
  const openStatusColumnName = inputOpenStatusColumnName || tenantDefaults?.openStatusColumnName || "";
  const forecastHorizon = normalizeRequestedHorizon(inputForecastHorizon || tenantDefaults?.forecastHorizon || 30, 30);

  let seriesMetadata = { seriesCount: null, skuColumnName: skuColumnName || null, storeColumnName: storeColumnName || null };
  const rawCsv = await readTextFromS3(s3Bucket, s3Key);
  const scopeValidation = validateSalesCsvScope(rawCsv, { dateFormat, skuColumnName, storeColumnName, plan });
  if (!scopeValidation.ok) {
    return {
      status: "error",
      message: scopeValidation.message,
      result: {
        code: scopeValidation.code,
        historySpanDays: scopeValidation.historySpanDays ?? null,
        maxSeriesPoints: scopeValidation.maxSeriesPoints ?? null,
        seriesCount: scopeValidation.seriesCount ?? null,
      },
    };
  }
  const targetValidation = inspectTargetColumnFromCsv(rawCsv, { targetVariable, skuColumnName, storeColumnName });
  if (!targetValidation.targetColumnName) {
    return {
      status: "error",
      message: `Selected target column ${targetVariable} was not found in the uploaded CSV.`,
      result: {
        code: "TARGET_COLUMN_NOT_FOUND",
        targetColumn: targetVariable,
      },
    };
  }
  if (targetValidation.invalidRowCount > 0) {
    return {
      status: "error",
      message: `${targetValidation.targetColumnName} contains ${targetValidation.invalidRowCount} invalid value(s). Fix the target column before starting forecasting.`,
      result: {
        code: "INVALID_TARGET_VALUES",
        targetColumn: targetValidation.targetColumnName,
        invalidRowCount: targetValidation.invalidRowCount,
        validRows: targetValidation.validRows,
        totalRows: targetValidation.totalRows,
        exampleInvalidRows: targetValidation.exampleInvalidRows,
      },
    };
  }
  if (mode === "local") {
    if (!FORECAST_LOCAL_RUNS_QUEUE_URL) {
      return { status: "error", message: "missing_local_runs_queue", result: {} };
    }
    if (!FORECAST_LOCAL_BATCH_QUEUE_URL) {
      return { status: "error", message: "missing_local_batch_queue", result: {} };
    }
    seriesMetadata = estimateSeriesCountFromCsv(rawCsv, { skuColumnName, storeColumnName });
    if (seriesMetadata.seriesCount > 100) {
      return {
        status: "error",
        message: `Local models support up to 100 SKU-location series per run. This file contains ${seriesMetadata.seriesCount}. Switch to global mode or reduce the dataset.`,
        result: {
          code: "LOCAL_MODEL_SERIES_LIMIT_EXCEEDED",
          seriesCount: seriesMetadata.seriesCount,
        },
      };
    }
  }

  await setTenantSettings(tenantId, {
    model,
    mode,
    seasonality,
    dateFormat,
    skuColumnName,
    storeColumnName,
    targetVariable,
    priceColumnName,
    holidayColumnName,
    promotionColumnName,
    openStatusColumnName,
    forecastHorizon,
  });

  const previousRun = await getLatestRun(tenantId);
  const snapshotId = randomId("SNAPSHOT-");
  const runId = randomId("RUN-");
  const createdAt = nowIso();
  const executionMode = mode === "local" ? "local_distributed" : "direct_lambda";

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
        parentRunId,
        isScenario: Boolean(adjustmentsKey),
        adjustmentsKey,
        scenarioLabel,
        editedAt: adjustmentsKey ? createdAt : null,
        editedCellCount,
        s3OutputPrefix,
        status: "QUEUED",
        executionMode,
        seriesCount: seriesMetadata.seriesCount,
        batchCount: mode === "local" ? 0 : null,
        completedBatchCount: mode === "local" ? 0 : null,
        failedBatchCount: mode === "local" ? 0 : null,
        createdAt,
        updatedAt: createdAt,
      }),
    })
  );

  const baseS3OutputPrefix = previousRun?.s3OutputPrefix || null;

  const payload = {
    invocationType: mode === "local" ? "local_dispatch" : "forecast_run",
    tenantId,
    runId,
    snapshotId,
    s3Bucket,
    s3Key,
    s3OutputPrefix,
    adjustmentsKey,
    parentRunId,
    scenarioLabel,
    editedCellCount,
    sku,
    store,
    frequency,
    model,
    mode,
    seasonality,
    dateFormat,
    skuColumnName,
    storeColumnName,
    targetVariable,
    priceColumnName,
    holidayColumnName,
    promotionColumnName,
    openStatusColumnName,
    forecastHorizon,
    futureAssumptionsJson: inputFutureAssumptionsJson,
    baseS3OutputPrefix,
    executionMode,
  };

  if (mode === "local") {
    await sqs.send(
      new SendMessageCommand({
        QueueUrl: FORECAST_LOCAL_RUNS_QUEUE_URL,
        MessageBody: JSON.stringify(payload),
      })
    );
  } else {
    await sqs.send(
      new SendMessageCommand({
        QueueUrl: FORECAST_GLOBAL_RUNS_QUEUE_URL,
        MessageBody: JSON.stringify(payload),
      })
    );
  }
  await updateRunStatus(tenantId, runId, mode === "local" ? "DISPATCHING" : "RUNNING");

  await upsertNotification({
    tenantId,
    runId,
    status: mode === "local" ? "DISPATCHING" : "RUNNING",
    createdAt,
    updatedAt: createdAt,
  });

  return {
    status: "queued",
    run: normalizeRun({
      runId,
      tenantId,
      snapshotId,
      parentRunId,
      isScenario: Boolean(adjustmentsKey),
      adjustmentsKey,
      scenarioLabel,
      editedAt: adjustmentsKey ? createdAt : null,
      editedCellCount,
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

const handleLocalDispatchMessage = async (message) => {
  const tenantId = message?.tenantId;
  const runId = message?.runId;
  const s3Bucket = message?.s3Bucket || RAW_BUCKET;
  const s3Key = message?.s3Key;
  const s3OutputPrefix = message?.s3OutputPrefix;
  if (!tenantId || !runId || !s3Bucket || !s3Key || !s3OutputPrefix) {
    throw new Error("invalid_local_dispatch_message");
  }
  if (!FORECAST_LOCAL_BATCH_QUEUE_URL) {
    throw new Error("missing_local_batch_queue");
  }

  const rawCsv = await readTextFromS3(s3Bucket, s3Key);
  const manifest = estimateSeriesCountFromCsv(rawCsv, {
    skuColumnName: message?.skuColumnName || "",
    storeColumnName: message?.storeColumnName || "",
  });
  const batchSize = resolveLocalBatchSize({
    configuredBatchSize: FORECAST_LOCAL_BATCH_SIZE,
    model: message?.model || "",
    seriesCount: manifest.seriesCount,
  });
  const seriesBatches = chunkArray(manifest.seriesKeys || [], batchSize);
  const manifestKey = `${s3OutputPrefix}/manifests/local_batch_manifest.json`;
  const manifestPayload = {
    tenantId,
    runId,
    generatedAt: nowIso(),
    totalSeries: manifest.seriesCount,
    batchSize,
    resolvedSkuColumnName: manifest.skuColumnName,
    resolvedStoreColumnName: manifest.storeColumnName,
    batches: seriesBatches.map((seriesKeys, index) => {
      const batchId = `batch-${String(index + 1).padStart(4, "0")}`;
      return {
        batchId,
        batchIndex: index + 1,
        seriesKeys,
        s3OutputPrefix: `${s3OutputPrefix}/batches/${batchId}`,
      };
    }),
  };

  await writeJsonToS3(ARTIFACT_BUCKET, manifestKey, manifestPayload);

  for (const batch of manifestPayload.batches) {
    await ddb.send(
      new PutItemCommand({
        TableName: FORECAST_RUNS_TABLE,
        Item: marshall({
          PK: `TENANT#${tenantId}`,
          SK: `BATCH#RUN#${runId}#${batch.batchId}`,
          tenantId,
          runId,
          batchId: batch.batchId,
          batchIndex: batch.batchIndex,
          status: "QUEUED",
          s3OutputPrefix: batch.s3OutputPrefix,
          createdAt: nowIso(),
          updatedAt: nowIso(),
        }),
      })
    );

    await sqs.send(
      new SendMessageCommand({
        QueueUrl: FORECAST_LOCAL_BATCH_QUEUE_URL,
        MessageBody: JSON.stringify({
          ...message,
          invocationType: "local_batch",
          manifestKey,
          batchId: batch.batchId,
          batchIndex: batch.batchIndex,
          batchCount: manifestPayload.batches.length,
          batchSeriesKeys: batch.seriesKeys,
          batchOutputPrefix: batch.s3OutputPrefix,
        }),
      })
    );
  }

  await ddb.send(
    new UpdateItemCommand({
      TableName: FORECAST_RUNS_TABLE,
      Key: marshall({
        PK: `TENANT#${tenantId}`,
        SK: `RUN#${runId}`,
      }),
      UpdateExpression: "SET #status = :status, executionMode = :executionMode, batchCount = :batchCount, completedBatchCount = :zero, failedBatchCount = :zero, manifestKey = :manifestKey, updatedAt = :updatedAt",
      ExpressionAttributeNames: { "#status": "status" },
      ExpressionAttributeValues: marshall({
        ":status": "RUNNING",
        ":executionMode": "local_distributed",
        ":batchCount": manifestPayload.batches.length,
        ":zero": 0,
        ":manifestKey": manifestKey,
        ":updatedAt": nowIso(),
      }),
    })
  );

  await updateNotificationStatus({
    tenantId,
    runId,
    status: "RUNNING",
    summary: { stage: "local_dispatch", batchCount: manifestPayload.batches.length, batchSize, seriesCount: manifest.seriesCount },
  });
};

const handleQueueRecords = async (event) => {
  const records = Array.isArray(event?.Records) ? event.Records : [];
  for (const record of records) {
    const body = typeof record?.body === "string" ? JSON.parse(record.body) : record?.body;
    const invocationType = body?.invocationType || body?.workType || "";
    if (invocationType === "local_dispatch") {
      await handleLocalDispatchMessage(body);
      continue;
    }
    throw new Error(`unsupported_queue_message:${invocationType}`);
  }
  return { status: "success" };
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

const listRecentRunsForAssistant = async (tenantId, limit = 10) => {
  if (!tenantId) return [];
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

  let items = (result.Items || []).map((item) => normalizeNotification(unmarshall(item)));

  // Fallback for legacy/partial rows missing GSI keys.
  if (!nextToken && items.length === 0) {
    const pkResult = await ddb.send(
      new QueryCommand({
        TableName: NOTIFICATIONS_TABLE,
        KeyConditionExpression: "PK = :pk AND begins_with(SK, :sk)",
        ExpressionAttributeValues: marshall({
          ":pk": `TENANT#${tenantId}`,
          ":sk": "RUN#",
        }),
        ScanIndexForward: false,
        Limit: limit,
      })
    );
    items = (pkResult.Items || [])
      .map((item) => normalizeNotification(unmarshall(item)))
      .sort((a, b) => String(b?.createdAt || "").localeCompare(String(a?.createdAt || "")));
  }

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
  const pageContext = buildPageContext(input);

  let run = null;
  if (runId) {
    run = await getRunById(tenantId, runId);
  }
  if (!run) {
    run = await getLatestRun(tenantId);
  }
  const recentRuns = await listRecentRunsForAssistant(tenantId, 10);

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
  let skuForecastValues = null;
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
    try {
      skuForecastValues = await readJsonFromS3(ARTIFACT_BUCKET, `${prefix}/sku_forecast_values.json`);
    } catch {
      skuForecastValues = null;
    }
  }

  const precomputedContext = buildContextPayload({
    run,
    summary,
    metadata,
    monthlyTotals,
    replenishmentSignals,
    skuForecastValues,
    tenantSettings,
    pageContext,
  });

  const cached = await getAssistantCachedResponse({ tenantId, runId: run?.runId || runId, command, context: precomputedContext });
  if (cached) {
    return cached;
  }

  const estimatedInputTokens = estimateTokens(command) + estimateTokens(JSON.stringify(precomputedContext)) + 180;
  if (tokensUsedBefore + estimatedInputTokens >= caps.tokensPerMonth) {
    return {
      ...defaultAssistantResponse(precomputedContext),
      status: "quota_exceeded",
      intent: "quota_exceeded",
      assistantText: `Insufficient token budget remaining for ${monthKey}. Estimated input tokens (${estimatedInputTokens}) exceed remaining allocation.`,
      checklist: ["Use a shorter prompt or retry next month.", "Increase tenant token limits in entitlements."],
      suggestedPrompts: [],
      steps: [],
    };
  }

  const generated = await generateForecastAssistantResponse({
    command,
    run,
    runId,
    tenantSettings,
    pageContext,
    summary,
    metadata,
    monthlyTotals,
    replenishmentSignals,
    skuForecastValues,
    recentRuns,
  });
  const response = generated.response;

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
    inputTokens: generated?.usage?.inputTokens || 0,
    outputTokens: generated?.usage?.outputTokens || 0,
  });

  await setAssistantCachedResponse({
    tenantId,
    runId: run?.runId || runId,
    command,
    context: generated.context,
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

const handleGetMergedSkuForecastValues = async (event) => {
  const tenantId = getTenantId(event);
  if (!tenantId) {
    return { status: "error", result: {} };
  }

  const requestedRunId =
    typeof event?.arguments?.runId === "string" && event.arguments.runId.trim()
      ? event.arguments.runId.trim()
      : null;
  if (requestedRunId) {
    return handleGetResultFile(event, "sku_forecast_values.json");
  }

  const key = `tenant-artifacts/${tenantId}/projection/sku_forecast_projection.json`;
  try {
    const data = await readJsonFromS3(ARTIFACT_BUCKET, key);
    return { status: "success", result: data };
  } catch {
    return handleGetResultFile(event, "sku_forecast_values.json");
  }
};

const handleGetForecastApprovals = async (event) => {
  const tenantId = getTenantId(event);
  if (!tenantId) {
    return { status: "error", result: {} };
  }
  const approvals = await getTenantForecastApprovals(tenantId);
  return { status: "success", result: approvals };
};

const handleSetForecastApproval = async (event) => {
  const tenantId = getTenantId(event);
  if (!tenantId) {
    return { status: "error", result: {} };
  }
  const input = event?.input?.input || event?.arguments?.input || {};
  const sku = typeof input.sku === "string" ? input.sku.trim() : "";
  const store = typeof input.store === "string" ? input.store.trim() : "";
  const approved = Boolean(input.approved);
  if (!sku) {
    return { status: "error", result: { message: "missing_sku" } };
  }
  const approvals = await setTenantForecastApproval(tenantId, { sku, store, approved });
  return { status: "success", result: approvals };
};

const dispatchField = async (fieldName, event) => {
  await assertTenantAccess(fieldName, event);

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
    case "getMergedSkuForecastValues":
      return handleGetMergedSkuForecastValues(event);
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
    case "getForecastApprovals":
      return handleGetForecastApprovals(event);
    case "setForecastApproval":
      return handleSetForecastApproval(event);
    case "forecastAssistant":
      return handleForecastAssistant(event);
    case "getAssistantUsage":
      return handleGetAssistantUsage(event);
    default:
      return { status: "error", message: "unknown_field", result: {} };
  }
};

module.exports = {
  handleQueueRecords,
  dispatchField,
  generateForecastAssistantResponse,
};
