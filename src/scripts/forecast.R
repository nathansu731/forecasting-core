source("/var/task/scripts/core/dependencies.R")
source("/var/task/scripts/core/constants.R")
source("/var/task/scripts/core/data_prep.R")
source("/var/task/scripts/core/modeling.R")
source("/var/task/scripts/core/validation.R")
source("/var/task/scripts/core/io_state.R")

run_forecast_pipeline <- function(event) {
  raw_bucket <- Sys.getenv("RAW_BUCKET")
  artifact_bucket <- Sys.getenv("ARTIFACT_BUCKET")
  forecast_runs_table <- Sys.getenv("FORECAST_RUNS_TABLE")
  data_snapshots_table <- Sys.getenv("DATA_SNAPSHOTS_TABLE")

  unwrap_value <- function(x) {
    if (is.null(x)) return(NULL)
    if (is.list(x)) {
      has_named_fields <- !is.null(names(x)) && any(names(x) != "")
      if (has_named_fields) return(x)
      if (length(x) == 1) return(x[[1]])
      return(x)
    }
    if (length(x) == 1) return(x[[1]])
    x
  }
  `%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x

  tenant_id <- unwrap_value(event$tenantId)
  run_id <- unwrap_value(event$runId)
  snapshot_id <- unwrap_value(event$snapshotId)
  s3_bucket <- unwrap_value(event$s3Bucket)
  s3_key <- unwrap_value(event$s3Key)
  s3_output_prefix <- unwrap_value(event$s3OutputPrefix)
  adjustments_key <- unwrap_value(event$adjustmentsKey)
  base_s3_output_prefix <- unwrap_value(event$baseS3OutputPrefix)
  selected_sku <- unwrap_value(event$sku)
  selected_store <- unwrap_value(event$store)
  selected_frequency <- unwrap_value(event$frequency)
  selected_model <- unwrap_value(event$model)
  selected_mode <- unwrap_value(event$mode)
  work_type <- unwrap_value(event$workType)
  selected_seasonality <- unwrap_value(event$seasonality)
  input_date_format <- unwrap_value(event$dateFormat)
  input_sku_column <- unwrap_value(event$skuColumnName)
  input_store_column <- unwrap_value(event$storeColumnName)
  input_target_variable <- unwrap_value(event$targetVariable)
  input_price_column <- unwrap_value(event$priceColumnName)
  input_holiday_column <- unwrap_value(event$holidayColumnName)
  input_promotion_column <- unwrap_value(event$promotionColumnName)
  input_open_status_column <- unwrap_value(event$openStatusColumnName)
  input_forecast_horizon <- suppressWarnings(as.integer(unwrap_value(event$forecastHorizon)))
  input_future_assumptions_json <- unwrap_value(event$futureAssumptionsJson)
  execution_mode <- unwrap_value(event$executionMode)
  manifest_key <- unwrap_value(event$manifestKey)
  batch_id <- unwrap_value(event$batchId)
  batch_index <- suppressWarnings(as.integer(unwrap_value(event$batchIndex)))
  batch_count <- suppressWarnings(as.integer(unwrap_value(event$batchCount)))
  batch_output_prefix <- unwrap_value(event$batchOutputPrefix)
  batch_series_keys <- unwrap_value(event$batchSeriesKeys)
  is_batch_run <- identical(unwrap_value(event$invocationType), "local_batch") || identical(work_type, "local_batch") || (!is.null(batch_id) && !is.null(batch_output_prefix))
  batch_series_keys <- if (is.null(batch_series_keys)) character(0) else as.character(unlist(batch_series_keys, use.names = FALSE))

  if (is.null(tenant_id) || is.null(run_id) || is.null(snapshot_id) || is.null(s3_bucket) || is.null(s3_key)) {
    return(list(status = "error", message = "missing_inputs"))
  }

  format_raw_future_assumptions_for_log <- function(raw_value) {
    if (is.null(raw_value)) return("NULL")
    if (is.character(raw_value) && length(raw_value) == 1) return(raw_value)
    tryCatch(
      toJSON(raw_value, auto_unbox = TRUE, null = "null"),
      error = function(e) "<unserializable>"
    )
  }

  log_forecast_event <- function(event_name, message_text = NULL, fields = list()) {
    base_fields <- list(
      event = event_name,
      message = message_text,
      runId = run_id,
      tenantId = tenant_id,
      snapshotId = snapshot_id,
      model = selected_model,
      mode = selected_mode,
      executionMode = execution_mode,
      artifactPrefix = s3_output_prefix,
      batchId = batch_id,
      batchIndex = batch_index
    )
    payload <- c(base_fields, fields)
    message(toJSON(payload, auto_unbox = TRUE, null = "null"))
  }

  message("Forecast run env: raw_bucket=", raw_bucket, " artifact_bucket=", artifact_bucket, " forecast_runs_table=", forecast_runs_table)
  message("Forecast run input: tenant_id=", tenant_id, " run_id=", run_id, " s3_bucket=", s3_bucket, " s3_key=", s3_key, " output_prefix=", s3_output_prefix, " adjustments_key=", adjustments_key, " model=", selected_model, " mode=", selected_mode)
  message("Forecast run future assumptions raw: ", format_raw_future_assumptions_for_log(input_future_assumptions_json))
  log_forecast_event(
    "forecast_run_start",
    "Starting forecast pipeline",
    list(
      s3Bucket = s3_bucket,
      s3Key = s3_key,
      adjustmentsKey = adjustments_key,
      artifactBucket = artifact_bucket,
      isBatchRun = is_batch_run
    )
  )

  resolve_horizon <- function(value, default_value) {
    if (is.null(value) || is.na(value)) return(default_value)
    h <- as.integer(value)
    if (is.na(h) || h <= 0) return(default_value)
    h <- max(1, min(365, h))
    h
  }

  parse_future_assumptions <- function(raw_value) {
    empty_future_assumptions <- function() {
      return(list(
        storeState = NULL,
        closedWeekdays = integer(0),
        holidayRanges = list(),
        promotionRanges = list()
      ))
    }

    normalize_scalar_string <- function(value) {
      flattened <- unlist(value, use.names = FALSE)
      if (length(flattened) == 0) return(NULL)
      scalar <- flattened[[1]]
      if (is.null(scalar) || (length(scalar) == 1 && is.na(scalar))) return(NULL)
      normalized <- trimws(as.character(scalar))
      if (identical(normalized, "")) return(NULL)
      normalized
    }

    if (is.null(raw_value)) {
      return(empty_future_assumptions())
    }
    if (is.character(raw_value) && length(raw_value) == 1 && identical(raw_value, "")) {
      return(empty_future_assumptions())
    }

    parsed <- tryCatch({
      if (is.character(raw_value)) {
        fromJSON(raw_value, simplifyVector = FALSE)
      } else {
        raw_value
      }
    }, error = function(e) NULL)

    if (is.null(parsed) || !is.list(parsed)) {
      return(empty_future_assumptions())
    }

    closed_weekdays <- suppressWarnings(as.integer(unlist(parsed$closedWeekdays, use.names = FALSE)))
    closed_weekdays <- closed_weekdays[!is.na(closed_weekdays) & closed_weekdays >= 1 & closed_weekdays <= 7]

    normalize_ranges <- function(ranges) {
      if (is.null(ranges) || length(ranges) == 0) return(list())
      normalized <- list()
      for (range in ranges) {
        start_date <- tryCatch(as.Date(range$startDate), error = function(e) NA)
        end_date <- tryCatch(as.Date(range$endDate), error = function(e) NA)
        if (is.na(start_date) || is.na(end_date)) next
        if (end_date < start_date) {
          swap <- start_date
          start_date <- end_date
          end_date <- swap
        }
        normalized[[length(normalized) + 1]] <- list(startDate = start_date, endDate = end_date)
      }
      normalized
    }

    list(
      storeState = normalize_scalar_string(parsed$storeState),
      closedWeekdays = sort(unique(closed_weekdays)),
      holidayRanges = normalize_ranges(parsed$holidayRanges),
      promotionRanges = normalize_ranges(parsed$promotionRanges)
    )
  }

  future_assumptions <- parse_future_assumptions(input_future_assumptions_json)
  message(
    "Forecast run future assumptions parsed: storeState=",
    ifelse(is.null(future_assumptions$storeState), "", future_assumptions$storeState),
    " closedWeekdays=",
    paste(future_assumptions$closedWeekdays, collapse = ","),
    " holidayRanges=",
    length(future_assumptions$holidayRanges),
    " promotionRanges=",
    length(future_assumptions$promotionRanges)
  )
  log_forecast_event(
    "forecast_future_assumptions",
    "Parsed future assumptions",
    list(
      storeState = future_assumptions$storeState,
      closedWeekdays = future_assumptions$closedWeekdays,
      holidayRangeCount = length(future_assumptions$holidayRanges),
      promotionRangeCount = length(future_assumptions$promotionRanges)
    )
  )

  s3 <- paws.storage::s3()
  ddb <- NULL
  if (requireNamespace("paws.database", quietly = TRUE)) {
    ddb <- paws.database::dynamodb()
  } else {
    message("paws.database package not available; run status updates will be skipped")
  }

  ddb_get_string <- function(item, key) {
    if (is.null(item[[key]]) || is.null(item[[key]]$S)) return(NULL)
    as.character(item[[key]]$S)
  }

  assert_runtime_context <- function() {
    if (is.null(ddb)) {
      stop("missing_paws_database")
    }
    if (is.null(forecast_runs_table) || forecast_runs_table == "") {
      stop("missing_forecast_runs_table")
    }
    if (is.null(data_snapshots_table) || data_snapshots_table == "") {
      stop("missing_data_snapshots_table")
    }

    run_item <- ddb$get_item(
      TableName = forecast_runs_table,
      Key = list(
        PK = list(S = paste0("TENANT#", tenant_id)),
        SK = list(S = paste0("RUN#", run_id))
      )
    )$Item
    if (is.null(run_item)) {
      stop("run_not_found")
    }

    expected_snapshot_id <- ddb_get_string(run_item, "snapshotId")
    if (!is.null(expected_snapshot_id) && expected_snapshot_id != snapshot_id) {
      stop("snapshot_mismatch")
    }

    expected_output_prefix <- ddb_get_string(run_item, "s3OutputPrefix")
    if (!is.null(expected_output_prefix) && !is.null(s3_output_prefix) && expected_output_prefix != s3_output_prefix) {
      stop("output_prefix_mismatch")
    }

    snapshot_item <- ddb$get_item(
      TableName = data_snapshots_table,
      Key = list(
        PK = list(S = paste0("TENANT#", tenant_id)),
        SK = list(S = paste0("SNAPSHOT#", snapshot_id))
      )
    )$Item
    if (is.null(snapshot_item)) {
      stop("snapshot_not_found")
    }

    expected_bucket <- ddb_get_string(snapshot_item, "s3Bucket")
    expected_key <- ddb_get_string(snapshot_item, "s3Key")
    if (!is.null(expected_bucket) && expected_bucket != s3_bucket) {
      stop("snapshot_bucket_mismatch")
    }
    if (!is.null(expected_key) && expected_key != s3_key) {
      stop("snapshot_key_mismatch")
    }

    if (is_batch_run && !is.null(batch_id) && batch_id != "") {
      batch_item <- ddb$get_item(
        TableName = forecast_runs_table,
        Key = list(
          PK = list(S = paste0("TENANT#", tenant_id)),
          SK = list(S = paste0("BATCH#RUN#", run_id, "#", batch_id))
        )
      )$Item
      if (is.null(batch_item)) {
        stop("batch_not_found")
      }

      expected_batch_prefix <- ddb_get_string(batch_item, "s3OutputPrefix")
      if (!is.null(expected_batch_prefix) && !is.null(batch_output_prefix) && expected_batch_prefix != batch_output_prefix) {
        stop("batch_output_prefix_mismatch")
      }
    }

    log_forecast_event(
      "forecast_runtime_context_verified",
      "Validated forecast runtime context against DynamoDB",
      list(
        forecastRunsTable = forecast_runs_table,
        dataSnapshotsTable = data_snapshots_table
      )
    )
  }

  assert_runtime_context()

  read_json_from_s3 <- function(bucket, key) {
    obj <- s3$get_object(Bucket = bucket, Key = key)
    raw_text <- rawToChar(obj$Body)
    fromJSON(raw_text, simplifyVector = FALSE)
  }

  write_json <- function(key, payload) {
    artifact_name <- basename(key)
    log_forecast_event(
      "artifact_write_started",
      "Writing artifact",
      list(artifact = artifact_name, artifactKey = key)
    )
    message("Writing artifact to s3://", artifact_bucket, "/", key)
    tryCatch({
      payload_json <- toJSON(payload, auto_unbox = TRUE)
      payload_raw <- charToRaw(enc2utf8(payload_json))
      s3$put_object(
        Bucket = artifact_bucket,
        Key = key,
        Body = payload_raw,
        ContentType = "application/json"
      )
      message("Wrote artifact: ", key)
      log_forecast_event(
        "artifact_write_succeeded",
        "Artifact write completed",
        list(artifact = artifact_name, artifactKey = key)
      )
    }, error = function(e) {
      message("Failed writing artifact ", key, ": ", e$message)
      log_forecast_event(
        "artifact_write_failed",
        "Artifact write failed",
        list(artifact = artifact_name, artifactKey = key, error = as.character(e$message))
      )
      stop(e)
    })
  }

  ddb_get_number <- function(item, key, default_value = 0) {
    if (is.null(item[[key]]$N)) return(default_value)
    parsed <- suppressWarnings(as.numeric(item[[key]]$N))
    if (is.na(parsed)) default_value else parsed
  }

  update_batch_item_status <- function(status, error_message = NULL) {
    if (is.null(ddb) || is.null(forecast_runs_table) || forecast_runs_table == "" || is.null(batch_id) || batch_id == "") return(invisible(NULL))
    expr_values <- list(
      ":status" = list(S = status),
      ":updatedAt" = list(S = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ"))
    )
    update_expr <- "SET #status = :status, updatedAt = :updatedAt"
    if (!is.null(batch_output_prefix) && batch_output_prefix != "") {
      expr_values[[":prefix"]] <- list(S = batch_output_prefix)
      update_expr <- paste0(update_expr, ", s3OutputPrefix = :prefix")
    }
    if (!is.null(error_message) && error_message != "") {
      expr_values[[":errorMessage"]] <- list(S = error_message)
      update_expr <- paste0(update_expr, ", errorMessage = :errorMessage")
    }
    ddb$update_item(
      TableName = forecast_runs_table,
      Key = list(
        PK = list(S = paste0("TENANT#", tenant_id)),
        SK = list(S = paste0("BATCH#RUN#", run_id, "#", batch_id))
      ),
      UpdateExpression = update_expr,
      ExpressionAttributeNames = list("#status" = "status"),
      ExpressionAttributeValues = expr_values
    )
  }

  increment_run_batch_counter <- function(counter_name) {
    if (is.null(ddb) || is.null(forecast_runs_table) || forecast_runs_table == "") return(NULL)
    ddb$update_item(
      TableName = forecast_runs_table,
      Key = list(
        PK = list(S = paste0("TENANT#", tenant_id)),
        SK = list(S = paste0("RUN#", run_id))
      ),
      UpdateExpression = paste0("ADD ", counter_name, " :inc SET updatedAt = :updatedAt"),
      ExpressionAttributeValues = list(
        ":inc" = list(N = "1"),
        ":updatedAt" = list(S = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ"))
      ),
      ReturnValues = "ALL_NEW"
    )
  }

  try_claim_aggregation <- function() {
    if (is.null(ddb) || is.null(forecast_runs_table) || forecast_runs_table == "") return(FALSE)
    tryCatch({
      ddb$update_item(
        TableName = forecast_runs_table,
        Key = list(
          PK = list(S = paste0("TENANT#", tenant_id)),
          SK = list(S = paste0("RUN#", run_id))
        ),
        UpdateExpression = "SET aggregationStartedAt = :startedAt, updatedAt = :updatedAt",
        ConditionExpression = "attribute_not_exists(aggregationStartedAt)",
        ExpressionAttributeValues = list(
          ":startedAt" = list(S = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ")),
          ":updatedAt" = list(S = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ"))
        )
      )
      TRUE
    }, error = function(e) FALSE)
  }

  aggregate_named_metric_maps <- function(metric_maps) {
    month_keys <- unique(unlist(lapply(metric_maps, names), use.names = FALSE))
    month_keys <- month_keys[month_keys != "average"]
    month_keys <- sort(unique(month_keys))
    sums <- setNames(rep(0, length(month_keys)), month_keys)
    for (metric_map in metric_maps) {
      if (is.null(metric_map)) next
      for (key in month_keys) {
        value <- suppressWarnings(as.numeric(metric_map[[key]]))
        if (!is.na(value)) sums[[key]] <- sums[[key]] + value
      }
    }
    result <- as.list(round(as.numeric(sums), 2))
    names(result) <- month_keys
    result$average <- if (length(month_keys) > 0) round(mean(as.numeric(sums)), 2) else 0
    result
  }

  aggregate_batch_outputs <- function() {
    if (is.null(manifest_key) || manifest_key == "") stop("Missing manifestKey for batch aggregation")
    manifest <- read_json_from_s3(artifact_bucket, manifest_key)
    batches <- manifest$batches
    if (is.null(batches) || length(batches) == 0) stop("Missing batch manifest entries")

    merged_daily <- list()
    merged_meta <- list()
    merged_sku_items <- list()
    merged_replenishment <- list()
    summary_list <- list()
    monthly_forecast_parts <- list()
    monthly_totals_parts <- list()

    for (batch in batches) {
      prefix <- batch$s3OutputPrefix
      daily_payload <- read_json_from_s3(artifact_bucket, paste0(prefix, "/daily_forecasts.json"))
      metadata_payload <- read_json_from_s3(artifact_bucket, paste0(prefix, "/metadata.json"))
      monthly_forecasts_payload <- read_json_from_s3(artifact_bucket, paste0(prefix, "/monthly_forecasts.json"))
      monthly_totals_payload <- read_json_from_s3(artifact_bucket, paste0(prefix, "/monthly_totals.json"))
      report_summary_payload <- read_json_from_s3(artifact_bucket, paste0(prefix, "/report_summary.json"))
      sku_values_payload <- read_json_from_s3(artifact_bucket, paste0(prefix, "/sku_forecast_values.json"))
      replenishment_payload <- read_json_from_s3(artifact_bucket, paste0(prefix, "/replenishment_signals.json"))

      merged_daily[[length(merged_daily) + 1]] <- as.data.frame(daily_payload, stringsAsFactors = FALSE)
      for (meta_name in names(metadata_payload)) merged_meta[[meta_name]] <- metadata_payload[[meta_name]]
      if (!is.null(sku_values_payload$items)) merged_sku_items <- c(merged_sku_items, sku_values_payload$items)
      if (!is.null(replenishment_payload$items)) merged_replenishment <- c(merged_replenishment, replenishment_payload$items)
      summary_list[[length(summary_list) + 1]] <- report_summary_payload
      monthly_forecast_parts[[length(monthly_forecast_parts) + 1]] <- monthly_forecasts_payload
      monthly_totals_parts[[length(monthly_totals_parts) + 1]] <- monthly_totals_payload
    }

    daily_forecasts_df <- do.call(rbind, merged_daily)
    forecast_frequency <- if (length(summary_list) > 0 && !is.null(summary_list[[1]]$validation$frequency)) summary_list[[1]]$validation$frequency else "daily"

    monthly_forecasts <- list(
      budget = aggregate_named_metric_maps(lapply(monthly_forecast_parts, function(part) part$budget)),
      demand = aggregate_named_metric_maps(lapply(monthly_forecast_parts, function(part) part$demand)),
      demandAdjustment = aggregate_named_metric_maps(lapply(monthly_forecast_parts, function(part) part$demandAdjustment)),
      forecastBaseline = aggregate_named_metric_maps(lapply(monthly_forecast_parts, function(part) part$forecastBaseline)),
      forecastAdjustment = aggregate_named_metric_maps(lapply(monthly_forecast_parts, function(part) part$forecastAdjustment)),
      previousForecasts = aggregate_named_metric_maps(lapply(monthly_forecast_parts, function(part) part$previousForecasts)),
      variance = aggregate_named_metric_maps(lapply(monthly_forecast_parts, function(part) part$variance)),
      revenue = aggregate_named_metric_maps(lapply(monthly_forecast_parts, function(part) part$revenue))
    )

    growth_values <- unlist(monthly_forecasts$revenue[names(monthly_forecasts$revenue) != "average"], use.names = FALSE)
    growth_rate <- 0
    if (length(growth_values) >= 2) {
      non_zero <- tail(growth_values, 2)
      prev <- non_zero[[1]]
      last <- non_zero[[2]]
      if (!is.na(prev) && prev != 0) growth_rate <- (last - prev) / prev
    }

    total_revenue_value <- sum(vapply(monthly_totals_parts, function(part) suppressWarnings(as.numeric(part$totalRevenue$value %||% 0)), numeric(1)), na.rm = TRUE)
    stockout_risk_value <- sum(vapply(monthly_totals_parts, function(part) suppressWarnings(as.numeric(part$stockoutRiskSkus$value %||% 0)), numeric(1)), na.rm = TRUE)
    forecast_accuracy_parts <- vapply(monthly_totals_parts, function(part) suppressWarnings(as.numeric(part$forecastAccuracy$value %||% NA_real_)), numeric(1))
    forecast_accuracy_value <- round(mean(forecast_accuracy_parts[!is.na(forecast_accuracy_parts)]), 2)
    if (is.na(forecast_accuracy_value)) forecast_accuracy_value <- 0

    monthly_totals <- list(
      totalRevenue = list(value = round(total_revenue_value, 2), variance = round(growth_rate, 3), status = calc_status(growth_rate)),
      stockoutRiskSkus = list(value = round(stockout_risk_value, 2), variance = 0, status = calc_status(0)),
      forecastAccuracy = list(value = forecast_accuracy_value, variance = 0, status = calc_status(0)),
      growthRate = list(value = round(growth_rate * 100, 2), variance = round(growth_rate, 3), status = calc_status(growth_rate))
    )

      summary <- list(
        totalSkus = sum(vapply(summary_list, function(part) suppressWarnings(as.numeric(part$totalSkus %||% 0)), numeric(1)), na.rm = TRUE),
        totalSeries = sum(vapply(summary_list, function(part) suppressWarnings(as.numeric(part$totalSeries %||% 0)), numeric(1)), na.rm = TRUE),
        rows = sum(vapply(summary_list, function(part) suppressWarnings(as.numeric(part$rows %||% 0)), numeric(1)), na.rm = TRUE),
        dateStart = min(vapply(summary_list, function(part) as.character(part$dateStart %||% "9999-12-31"), character(1))),
        dateEnd = max(vapply(summary_list, function(part) as.character(part$dateEnd %||% "0000-01-01"), character(1))),
        runConfig = if (length(summary_list) > 0) summary_list[[1]]$runConfig else NULL,
        futureAssumptionsDiagnostics = if (length(summary_list) > 0) summary_list[[1]]$futureAssumptionsDiagnostics else NULL,
        validation = if (length(summary_list) > 0) summary_list[[1]]$validation else list(frequency = forecast_frequency)
      )

    sku_forecast_values <- list(frequency = forecast_frequency, items = merged_sku_items)
    projection_generated_at <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ")
    sku_forecast_projection <- list(
      frequency = forecast_frequency,
      generatedAt = projection_generated_at,
      projectionVersion = paste0(run_id, "-", gsub("[^0-9]", "", projection_generated_at)),
      updatedByRunId = run_id,
      itemCount = length(merged_sku_items),
      items = merged_sku_items
    )
    replenishment_signals <- list(
      generatedAt = projection_generated_at,
      horizonDays = if (length(summary_list) > 0) suppressWarnings(as.integer(summary_list[[1]]$validation$selectedModel$horizon %||% 30)) else 30,
      items = merged_replenishment
    )

    projection_key <- paste0("tenant-artifacts/", tenant_id, "/projection/sku_forecast_projection.json")
    write_json(paste0(s3_output_prefix, "/daily_forecasts.json"), daily_forecasts_df)
    write_json(paste0(s3_output_prefix, "/metadata.json"), merged_meta)
    write_json(paste0(s3_output_prefix, "/monthly_forecasts.json"), monthly_forecasts)
    write_json(paste0(s3_output_prefix, "/monthly_totals.json"), monthly_totals)
    write_json(paste0(s3_output_prefix, "/report_summary.json"), summary)
    write_json(paste0(s3_output_prefix, "/sku_forecast_values.json"), sku_forecast_values)
    write_json(projection_key, sku_forecast_projection)
    write_json(paste0(s3_output_prefix, "/replenishment_signals.json"), replenishment_signals)
    summary
  }

  update_run_status(ddb, forecast_runs_table, tenant_id, run_id, "RUNNING")

  tryCatch({
    obj <- s3$get_object(Bucket = s3_bucket, Key = s3_key)
    raw_text <- rawToChar(obj$Body)

    adjustment_payload <- tryCatch({
      fromJSON(raw_text, simplifyVector = FALSE)
    }, error = function(e) NULL)

    if (!is.null(adjustment_payload$type) && adjustment_payload$type == "forecast_adjustments") {
      if (is.null(base_s3_output_prefix) || base_s3_output_prefix == "") {
        stop("Missing baseS3OutputPrefix for adjustments")
      }
      base_values <- read_json_from_s3(artifact_bucket, paste0(base_s3_output_prefix, "/sku_forecast_values.json"))
      if (is.null(base_values$items)) {
        stop("Missing base sku_forecast_values.json")
      }

      target_sku <- adjustment_payload$sku
      target_store <- adjustment_payload$store
      adjustments <- adjustment_payload$adjustments

      for (i in seq_along(base_values$items)) {
        item <- base_values$items[[i]]
        if (!is.null(item$sku) && !is.null(item$store) && item$sku == target_sku && item$store == target_store) {
          if (is.null(item$originalDemand)) item$originalDemand <- item$demand
          if (is.null(item$originalForecastBaseline)) item$originalForecastBaseline <- item$forecastBaseline
          if (!is.null(adjustments$demandAdjustment)) item$demandAdjustment <- adjustments$demandAdjustment
          if (!is.null(adjustments$forecastAdjustment)) item$forecastAdjustment <- adjustments$forecastAdjustment
          base_values$items[[i]] <- item
        }
      }

      write_json(paste0(s3_output_prefix, "/sku_forecast_values.json"), base_values)

      base_files <- c("daily_forecasts.json", "monthly_forecasts.json", "monthly_totals.json", "metadata.json", "report_summary.json", "replenishment_signals.json")
      for (file in base_files) {
        tryCatch({
          payload <- read_json_from_s3(artifact_bucket, paste0(base_s3_output_prefix, "/", file))
          write_json(paste0(s3_output_prefix, "/", file), payload)
        }, error = function(e) {
          message("Skipping base artifact copy: ", file, " error: ", e$message)
        })
      }

      update_run_status(ddb, forecast_runs_table, tenant_id, run_id, "DONE", s3_output_prefix, adjustment_payload)
      return(list(status = "success", result = list(message = "adjustments_applied")))
    }

    make_series_key <- function(sku_value, store_value) {
      paste0(as.character(sku_value), "::", as.character(store_value))
    }

    previous_forecast_by_series <- list()
    if (!is.null(base_s3_output_prefix) && base_s3_output_prefix != "") {
      previous_values <- tryCatch({
        read_json_from_s3(artifact_bucket, paste0(base_s3_output_prefix, "/sku_forecast_values.json"))
      }, error = function(e) NULL)

      if (!is.null(previous_values$items) && length(previous_values$items) > 0) {
        for (item in previous_values$items) {
          if (!is.null(item$sku) && !is.null(item$store) && !is.null(item$forecastBaseline)) {
            previous_forecast_by_series[[make_series_key(item$sku, item$store)]] <- item$forecastBaseline
          }
        }
      }
    }

    df <- read.csv(text = raw_text, stringsAsFactors = FALSE)
    df <- normalize_columns(df)

    requested_target <- tolower(trimws(ifelse(is.null(input_target_variable) || input_target_variable == "", "quantity", as.character(input_target_variable))))
    requested_price <- tolower(trimws(ifelse(is.null(input_price_column) || input_price_column == "", "price", as.character(input_price_column))))
    requested_holiday <- trimws(ifelse(is.null(input_holiday_column), "", as.character(input_holiday_column)))
    requested_promotion <- trimws(ifelse(is.null(input_promotion_column), "", as.character(input_promotion_column)))
    requested_open_status <- trimws(ifelse(is.null(input_open_status_column), "", as.character(input_open_status_column)))
    key_map <- setNames(names(df), vapply(names(df), normalize_column_key, character(1)))
    resolve_mapped_column <- function(requested_name, fallback_candidates = character()) {
      requested_key <- normalize_column_key(requested_name)
      if (!is.null(requested_name) && requested_name != "" && requested_key %in% names(key_map)) {
        return(key_map[[requested_key]])
      }
      for (candidate in fallback_candidates) {
        candidate_key <- normalize_column_key(candidate)
        if (candidate_key %in% names(key_map)) {
          return(key_map[[candidate_key]])
        }
      }
      NULL
    }
    target_key <- normalize_column_key(requested_target)
    price_key <- normalize_column_key(requested_price)
    target_column <- if (target_key %in% names(key_map)) key_map[[target_key]] else NULL
    price_column <- if (price_key %in% names(key_map)) key_map[[price_key]] else NULL
    holiday_column <- resolve_mapped_column(requested_holiday, c("isholiday", "holiday", "holidayflag", "is_holiday"))
    promotion_column <- resolve_mapped_column(requested_promotion, c("promotion", "promo", "promotionflag", "is_promotion"))
    open_status_column <- resolve_mapped_column(requested_open_status, c("isshopopened", "isstoreopen", "isopen", "storeopen", "shopopen", "openflag"))
    if (is.null(target_column)) target_column <- requested_target
    if (is.null(price_column)) price_column <- requested_price
    selected_date_format <- ifelse(is.null(input_date_format) || input_date_format == "", "dd/mm/yyyy", as.character(input_date_format))

    required_cols <- c("date", target_column)
    missing_cols <- setdiff(required_cols, names(df))
    if (length(missing_cols) > 0) {
      if (length(missing_cols) == 1) {
        stop(paste0(missing_cols[[1]], " column does not exist"))
      }
      stop(paste0("Missing required columns: ", paste(missing_cols, collapse = ", ")))
    }

    if (!(price_column %in% names(df))) {
      message("Price column not found (", price_column, "). Using default unit price = 1.")
      df[[price_column]] <- 1
    }

    requested_sku_column <- trimws(ifelse(is.null(input_sku_column), "", as.character(input_sku_column)))
    requested_store_column <- trimws(ifelse(is.null(input_store_column), "", as.character(input_store_column)))
    sku_column <- resolve_mapped_column(requested_sku_column, c("sku", "sku_id", "skuid", "product", "productid", "product_id", "item", "itemid", "item_id"))
    if (is.null(sku_column)) {
      sku_column <- resolve_column(df, c("sku", "sku_id", "skuid", "product", "productid", "product_id", "item", "itemid", "item_id"))
    }
    if (!is.null(sku_column) && sku_column != "sku" && !("sku" %in% names(df))) {
      message("SKU column mapped from ", sku_column, ".")
      df$sku <- df[[sku_column]]
    }
    location_column <- resolve_mapped_column(requested_store_column, c("location", "store", "storeid", "store_id", "storename", "store_name", "shop", "shopid", "shop_id", "outlet", "outletid", "outlet_id", "branch", "branchid", "branch_id"))
    if (is.null(location_column)) {
      location_column <- resolve_column(df, c("location", "store", "storeid", "store_id", "storename", "store_name", "shop", "shopid", "shop_id", "outlet", "outletid", "outlet_id", "branch", "branchid", "branch_id"))
    }
    if (!is.null(location_column) && location_column != "location" && !("location" %in% names(df))) {
      message("Location column mapped from ", location_column, ".")
      df$location <- df[[location_column]]
    }
    aisle_column <- resolve_column(df, c("aisle", "isle", "department", "category"))
    if (!is.null(aisle_column) && aisle_column != "aisle" && !("aisle" %in% names(df))) {
      message("Aisle column mapped from ", aisle_column, ".")
      df$aisle <- df[[aisle_column]]
    }

    if (!("sku" %in% names(df))) {
      message("SKU column not found. Using default SKU-1 for all rows.")
      df$sku <- "SKU-1"
    }
    if (!("location" %in% names(df))) {
      message("Location column not found. Using default location-1 for all rows.")
      df$location <- "location-1"
    }
    if (!("aisle" %in% names(df))) {
      message("Aisle column not found. Using default aisle-1 for all rows.")
      df$aisle <- "aisle-1"
    }
    df$sku <- trimws(as.character(df$sku))
    df$location <- trimws(as.character(df$location))
    df$aisle <- trimws(as.character(df$aisle))
    df$sku[df$sku == "" | is.na(df$sku)] <- "SKU-1"
    df$location[df$location == "" | is.na(df$location)] <- "location-1"
    df$aisle[df$aisle == "" | is.na(df$aisle)] <- "aisle-1"
    df$series_key <- make_series_key(df$sku, df$location)

    df$date <- parse_dates_by_format(df$date, selected_date_format)
    df$quantity <- suppressWarnings(as.numeric(df[[target_column]]))
    df$price <- suppressWarnings(as.numeric(df[[price_column]]))
    if (is.null(holiday_column)) {
      message("Holiday feature column not found. Using default 0 (FALSE) for all rows.")
      df$reg_holiday <- 0
    } else {
      df$reg_holiday <- safe_bool(df[[holiday_column]])
    }
    if (is.null(promotion_column)) {
      message("Promotion feature column not found. Using default 0 (FALSE) for all rows.")
      df$reg_promotion <- 0
    } else {
      df$reg_promotion <- safe_bool(df[[promotion_column]])
    }
    if (is.null(open_status_column)) {
      message("Open-status feature column not found. Using default 1 (TRUE) for all rows.")
      df$reg_is_open <- 1
    } else {
      df$reg_is_open <- safe_bool(df[[open_status_column]])
    }
    df$revenue <- df$quantity * df$price

    df <- df[!is.na(df$date) & !is.na(df$sku), ]

    target_cleanup <- list(
      rawRows = nrow(df),
      droppedNonFiniteTargetRows = sum(!is.finite(df$quantity), na.rm = TRUE),
      retainedFiniteTargetRows = sum(is.finite(df$quantity), na.rm = TRUE),
      droppedAggregatedNonFiniteRows = 0,
      droppedSeriesWithNonFiniteHistory = 0,
      droppedSeriesKeys = character(0)
    )

    onhand_col <- resolve_column(df, c("onhand", "on_hand", "currentstock", "current_stock", "stockonhand", "stock_on_hand", "stock"))
    lead_time_col <- resolve_column(df, c("leadtimedays", "lead_time_days", "leadtime", "lead_time", "supplierleaddays", "supplier_lead_days"))
    safety_stock_col <- resolve_column(df, c("safetystockdays", "safety_stock_days", "safetydays", "safety_days"))
    reorder_point_col <- resolve_column(df, c("reorderpoint", "reorder_point", "minstock", "min_stock"))

    if (!is.null(onhand_col)) df[[onhand_col]] <- suppressWarnings(as.numeric(df[[onhand_col]]))
    if (!is.null(lead_time_col)) df[[lead_time_col]] <- suppressWarnings(as.numeric(df[[lead_time_col]]))
    if (!is.null(safety_stock_col)) df[[safety_stock_col]] <- suppressWarnings(as.numeric(df[[safety_stock_col]]))
    if (!is.null(reorder_point_col)) df[[reorder_point_col]] <- suppressWarnings(as.numeric(df[[reorder_point_col]]))

    if (!is.null(selected_sku) && selected_sku != "") {
      df <- df[df$sku == selected_sku, ]
    }
    if (!is.null(selected_store) && selected_store != "") {
      df <- df[df$location == selected_store, ]
    }
    if (is_batch_run && length(batch_series_keys) > 0) {
      df <- df[df$series_key %in% batch_series_keys, ]
    }
    historical_df <- df[is.finite(df$quantity), ]

    extract_latest_value <- function(sku_df, column_name) {
      if (is.null(column_name) || !(column_name %in% names(sku_df))) return(NA_real_)
      values <- suppressWarnings(as.numeric(sku_df[[column_name]]))
      idx <- which(!is.na(values))
      if (length(idx) == 0) return(NA_real_)
      ordered <- idx[order(sku_df$date[idx], decreasing = TRUE)]
      as.numeric(values[ordered[1]])
    }

    build_calendar_regressors <- function(dates, frequency) {
      dates <- as.Date(dates)
      if (length(dates) == 0) return(data.frame())

      base <- data.frame(trend = seq_along(dates))
      build_dummy_frame <- function(values, prefix) {
        dummy_matrix <- model.matrix(~ values)
        if (ncol(dummy_matrix) <= 1) return(data.frame())
        dummy_df <- as.data.frame(dummy_matrix[, -1, drop = FALSE])
        colnames(dummy_df) <- paste0(prefix, "_", seq_len(ncol(dummy_df)))
        dummy_df
      }

      if (frequency == "daily") {
        weekday <- factor(as.integer(format(dates, "%u")), levels = 1:7)
        weekday_df <- build_dummy_frame(weekday, "dow")
        return(cbind(base, weekday_df))
      }

      if (frequency %in% c("weekly", "monthly")) {
        month <- factor(as.integer(format(dates, "%m")), levels = 1:12)
        month_df <- build_dummy_frame(month, "month")
        return(cbind(base, month_df))
      }

      if (frequency == "quarterly") {
        quarter <- factor(((as.integer(format(dates, "%m")) - 1) %/% 3) + 1, levels = 1:4)
        quarter_df <- build_dummy_frame(quarter, "quarter")
        return(cbind(base, quarter_df))
      }

      base
    }

    build_regression_design <- function(sku_df_raw, history_dates, future_dates, frequency, use_future_assumptions = TRUE) {
      history_dates <- as.Date(history_dates)
      future_dates <- as.Date(future_dates)
      combined_dates <- c(history_dates, future_dates)
      if (length(combined_dates) == 0) return(list(history = NULL, future = NULL, combined = NULL))

      design_index <- data.frame(
        date = combined_dates,
        period = sapply(combined_dates, period_key, frequency = frequency),
        row_id = seq_along(combined_dates),
        is_history = c(rep(TRUE, length(history_dates)), rep(FALSE, length(future_dates)))
      )

      feature_source <- sku_df_raw[!is.na(sku_df_raw$date), c("date", "price", "reg_holiday", "reg_promotion", "reg_is_open")]
      if (nrow(feature_source) == 0) {
        feature_source <- data.frame(date = as.Date(character(0)), price = numeric(0), reg_holiday = numeric(0), reg_promotion = numeric(0), reg_is_open = numeric(0))
      }

      if (frequency == "daily") {
        feature_price <- aggregate(price ~ date, data = feature_source, function(values) {
          values <- suppressWarnings(as.numeric(values))
          values <- values[!is.na(values)]
          if (length(values) == 0) return(NA_real_)
          tail(values, 1)
        })
        feature_holiday <- aggregate(reg_holiday ~ date, data = feature_source, function(values) max(as.numeric(values), na.rm = TRUE))
        feature_promotion <- aggregate(reg_promotion ~ date, data = feature_source, function(values) max(as.numeric(values), na.rm = TRUE))
        feature_open <- aggregate(reg_is_open ~ date, data = feature_source, function(values) mean(as.numeric(values), na.rm = TRUE))
        feature_frame <- Reduce(function(left, right) merge(left, right, by = "date", all = TRUE), list(feature_price, feature_holiday, feature_promotion, feature_open))
        merged <- merge(design_index, feature_frame, by = "date", all.x = TRUE, sort = FALSE)
      } else {
        feature_source$period <- sapply(feature_source$date, period_key, frequency = frequency)
        price_period <- aggregate(price ~ period, data = feature_source, function(values) {
          values <- suppressWarnings(as.numeric(values))
          values <- values[!is.na(values)]
          if (length(values) == 0) return(NA_real_)
          tail(values, 1)
        })
        holiday_period <- aggregate(reg_holiday ~ period, data = feature_source, function(values) max(as.numeric(values), na.rm = TRUE))
        promotion_period <- aggregate(reg_promotion ~ period, data = feature_source, function(values) max(as.numeric(values), na.rm = TRUE))
        open_period <- aggregate(reg_is_open ~ period, data = feature_source, function(values) mean(as.numeric(values), na.rm = TRUE))
        feature_frame <- Reduce(function(left, right) merge(left, right, by = "period", all = TRUE), list(price_period, holiday_period, promotion_period, open_period))
        merged <- merge(design_index, feature_frame, by = "period", all.x = TRUE, sort = FALSE)
      }
      merged <- merged[order(merged$row_id), ]
      merged$date <- as.Date(merged$date)

      hist_prices <- suppressWarnings(as.numeric(merged$price[merged$is_history]))
      hist_prices <- hist_prices[!is.na(hist_prices)]
      default_price <- if (length(hist_prices) > 0) tail(hist_prices, 1) else 1
      merged$price[is.na(merged$price)] <- default_price

      merged$reg_holiday[is.na(merged$reg_holiday)] <- 0
      merged$reg_promotion[is.na(merged$reg_promotion)] <- 0

      history_open <- suppressWarnings(as.numeric(merged$reg_is_open[merged$is_history]))
      weekday_ids <- as.integer(format(merged$date, "%u"))
      weekday_default_open <- rep(1, 7)
      if (length(history_dates) > 0) {
        hist_weekdays <- weekday_ids[merged$is_history]
        for (weekday_index in 1:7) {
          weekday_values <- history_open[hist_weekdays == weekday_index]
          weekday_values <- weekday_values[!is.na(weekday_values)]
          if (length(weekday_values) > 0) {
            weekday_default_open[[weekday_index]] <- round(mean(weekday_values))
          }
        }
      }
      overall_open_default <- if (length(history_open[!is.na(history_open)]) > 0) round(mean(history_open, na.rm = TRUE)) else 1
      missing_open <- which(is.na(merged$reg_is_open))
      if (length(missing_open) > 0) {
        for (index in missing_open) {
          merged$reg_is_open[[index]] <- if (frequency == "daily") weekday_default_open[[weekday_ids[[index]]]] else overall_open_default
        }
      }

      future_rows <- which(!merged$is_history)
      applied_closed <- rep(FALSE, nrow(merged))
      applied_holiday <- rep(FALSE, nrow(merged))
      applied_promotion <- rep(FALSE, nrow(merged))
      if (use_future_assumptions && length(future_rows) > 0) {
        if (frequency == "daily" && length(future_assumptions$closedWeekdays) > 0) {
          future_weekdays <- as.integer(format(merged$date[future_rows], "%u"))
          closed_rows <- future_rows[future_weekdays %in% future_assumptions$closedWeekdays]
          if (length(closed_rows) > 0) {
            merged$reg_is_open[closed_rows] <- 0
            applied_closed[closed_rows] <- TRUE
          }
        }

        apply_range_overrides <- function(column_name, ranges, applied_flags) {
          if (length(ranges) == 0) return()
          for (range in ranges) {
            matching_rows <- future_rows[merged$date[future_rows] >= range$startDate & merged$date[future_rows] <= range$endDate]
            if (length(matching_rows) > 0) {
              merged[[column_name]][matching_rows] <- 1
              applied_flags[matching_rows] <- TRUE
            }
          }
          applied_flags
        }

        applied_holiday <- apply_range_overrides("reg_holiday", future_assumptions$holidayRanges, applied_holiday)
        applied_promotion <- apply_range_overrides("reg_promotion", future_assumptions$promotionRanges, applied_promotion)
      }

      calendar_xreg <- build_calendar_regressors(merged$date, frequency)
      feature_xreg <- data.frame(
        reg_price = as.numeric(merged$price),
        reg_holiday = as.numeric(merged$reg_holiday),
        reg_promotion = as.numeric(merged$reg_promotion),
        reg_is_open = as.numeric(merged$reg_is_open)
      )
      xreg <- cbind(calendar_xreg, feature_xreg)
      xreg[] <- lapply(xreg, function(column) as.numeric(column))

      history_length <- length(history_dates)
      future_length <- length(future_dates)
      list(
        history = if (history_length > 0) as.matrix(xreg[seq_len(history_length), , drop = FALSE]) else NULL,
        future = if (future_length > 0) as.matrix(xreg[(history_length + 1):(history_length + future_length), , drop = FALSE]) else NULL,
        combined = as.matrix(xreg),
        futureDiagnostics = list(
          futureRowCount = future_length,
          closedCount = sum(applied_closed[future_rows], na.rm = TRUE),
          holidayCount = sum(applied_holiday[future_rows], na.rm = TRUE),
          promotionCount = sum(applied_promotion[future_rows], na.rm = TRUE),
          items = lapply(future_rows, function(index) {
            list(
              date = format(merged$date[[index]], "%Y-%m-%d"),
              closedWeekdayApplied = isTRUE(applied_closed[[index]]),
              holidayApplied = isTRUE(applied_holiday[[index]]),
              promotionApplied = isTRUE(applied_promotion[[index]]),
              regIsOpen = as.numeric(merged$reg_is_open[[index]]),
              regHoliday = as.numeric(merged$reg_holiday[[index]]),
              regPromotion = as.numeric(merged$reg_promotion[[index]])
            )
          })
        )
      )
    }

    has_future_assumption_inputs <- function(assumptions) {
      length(assumptions$closedWeekdays) > 0 || length(assumptions$holidayRanges) > 0 || length(assumptions$promotionRanges) > 0 || !is.null(assumptions$storeState)
    }

    has_actionable_future_overrides <- function(assumptions) {
      length(assumptions$closedWeekdays) > 0 || length(assumptions$holidayRanges) > 0 || length(assumptions$promotionRanges) > 0
    }

    format_assumption_ranges <- function(ranges) {
      if (length(ranges) == 0) return(list())
      lapply(ranges, function(range) {
        list(
          startDate = format(range$startDate, "%Y-%m-%d"),
          endDate = format(range$endDate, "%Y-%m-%d")
        )
      })
    }

    format_raw_future_assumptions <- function(raw_value) {
      if (is.null(raw_value) || identical(raw_value, "")) return(NULL)
      if (is.character(raw_value) && length(raw_value) == 1) return(raw_value)
      tryCatch(
        toJSON(raw_value, auto_unbox = TRUE, null = "null"),
        error = function(e) as.character(raw_value)
      )
    }

    format_parsed_future_assumptions <- function(assumptions) {
      list(
        storeLocation = if (!is.null(assumptions$storeState) && assumptions$storeState != "") as.character(assumptions$storeState) else NULL,
        closedWeekdays = as.list(as.integer(assumptions$closedWeekdays)),
        holidayRanges = format_assumption_ranges(assumptions$holidayRanges),
        promotionRanges = format_assumption_ranges(assumptions$promotionRanges)
      )
    }

    apply_confirmed_closed_overrides <- function(forecast_values, bounds, diagnostics) {
      adjusted_forecast <- as.numeric(forecast_values)
      adjusted_bounds <- list(
        lower80 = as.numeric(bounds$lower80),
        upper80 = as.numeric(bounds$upper80),
        lower95 = as.numeric(bounds$lower95),
        upper95 = as.numeric(bounds$upper95)
      )
      zeroed_indices <- integer(0)

      if (is.null(diagnostics$items) || length(diagnostics$items) == 0) {
        return(list(forecast = adjusted_forecast, bounds = adjusted_bounds, zeroedIndices = zeroed_indices))
      }

      zeroed_indices <- which(vapply(diagnostics$items, function(item) isTRUE(item$closedWeekdayApplied), logical(1)))
      if (length(zeroed_indices) == 0) {
        return(list(forecast = adjusted_forecast, bounds = adjusted_bounds, zeroedIndices = zeroed_indices))
      }

      adjusted_forecast[zeroed_indices] <- 0
      adjusted_bounds$lower80[zeroed_indices] <- 0
      adjusted_bounds$upper80[zeroed_indices] <- 0
      adjusted_bounds$lower95[zeroed_indices] <- 0
      adjusted_bounds$upper95[zeroed_indices] <- 0

      list(forecast = adjusted_forecast, bounds = adjusted_bounds, zeroedIndices = zeroed_indices)
    }

    build_override_effect_items <- function(sku, stage, diagnostics, adjusted_forecast, baseline_forecast, zeroed_indices = integer(0)) {
      if (is.null(diagnostics$items) || length(diagnostics$items) == 0) return(list())
      items <- list()
      for (index in seq_along(diagnostics$items)) {
        diagnostic_item <- diagnostics$items[[index]]
        if (!isTRUE(diagnostic_item$closedWeekdayApplied) && !isTRUE(diagnostic_item$holidayApplied) && !isTRUE(diagnostic_item$promotionApplied)) {
          next
        }
        adjusted_value <- if (length(adjusted_forecast) >= index) round(as.numeric(adjusted_forecast[[index]]), 2) else NA_real_
        baseline_value <- if (length(baseline_forecast) >= index) round(as.numeric(baseline_forecast[[index]]), 2) else NA_real_
        delta_value <- if (!is.na(adjusted_value) && !is.na(baseline_value)) round(adjusted_value - baseline_value, 2) else NA_real_
        items[[length(items) + 1]] <- list(
          sku = sku,
          stage = stage,
          date = diagnostic_item$date,
          closedWeekdayApplied = diagnostic_item$closedWeekdayApplied,
          holidayApplied = diagnostic_item$holidayApplied,
          promotionApplied = diagnostic_item$promotionApplied,
          regIsOpen = diagnostic_item$regIsOpen,
          regHoliday = diagnostic_item$regHoliday,
          regPromotion = diagnostic_item$regPromotion,
          hardClosedOverrideApplied = index %in% zeroed_indices,
          baselineForecast = baseline_value,
          adjustedForecast = adjusted_value,
          delta = delta_value
        )
      }
      items
    }

    summarize_override_effect_items <- function(items) {
      if (length(items) == 0) {
        return(list(
          affectedItemCount = 0,
          closedItemCount = 0,
          holidayItemCount = 0,
          promotionItemCount = 0,
          hardClosedOverrideCount = 0,
          totalAbsoluteForecastDelta = 0,
          maxAbsoluteForecastDelta = 0,
          items = list()
        ))
      }

      deltas <- suppressWarnings(as.numeric(vapply(items, function(item) item$delta, numeric(1))))
      abs_deltas <- abs(deltas[!is.na(deltas)])
      list(
        affectedItemCount = length(items),
        closedItemCount = sum(vapply(items, function(item) isTRUE(item$closedWeekdayApplied), logical(1))),
        holidayItemCount = sum(vapply(items, function(item) isTRUE(item$holidayApplied), logical(1))),
        promotionItemCount = sum(vapply(items, function(item) isTRUE(item$promotionApplied), logical(1))),
        hardClosedOverrideCount = sum(vapply(items, function(item) isTRUE(item$hardClosedOverrideApplied), logical(1))),
        totalAbsoluteForecastDelta = round(sum(abs_deltas), 2),
        maxAbsoluteForecastDelta = round(if (length(abs_deltas) > 0) max(abs_deltas) else 0, 2),
        items = items
      )
    }

    summarize_regression_diagnostics <- function(diagnostics_list) {
      if (is.null(diagnostics_list) || length(diagnostics_list) == 0) return(NULL)

      unique_strings <- function(values) {
        values <- unlist(values, use.names = FALSE)
        values <- values[!is.na(values) & values != ""]
        sort(unique(as.character(values)))
      }

      fallback_reasons <- list()
      for (diagnostic in diagnostics_list) {
        reason <- diagnostic$fallbackReason
        if (is.null(reason) || is.na(reason) || reason == "") next
        current_count <- fallback_reasons[[reason]]
        fallback_reasons[[reason]] <- ifelse(is.null(current_count), 1, current_count + 1)
      }

      model_used <- vapply(
        diagnostics_list,
        function(diagnostic) ifelse(is.null(diagnostic$modelUsed), "", as.character(diagnostic$modelUsed)),
        character(1)
      )
      model_usage_counts <- list()
      for (usage_name in sort(unique(model_used[model_used != ""]))) {
        model_usage_counts[[usage_name]] <- sum(model_used == usage_name)
      }

      list(
        observations = length(diagnostics_list),
        regressionFits = sum(model_used == "regression_arima"),
        noRegressorsRetained = sum(model_used == "arima_no_regressors_retained"),
        arimaFallbacks = sum(model_used == "arima_fallback"),
        modelUsageCounts = model_usage_counts,
        requestedColumns = unique_strings(lapply(diagnostics_list, function(diagnostic) diagnostic$requestedColumns)),
        usedColumns = unique_strings(lapply(diagnostics_list, function(diagnostic) diagnostic$usedColumns)),
        retainedColumns = unique_strings(lapply(diagnostics_list, function(diagnostic) diagnostic$retainedColumns)),
        droppedByModelColumns = unique_strings(lapply(diagnostics_list, function(diagnostic) diagnostic$droppedByModelColumns)),
        droppedNonFiniteColumns = unique_strings(lapply(diagnostics_list, function(diagnostic) diagnostic$droppedNonFiniteColumns)),
        droppedConstantColumns = unique_strings(lapply(diagnostics_list, function(diagnostic) diagnostic$droppedConstantColumns)),
        droppedDependentColumns = unique_strings(lapply(diagnostics_list, function(diagnostic) diagnostic$droppedDependentColumns)),
        fitErrorMessages = unique_strings(lapply(diagnostics_list, function(diagnostic) diagnostic$fitErrorMessage)),
        fallbackReasons = fallback_reasons
      )
    }

    agg <- aggregate(cbind(quantity, revenue) ~ series_key + sku + location + date, data = historical_df, sum, na.rm = TRUE)
    if (nrow(agg) == 0) {
      stop("No usable data after aggregation")
    }
    aggregated_non_finite <- !is.finite(agg$quantity)
    target_cleanup$droppedAggregatedNonFiniteRows <- sum(aggregated_non_finite, na.rm = TRUE)
    if (any(aggregated_non_finite, na.rm = TRUE)) {
      agg <- agg[!aggregated_non_finite, ]
    }
    if (nrow(agg) == 0) {
      stop("No usable data after removing non-finite aggregated target values")
    }

    unique_series_keys <- sort(unique(agg$series_key))
    series_identity <- lapply(unique_series_keys, function(series_key) {
      row <- agg[agg$series_key == series_key, ][1, ]
      list(
        sku = as.character(row$sku),
        store = as.character(row$location)
      )
    })
    names(series_identity) <- unique_series_keys
    forecast_horizon <- resolve_horizon(input_forecast_horizon, 30)
    daily_forecasts <- list()
    inventory_by_series <- list()

    for (series_key in unique_series_keys) {
      series_df_raw <- df[df$series_key == series_key, ]
      inventory_by_series[[series_key]] <- list(
        onHand = extract_latest_value(series_df_raw, onhand_col),
        leadTimeDays = extract_latest_value(series_df_raw, lead_time_col),
        safetyStockDays = extract_latest_value(series_df_raw, safety_stock_col),
        reorderPoint = extract_latest_value(series_df_raw, reorder_point_col)
      )
    }

    model_mode <- resolve_model_mode(selected_mode)
    model_method <- resolve_model_method(selected_model, model_mode)
    seasonality <- get_seasonality("daily", selected_seasonality)

    series_list <- list()
    series_by_series_key <- list()
    daily_history_dates_by_series <- list()
    daily_xreg_history_by_series <- list()
    actual_daily_map_by_series <- list()
    final_regression_diagnostics <- list()
    daily_future_assumption_effects <- list()
    period_future_assumption_effects <- list()
    local_model_routing <- list()
    valid_series_keys <- character(0)
    valid_series_identity <- list()
    for (series_key in unique_series_keys) {
      series_df <- agg[agg$series_key == series_key, ]
      series_df <- series_df[order(series_df$date), ]
      full_dates <- seq(min(series_df$date), max(series_df$date), by = "day")
      series <- merge(data.frame(date = full_dates), series_df, by = "date", all.x = TRUE)
      series$quantity[is.na(series$quantity)] <- 0
      if (any(!is.finite(series$quantity))) {
        target_cleanup$droppedSeriesWithNonFiniteHistory <- target_cleanup$droppedSeriesWithNonFiniteHistory + 1
        target_cleanup$droppedSeriesKeys <- unique(c(target_cleanup$droppedSeriesKeys, series_key))
        next
      }
      valid_series_keys <- c(valid_series_keys, series_key)
      valid_series_identity[[series_key]] <- series_identity[[series_key]]
      series_list[[length(series_list) + 1]] <- series$quantity
      series_by_series_key[[series_key]] <- series$quantity
      daily_history_dates_by_series[[series_key]] <- series$date
      daily_design <- build_regression_design(df[df$series_key == series_key, ], series$date, as.Date(character(0)), "daily")
      daily_xreg_history_by_series[[series_key]] <- daily_design$history
      local_model_routing[[series_key]] <- list(
        daily = plan_local_series_method(model_method, series$quantity, daily_design$history)
      )
      actual_daily_map_by_series[[series_key]] <- setNames(as.list(round(series$quantity, 2)), format(series$date, "%Y-%m-%d"))
    }
    unique_series_keys <- valid_series_keys
    series_identity <- valid_series_identity
    if (length(unique_series_keys) == 0) {
      stop("No usable series after removing non-finite target histories")
    }

    validation_series_metadata <- lapply(unique_series_keys, function(series_key) {
      identity <- series_identity[[series_key]]
      list(seriesKey = series_key, sku = identity$sku, store = identity$store)
    })

    can_use_global_model <- model_mode == "global" && length(unique_series_keys) >= 3
    executed_model_mode <- if (can_use_global_model) "global" else "local"
    executed_model_method <- if (can_use_global_model) model_method else if (model_mode == "global") "arima" else model_method

    if (can_use_global_model) {
      lag <- if (is.list(seasonality)) round(seasonality[[1]] * 1.25) else round(seasonality * 1.25)
      forecast_matrix <- start_forecasting(series_list, lag, forecast_horizon, model_method)
      for (i in seq_along(unique_series_keys)) {
        series_key <- unique_series_keys[i]
        identity <- series_identity[[series_key]]
        sku <- identity$sku
        store <- identity$store
        forecast_mean <- as.numeric(forecast_matrix[i, ])
        forecast_dates <- seq(max(agg$date[agg$series_key == series_key]) + 1, by = "day", length.out = forecast_horizon)
        daily_future_design <- build_regression_design(df[df$series_key == series_key, ], daily_history_dates_by_series[[series_key]], forecast_dates, "daily")
        bounds <- approx_bounds(forecast_mean, series_by_series_key[[series_key]])
        baseline_forecast_mean <- forecast_mean
        adjusted_daily <- apply_confirmed_closed_overrides(forecast_mean, bounds, daily_future_design$futureDiagnostics)
        forecast_mean <- adjusted_daily$forecast
        bounds <- adjusted_daily$bounds
        if (has_actionable_future_overrides(future_assumptions)) {
          daily_future_assumption_effects <- c(
            daily_future_assumption_effects,
            build_override_effect_items(
              sku,
              "daily",
              daily_future_design$futureDiagnostics,
              forecast_mean,
              baseline_forecast_mean,
              adjusted_daily$zeroedIndices
            )
          )
        }
        daily_forecasts[[series_key]] <- data.frame(
          sku = sku,
          store = store,
          date = format(forecast_dates, "%Y-%m-%d"),
          forecast = round(forecast_mean, 2),
          lower80 = round(bounds$lower80, 2),
          upper80 = round(bounds$upper80, 2),
          lower95 = round(bounds$lower95, 2),
          upper95 = round(bounds$upper95, 2)
        )
      }
    } else {
      for (series_key in unique_series_keys) {
        identity <- series_identity[[series_key]]
        sku <- identity$sku
        store <- identity$store
        message("Starting local daily forecast sku=", sku, " store=", store, " series_key=", series_key)
        series_data <- series_by_series_key[[series_key]]
        history_dates <- daily_history_dates_by_series[[series_key]]
        future_dates <- seq(max(history_dates) + 1, by = "day", length.out = forecast_horizon)
        daily_future_design <- build_regression_design(df[df$series_key == series_key, ], history_dates, future_dates, "daily")
        daily_plan <- if (!is.null(local_model_routing[[series_key]]$daily)) local_model_routing[[series_key]]$daily else list(plannedMethod = executed_model_method, routingReason = NULL)
        daily_method <- if (!is.null(daily_plan$plannedMethod)) daily_plan$plannedMethod else executed_model_method
        forecast_mean <- forecast_with_model(
          series_data,
          daily_method,
          forecast_horizon,
          seasonality,
          daily_xreg_history_by_series[[series_key]],
          daily_future_design$future
        )
        regression_diag <- if (daily_method == "regression_arima") attr(forecast_mean, "regression_diagnostics") else NULL
        bounds <- approx_bounds(forecast_mean, series_data)
        adjusted_daily <- apply_confirmed_closed_overrides(forecast_mean, bounds, daily_future_design$futureDiagnostics)
        forecast_mean <- adjusted_daily$forecast
        bounds <- adjusted_daily$bounds
        if (!is.null(daily_plan)) {
          local_model_routing[[series_key]]$daily$executedMethod <- if (!is.null(regression_diag$modelUsed)) regression_diag$modelUsed else daily_method
        }
        if (daily_method == "regression_arima") {
          if (!is.null(regression_diag)) {
            regression_diag$sku <- sku
            regression_diag$store <- store
            regression_diag$stage <- "daily_forecast"
            final_regression_diagnostics[[length(final_regression_diagnostics) + 1]] <- regression_diag
            message("Regression ARIMA diagnostics [daily] sku=", sku, " store=", store, " modelUsed=", regression_diag$modelUsed, " usedColumns=", paste(regression_diag$usedColumns, collapse = ","), " retainedColumns=", paste(regression_diag$retainedColumns, collapse = ","), " fallbackReason=", ifelse(is.null(regression_diag$fallbackReason), "", regression_diag$fallbackReason))
          }
          if (has_actionable_future_overrides(future_assumptions)) {
            baseline_future_design <- build_regression_design(df[df$series_key == series_key, ], history_dates, future_dates, "daily", use_future_assumptions = FALSE)
            baseline_forecast_mean <- forecast_with_model(
              series_data,
              daily_method,
              forecast_horizon,
              seasonality,
              daily_xreg_history_by_series[[series_key]],
              baseline_future_design$future
            )
            daily_future_assumption_effects <- c(
              daily_future_assumption_effects,
              build_override_effect_items(
                sku,
                "daily",
                daily_future_design$futureDiagnostics,
                forecast_mean,
                baseline_forecast_mean,
                adjusted_daily$zeroedIndices
              )
            )
          }
        }
        daily_forecasts[[series_key]] <- data.frame(
          sku = sku,
          store = store,
          date = format(future_dates, "%Y-%m-%d"),
          forecast = round(forecast_mean, 2),
          lower80 = round(bounds$lower80, 2),
          upper80 = round(bounds$upper80, 2),
          lower95 = round(bounds$lower95, 2),
          upper95 = round(bounds$upper95, 2)
        )
      }
    }

    daily_forecasts_df <- do.call(rbind, daily_forecasts)

    frequency <- if (!is.null(selected_frequency) && selected_frequency != "") selected_frequency else detect_frequency(historical_df$date)
    validation_horizon <- switch(
      frequency,
      daily = 7,
      weekly = 4,
      monthly = 3,
      quarterly = 2,
      yearly = 1,
      7
    )
    forecast_horizon_adj <- resolve_horizon(input_forecast_horizon, if (frequency == "daily") 30 else 12)

    # Metadata per sku-location series
    sku_revenue <- aggregate(revenue ~ series_key + sku + location, data = historical_df, sum, na.rm = TRUE)
    total_revenue <- sum(sku_revenue$revenue, na.rm = TRUE)
    sku_revenue$share <- ifelse(total_revenue > 0, sku_revenue$revenue / total_revenue, 0)
    sku_revenue <- sku_revenue[order(-sku_revenue$share), ]
    sku_revenue$cumshare <- cumsum(sku_revenue$share)

    sku_meta <- list()
    for (i in seq_len(nrow(sku_revenue))) {
      series_key <- sku_revenue$series_key[i]
      sku <- sku_revenue$sku[i]
      store <- sku_revenue$location[i]
      share <- sku_revenue$share[i]
      cumshare <- sku_revenue$cumshare[i]
      abc_class <- if (cumshare <= 0.7) "A" else if (cumshare <= 0.9) "B" else "C"

      sku_meta[[series_key]] <- list(
        sku = sku,
        store = store,
        skuDesc = paste("SKU", sku),
        forecastMethod = if (executed_model_mode == "local" && !is.null(local_model_routing[[series_key]]$daily$plannedMethod)) {
          toupper(local_model_routing[[series_key]]$daily$plannedMethod)
        } else {
          toupper(executed_model_method)
        },
        ABCclass = abc_class,
        ABCpercentage = round(share * 100, 2),
        isApproved = TRUE
      )
    }

    sku_forecast_items <- list()
    seasonality <- get_seasonality(frequency, selected_seasonality)

    period_series_list <- list()
    demand_period_map <- list()
    period_history_dates_by_series <- list()
    period_xreg_history_list <- list()
    validation_series_method_plans <- list()

    for (series_key in unique_series_keys) {
      series_df <- agg[agg$series_key == series_key, ]
      series_df <- series_df[order(series_df$date), ]
      series_df$period <- sapply(series_df$date, period_key, frequency = frequency)
      period_starts <- aggregate(date ~ period, data = transform(series_df, date = as.Date(series_df$date)), min)
      demand_period <- aggregate(quantity ~ period, data = series_df, sum, na.rm = TRUE)
      demand_period <- merge(demand_period, period_starts, by = "period", all.x = TRUE)
      demand_period <- demand_period[order(demand_period$date), ]

      period_series_list[[length(period_series_list) + 1]] <- demand_period$quantity
      demand_period_map[[series_key]] <- demand_period
      period_history_dates_by_series[[series_key]] <- demand_period$date
      period_design <- build_regression_design(df[df$series_key == series_key, ], demand_period$date, as.Date(character(0)), frequency)
      period_xreg_history_list[[length(period_xreg_history_list) + 1]] <- period_design$history
      validation_series_method_plans[[length(validation_series_method_plans) + 1]] <- plan_local_series_method("arima", demand_period$quantity, period_design$history)
      local_model_routing[[series_key]]$period <- validation_series_method_plans[[length(validation_series_method_plans)]]
    }

    forecast_matrix <- NULL
    if (can_use_global_model) {
      lag <- if (is.list(seasonality)) round(seasonality[[1]] * 1.25) else round(seasonality * 1.25)
      forecast_matrix <- start_forecasting(period_series_list, lag, forecast_horizon_adj, model_method)
    }

    selected_validation <- if (can_use_global_model) {
      evaluate_global_holdout(period_series_list, seasonality, validation_horizon, executed_model_method, validation_series_metadata)
    } else {
      evaluate_local_validation(period_series_list, executed_model_method, seasonality, validation_horizon, period_xreg_history_list, validation_series_metadata, validation_series_method_plans)
    }
    arima_validation <- evaluate_local_validation(
      period_series_list,
      "arima",
      seasonality,
      validation_horizon,
      series_metadata = validation_series_metadata,
      validation_strategy = if (can_use_global_model) "holdout" else "auto"
    )

    for (i in seq_along(unique_series_keys)) {
      series_key <- unique_series_keys[i]
      identity <- series_identity[[series_key]]
      sku <- identity$sku
      store <- identity$store
      demand_period <- demand_period_map[[series_key]]
      series <- demand_period$quantity

      if (can_use_global_model && !is.null(forecast_matrix)) {
        forecast_mean <- as.numeric(forecast_matrix[i, ])
        last_period_date <- tail(demand_period$date, 1)
        future_dates <- sequence_periods(last_period_date, frequency, forecast_horizon_adj)
        period_future_design <- build_regression_design(df[df$series_key == series_key, ], period_history_dates_by_series[[series_key]], future_dates, frequency)
        bounds <- approx_bounds(forecast_mean, series)
        baseline_forecast_mean <- forecast_mean
        adjusted_period <- apply_confirmed_closed_overrides(forecast_mean, bounds, period_future_design$futureDiagnostics)
        forecast_mean <- adjusted_period$forecast
        bounds <- adjusted_period$bounds
        if (has_actionable_future_overrides(future_assumptions)) {
          period_future_assumption_effects <- c(
            period_future_assumption_effects,
            build_override_effect_items(
              sku,
              "period",
              period_future_design$futureDiagnostics,
              forecast_mean,
              baseline_forecast_mean,
              adjusted_period$zeroedIndices
            )
          )
        }
      } else {
        last_period_date <- tail(demand_period$date, 1)
        future_dates <- sequence_periods(last_period_date, frequency, forecast_horizon_adj)
        period_future_design <- build_regression_design(df[df$series_key == series_key, ], period_history_dates_by_series[[series_key]], future_dates, frequency)
        message("Starting local period forecast sku=", sku, " store=", store, " series_key=", series_key, " frequency=", frequency)
        period_plan <- if (!is.null(local_model_routing[[series_key]]$period)) local_model_routing[[series_key]]$period else list(plannedMethod = executed_model_method, routingReason = NULL)
        period_method <- if (!is.null(period_plan$plannedMethod)) period_plan$plannedMethod else executed_model_method
        forecast_mean <- forecast_with_model(
          series,
          period_method,
          forecast_horizon_adj,
          seasonality,
          period_xreg_history_list[[i]],
          period_future_design$future
        )
        regression_diag <- if (period_method == "regression_arima") attr(forecast_mean, "regression_diagnostics") else NULL
        bounds <- approx_bounds(forecast_mean, series)
        adjusted_period <- apply_confirmed_closed_overrides(forecast_mean, bounds, period_future_design$futureDiagnostics)
        forecast_mean <- adjusted_period$forecast
        bounds <- adjusted_period$bounds
        if (!is.null(period_plan)) {
          local_model_routing[[series_key]]$period$executedMethod <- if (!is.null(regression_diag$modelUsed)) regression_diag$modelUsed else period_method
        }
        if (period_method == "regression_arima") {
          if (!is.null(regression_diag)) {
            regression_diag$sku <- sku
            regression_diag$store <- store
            regression_diag$stage <- "period_forecast"
            final_regression_diagnostics[[length(final_regression_diagnostics) + 1]] <- regression_diag
            message("Regression ARIMA diagnostics [period] sku=", sku, " store=", store, " modelUsed=", regression_diag$modelUsed, " usedColumns=", paste(regression_diag$usedColumns, collapse = ","), " retainedColumns=", paste(regression_diag$retainedColumns, collapse = ","), " fallbackReason=", ifelse(is.null(regression_diag$fallbackReason), "", regression_diag$fallbackReason))
          }
          if (has_actionable_future_overrides(future_assumptions)) {
            baseline_period_design <- build_regression_design(df[df$series_key == series_key, ], period_history_dates_by_series[[series_key]], future_dates, frequency, use_future_assumptions = FALSE)
            baseline_forecast_mean <- forecast_with_model(
              series,
              period_method,
              forecast_horizon_adj,
              seasonality,
              period_xreg_history_list[[i]],
              baseline_period_design$future
            )
            period_future_assumption_effects <- c(
              period_future_assumption_effects,
              build_override_effect_items(
                sku,
                "period",
                period_future_design$futureDiagnostics,
                forecast_mean,
                baseline_forecast_mean,
                adjusted_period$zeroedIndices
              )
            )
          }
        }
      }

      last_period_date <- tail(demand_period$date, 1)
      future_dates <- sequence_periods(last_period_date, frequency, forecast_horizon_adj)
      forecast_keys <- sapply(future_dates, period_key, frequency = frequency)

      forecast_map <- to_named_map(forecast_keys, round(forecast_mean, 2))
      lower80_map <- to_named_map(forecast_keys, round(bounds$lower80, 2))
      upper80_map <- to_named_map(forecast_keys, round(bounds$upper80, 2))
      lower95_map <- to_named_map(forecast_keys, round(bounds$lower95, 2))
      upper95_map <- to_named_map(forecast_keys, round(bounds$upper95, 2))

      periods <- forecast_keys
      demand_map <- lapply(forecast_keys, function(period_key_value) NA_real_)
      names(demand_map) <- forecast_keys
      forecast_baseline_map <- forecast_map
      demand_adjustment_map <- to_named_map(forecast_keys, rep(0, length(forecast_keys)))
      forecast_adjustment_map <- to_named_map(forecast_keys, rep(0, length(forecast_keys)))
      lower80_full_map <- lower80_map
      upper80_full_map <- upper80_map
      lower95_full_map <- lower95_map
      upper95_full_map <- upper95_map

      if (frequency == "daily") {
        last_actual_date <- tail(as.Date(demand_period$date), 1)
        historical_dates <- seq(last_actual_date - 29, by = "day", length.out = 30)
        historical_keys <- format(historical_dates, "%Y-%m-%d")
        periods <- c(historical_keys, forecast_keys)

        actual_map <- actual_daily_map_by_series[[series_key]]
        demand_map <- lapply(periods, function(period_key_value) {
          if (period_key_value %in% historical_keys) {
            if (!is.null(actual_map) && period_key_value %in% names(actual_map)) {
              return(actual_map[[period_key_value]])
            }
            return(NA_real_)
          }
          NA_real_
        })
        names(demand_map) <- periods

        prev_baseline <- previous_forecast_by_series[[series_key]]
        forecast_baseline_map <- lapply(periods, function(period_key_value) {
          if (period_key_value %in% forecast_keys) {
            return(forecast_map[[period_key_value]])
          }
          if (!is.null(prev_baseline) && period_key_value %in% names(prev_baseline)) {
            return(as.numeric(prev_baseline[[period_key_value]]))
          }
          NA_real_
        })
        names(forecast_baseline_map) <- periods

        demand_adjustment_map <- to_named_map(periods, rep(0, length(periods)))
        forecast_adjustment_map <- to_named_map(periods, rep(0, length(periods)))

        lower80_full_map <- lapply(periods, function(period_key_value) {
          if (period_key_value %in% forecast_keys) return(lower80_map[[period_key_value]])
          NA_real_
        })
        names(lower80_full_map) <- periods
        upper80_full_map <- lapply(periods, function(period_key_value) {
          if (period_key_value %in% forecast_keys) return(upper80_map[[period_key_value]])
          NA_real_
        })
        names(upper80_full_map) <- periods
        lower95_full_map <- lapply(periods, function(period_key_value) {
          if (period_key_value %in% forecast_keys) return(lower95_map[[period_key_value]])
          NA_real_
        })
        names(lower95_full_map) <- periods
        upper95_full_map <- lapply(periods, function(period_key_value) {
          if (period_key_value %in% forecast_keys) return(upper95_map[[period_key_value]])
          NA_real_
        })
        names(upper95_full_map) <- periods
      }

      store <- if (!is.null(sku_meta[[series_key]]$store)) sku_meta[[series_key]]$store else "Unknown"

      sku_forecast_items[[length(sku_forecast_items) + 1]] <- list(
        sku = sku,
        store = store,
        frequency = frequency,
        periods = periods,
        demand = demand_map,
        forecastBaseline = forecast_baseline_map,
        demandAdjustment = demand_adjustment_map,
        forecastAdjustment = forecast_adjustment_map,
        lower80 = lower80_full_map,
        upper80 = upper80_full_map,
        lower95 = lower95_full_map,
        upper95 = upper95_full_map,
        originalDemand = demand_map,
        originalForecastBaseline = forecast_baseline_map,
        model = executed_model_method
      )
    }

    sku_forecast_values <- list(
      frequency = frequency,
      items = sku_forecast_items
    )

    # Tenant-level merged projection for navigator:
    # merge current run outputs with previous projection without retraining.
    projection_key <- paste0("tenant-artifacts/", tenant_id, "/projection/sku_forecast_projection.json")
    previous_projection <- tryCatch({
      read_json_from_s3(artifact_bucket, projection_key)
    }, error = function(e) NULL)

    safe_item_key <- function(item) {
      sku_value <- if (!is.null(item$sku)) as.character(item$sku) else ""
      store_value <- if (!is.null(item$store)) as.character(item$store) else ""
      paste0(sku_value, "::", store_value)
    }

    to_numeric_map <- function(map_obj) {
      out <- list()
      if (is.null(map_obj) || is.null(names(map_obj))) return(out)
      for (key in names(map_obj)) {
        value <- suppressWarnings(as.numeric(map_obj[[key]]))
        if (!is.na(value)) out[[key]] <- value
      }
      out
    }

    merge_maps <- function(base_map, overlay_map) {
      merged <- if (!is.null(base_map)) base_map else list()
      if (is.null(overlay_map) || is.null(names(overlay_map))) return(merged)
      for (key in names(overlay_map)) {
        merged[[key]] <- overlay_map[[key]]
      }
      merged
    }

    map_to_period_values <- function(periods, map_obj, default_value = NA_real_) {
      result <- lapply(periods, function(period_key_value) {
        if (!is.null(map_obj) && period_key_value %in% names(map_obj)) {
          return(map_obj[[period_key_value]])
        }
        default_value
      })
      names(result) <- periods
      result
    }

    previous_items <- if (!is.null(previous_projection$items) && length(previous_projection$items) > 0) previous_projection$items else list()
    previous_by_key <- list()
    for (prev_item in previous_items) {
      previous_by_key[[safe_item_key(prev_item)]] <- prev_item
    }

    current_by_key <- list()
    for (current_item in sku_forecast_items) {
      current_by_key[[safe_item_key(current_item)]] <- current_item
    }

    all_item_keys <- union(names(previous_by_key), names(current_by_key))
    projection_items <- list()

    for (item_key_value in all_item_keys) {
      prev_item <- previous_by_key[[item_key_value]]
      curr_item <- current_by_key[[item_key_value]]

      selected_item <- if (!is.null(curr_item)) curr_item else prev_item
      if (is.null(selected_item)) next

      merged_actual <- merge_maps(
        to_numeric_map(if (!is.null(prev_item)) prev_item$demand else NULL),
        to_numeric_map(if (!is.null(curr_item)) curr_item$demand else NULL)
      )
      merged_baseline <- merge_maps(
        to_numeric_map(if (!is.null(prev_item)) prev_item$forecastBaseline else NULL),
        to_numeric_map(if (!is.null(curr_item)) curr_item$forecastBaseline else NULL)
      )

      merged_lower80 <- merge_maps(
        to_numeric_map(if (!is.null(prev_item)) prev_item$lower80 else NULL),
        to_numeric_map(if (!is.null(curr_item)) curr_item$lower80 else NULL)
      )
      merged_upper80 <- merge_maps(
        to_numeric_map(if (!is.null(prev_item)) prev_item$upper80 else NULL),
        to_numeric_map(if (!is.null(curr_item)) curr_item$upper80 else NULL)
      )
      merged_lower95 <- merge_maps(
        to_numeric_map(if (!is.null(prev_item)) prev_item$lower95 else NULL),
        to_numeric_map(if (!is.null(curr_item)) curr_item$lower95 else NULL)
      )
      merged_upper95 <- merge_maps(
        to_numeric_map(if (!is.null(prev_item)) prev_item$upper95 else NULL),
        to_numeric_map(if (!is.null(curr_item)) curr_item$upper95 else NULL)
      )

      merged_periods <- sort(unique(c(names(merged_actual), names(merged_baseline))))
      if (length(merged_periods) == 0) {
        merged_periods <- if (!is.null(selected_item$periods)) as.character(selected_item$periods) else character(0)
      }

      demand_values <- map_to_period_values(merged_periods, merged_actual, NA_real_)
      baseline_values <- map_to_period_values(merged_periods, merged_baseline, NA_real_)
      zero_adjustments <- to_named_map(merged_periods, rep(0, length(merged_periods)))

      projection_items[[length(projection_items) + 1]] <- list(
        sku = selected_item$sku,
        store = selected_item$store,
        frequency = if (!is.null(curr_item$frequency)) curr_item$frequency else selected_item$frequency,
        periods = merged_periods,
        demand = demand_values,
        forecastBaseline = baseline_values,
        demandAdjustment = zero_adjustments,
        forecastAdjustment = zero_adjustments,
        lower80 = map_to_period_values(merged_periods, merged_lower80, NA_real_),
        upper80 = map_to_period_values(merged_periods, merged_upper80, NA_real_),
        lower95 = map_to_period_values(merged_periods, merged_lower95, NA_real_),
        upper95 = map_to_period_values(merged_periods, merged_upper95, NA_real_),
        originalDemand = demand_values,
        originalForecastBaseline = baseline_values,
        model = if (!is.null(curr_item$model)) curr_item$model else selected_item$model
      )
    }

    projection_generated_at <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ")
    projection_version <- paste0(run_id, "-", gsub("[^0-9]", "", projection_generated_at))

    sku_forecast_projection <- list(
      frequency = frequency,
      generatedAt = projection_generated_at,
      projectionVersion = projection_version,
      updatedByRunId = run_id,
      itemCount = length(projection_items),
      items = projection_items
    )

    # Monthly aggregates
    max_date <- max(agg$date)
    month_seq <- seq(as.Date(format(max_date, "%Y-%m-01")), by = "-1 month", length.out = 12)
    month_keys <- format(month_seq, "%m-%Y")

    agg$month_key <- format(agg$date, "%m-%Y")
    monthly_actual <- aggregate(quantity ~ month_key, data = agg, sum, na.rm = TRUE)

    daily_forecasts_df$month_key <- format(as.Date(daily_forecasts_df$date), "%m-%Y")
    monthly_forecast <- aggregate(forecast ~ month_key, data = daily_forecasts_df, sum, na.rm = TRUE)

    fill_metric <- function(map) {
      values <- sapply(month_keys, function(key) {
        if (key %in% names(map)) map[[key]] else 0
      })
      result <- as.list(values)
      names(result) <- month_keys
      result$average <- round(mean(values), 2)
      result
    }

    demand_map <- setNames(monthly_actual$quantity, monthly_actual$month_key)
    forecast_map <- setNames(monthly_forecast$forecast, monthly_forecast$month_key)
    variance_map <- setNames(
      sapply(month_keys, function(key) {
        (if (key %in% names(forecast_map)) forecast_map[[key]] else 0) -
          (if (key %in% names(demand_map)) demand_map[[key]] else 0)
      }),
      month_keys
    )
    monthly_revenue <- aggregate(
      revenue ~ month_key + month_start,
      data = transform(agg, month_key = format(date, "%m-%Y"), month_start = as.Date(format(date, "%Y-%m-01"))),
      sum,
      na.rm = TRUE
    )
    revenue_map <- setNames(monthly_revenue$revenue, monthly_revenue$month_key)

    monthly_forecasts <- list(
      budget = fill_metric(revenue_map),
      demand = fill_metric(demand_map),
      demandAdjustment = fill_metric(setNames(rep(0, length(month_keys)), month_keys)),
      forecastBaseline = fill_metric(forecast_map),
      forecastAdjustment = fill_metric(setNames(rep(0, length(month_keys)), month_keys)),
      previousForecasts = fill_metric(forecast_map),
      variance = fill_metric(variance_map),
      revenue = fill_metric(revenue_map)
    )

    # Monthly totals for overview
    total_revenue_value <- round(sum(df$revenue, na.rm = TRUE), 2)
    total_skus <- length(unique(historical_df$sku))
    total_series <- length(unique_series_keys)
    month_revenue <- monthly_revenue
    growth_rate <- 0
    if (nrow(month_revenue) >= 2) {
      sorted <- month_revenue[order(month_revenue$month_start), ]
      last <- tail(sorted$revenue, 1)
      prev <- tail(sorted$revenue, 2)[1]
      if (prev != 0) growth_rate <- (last - prev) / prev
    }

    default_lead_days <- list(A = 7, B = 14, C = 21)
    default_safety_days <- list(A = 4, B = 6, C = 8)
    default_cover_days <- list(A = 8, B = 14, C = 22)

    replenishment_items <- list()
    for (series_key in unique_series_keys) {
      identity <- series_identity[[series_key]]
      sku <- identity$sku
      store <- identity$store
      sku_info <- sku_meta[[series_key]]
      abc_class <- if (!is.null(sku_info$ABCclass)) sku_info$ABCclass else "C"
      if (!(abc_class %in% c("A", "B", "C"))) abc_class <- "C"

      forecast_df <- daily_forecasts[[series_key]]
      demand_values <- pmax(as.numeric(forecast_df$forecast), 0)
      avg_daily_demand <- if (length(demand_values) > 0) mean(demand_values, na.rm = TRUE) else 0
      horizon_demand <- if (length(demand_values) > 0) sum(demand_values, na.rm = TRUE) else 0

      inventory <- inventory_by_series[[series_key]]
      lead_time_days <- as.numeric(inventory$leadTimeDays)
      safety_stock_days <- as.numeric(inventory$safetyStockDays)
      reorder_point <- as.numeric(inventory$reorderPoint)
      on_hand <- as.numeric(inventory$onHand)
      on_hand_source <- "provided"

      if (is.na(lead_time_days) || lead_time_days <= 0) lead_time_days <- default_lead_days[[abc_class]]
      if (is.na(safety_stock_days) || safety_stock_days < 0) safety_stock_days <- default_safety_days[[abc_class]]
      if (is.na(on_hand) || on_hand < 0) {
        on_hand <- round(avg_daily_demand * default_cover_days[[abc_class]])
        on_hand_source <- "estimated"
      }

      if (is.na(reorder_point) || reorder_point < 0) {
        reorder_point <- round(avg_daily_demand * (lead_time_days + safety_stock_days))
      }

      days_of_cover <- if (avg_daily_demand > 0) on_hand / avg_daily_demand else NA_real_
      risk <- "Healthy"
      predicted_stockout <- NULL
      reorder_by <- NULL
      recommended_reorder_qty <- 0

      if (avg_daily_demand > 0) {
        critical_threshold <- max(3, ceiling(lead_time_days * 0.6))
        if (days_of_cover <= critical_threshold) {
          risk <- "Critical"
        } else if (days_of_cover <= lead_time_days) {
          risk <- "High"
        } else if (days_of_cover <= (lead_time_days + safety_stock_days)) {
          risk <- "Medium"
        }

        stockout_date <- Sys.Date() + max(1, floor(days_of_cover))
        predicted_stockout <- format(stockout_date, "%Y-%m-%d")
        if (risk != "Healthy") {
          reorder_by <- format(stockout_date - lead_time_days, "%Y-%m-%d")
        }

        required_units <- (lead_time_days + safety_stock_days) * avg_daily_demand
        recommended_reorder_qty <- max(0, ceiling(required_units - on_hand))
      }

      replenishment_items[[length(replenishment_items) + 1]] <- list(
        sku = sku,
        store = if (!is.null(sku_info$store)) sku_info$store else store,
        skuDesc = if (!is.null(sku_info$skuDesc)) sku_info$skuDesc else paste("SKU", sku),
        abcClass = abc_class,
        avgDailyDemand = round(avg_daily_demand, 2),
        horizonDemand = round(horizon_demand, 2),
        onHand = round(on_hand, 2),
        onHandSource = on_hand_source,
        leadTimeDays = round(lead_time_days, 2),
        safetyStockDays = round(safety_stock_days, 2),
        reorderPoint = round(reorder_point, 2),
        daysOfCover = if (is.na(days_of_cover)) NULL else round(days_of_cover, 2),
        predictedStockoutDate = predicted_stockout,
        reorderByDate = reorder_by,
        recommendedReorderQty = recommended_reorder_qty,
        risk = risk,
        confidence = ifelse(on_hand_source == "provided", "high", "medium")
      )
    }

    effective_horizon <- if (frequency == "daily") forecast_horizon else forecast_horizon_adj
    replenishment_signals <- list(
      generatedAt = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ"),
      horizonDays = effective_horizon,
      items = replenishment_items
    )

    at_risk_count <- length(Filter(function(item) {
      !is.null(item$risk) && (item$risk == "Critical" || item$risk == "High")
    }, replenishment_items))
    at_risk_rate <- if (total_skus > 0) -(at_risk_count / total_skus) else 0

    selected_smape <- if (!is.null(selected_validation$metrics$smape)) as.numeric(selected_validation$metrics$smape) else NA_real_
    arima_smape <- if (!is.null(arima_validation$metrics$smape)) as.numeric(arima_validation$metrics$smape) else NA_real_
    forecast_accuracy_value <- if (!is.na(selected_smape)) round(pmax(0, 100 - selected_smape), 2) else 0
    accuracy_delta <- if (!is.na(selected_smape) && !is.na(arima_smape) && arima_smape != 0) {
      (arima_smape - selected_smape) / abs(arima_smape)
    } else {
      0
    }

    monthly_totals <- list(
      totalRevenue = list(value = total_revenue_value, variance = round(growth_rate, 3), status = calc_status(growth_rate)),
      stockoutRiskSkus = list(value = at_risk_count, variance = round(at_risk_rate, 3), status = calc_status(at_risk_rate)),
      forecastAccuracy = list(value = forecast_accuracy_value, variance = round(accuracy_delta, 3), status = calc_status(accuracy_delta)),
      growthRate = list(value = round(growth_rate * 100, 2), variance = round(growth_rate, 3), status = calc_status(growth_rate))
    )

    future_assumptions_summary <- list(
      provided = has_future_assumption_inputs(future_assumptions),
      actionableOverridesProvided = has_actionable_future_overrides(future_assumptions),
      model = executed_model_method,
      modelConsumesFutureHints = has_actionable_future_overrides(future_assumptions) || (executed_model_mode == "local" && executed_model_method == "regression_arima"),
      rawInput = format_raw_future_assumptions(input_future_assumptions_json),
      requested = format_parsed_future_assumptions(future_assumptions),
      dailyForecastImpact = summarize_override_effect_items(daily_future_assumption_effects),
      periodForecastImpact = summarize_override_effect_items(period_future_assumption_effects)
    )

    summary <- list(
      totalSkus = total_skus,
      totalSeries = total_series,
      rows = nrow(df),
      dateStart = format(min(df$date), "%Y-%m-%d"),
      dateEnd = format(max(df$date), "%Y-%m-%d"),
      runConfig = list(
        requestedModel = selected_model,
        executedModel = executed_model_method,
        executedMode = executed_model_mode,
        requestedFrequency = selected_frequency,
        detectedFrequency = frequency,
        requestedTargetColumn = requested_target,
        resolvedTargetColumn = target_column
      ),
      targetCleanupDiagnostics = list(
        rawRows = target_cleanup$rawRows,
        retainedFiniteTargetRows = target_cleanup$retainedFiniteTargetRows,
        droppedNonFiniteTargetRows = target_cleanup$droppedNonFiniteTargetRows,
        droppedAggregatedNonFiniteRows = target_cleanup$droppedAggregatedNonFiniteRows,
        droppedSeriesWithNonFiniteHistory = target_cleanup$droppedSeriesWithNonFiniteHistory,
        droppedSeriesKeys = as.list(sort(unique(target_cleanup$droppedSeriesKeys)))
      ),
      localModelRouting = if (executed_model_mode == "local") local_model_routing else NULL,
      futureAssumptionsDiagnostics = future_assumptions_summary,
      validation = list(
        frequency = frequency,
        selectedModel = list(
          model = executed_model_method,
          mode = executed_model_mode,
          strategy = if (!is.null(selected_validation)) selected_validation$strategy else "none",
          horizon = if (!is.null(selected_validation)) selected_validation$horizon else validation_horizon,
          seriesCount = if (!is.null(selected_validation)) selected_validation$seriesCount else 0,
          windows = if (!is.null(selected_validation)) selected_validation$windows else 0,
          metrics = if (!is.null(selected_validation)) selected_validation$metrics else list(mae = NA, rmse = NA, smape = NA),
          regressionDiagnostics = if (!is.null(selected_validation)) selected_validation$regressionDiagnostics else NULL,
          perSeries = if (!is.null(selected_validation)) selected_validation$perSeries else list()
        ),
        arimaBaseline = list(
          model = "arima",
          mode = "local",
          strategy = if (!is.null(arima_validation)) arima_validation$strategy else "none",
          horizon = if (!is.null(arima_validation)) arima_validation$horizon else validation_horizon,
          seriesCount = if (!is.null(arima_validation)) arima_validation$seriesCount else 0,
          windows = if (!is.null(arima_validation)) arima_validation$windows else 0,
          metrics = if (!is.null(arima_validation)) arima_validation$metrics else list(mae = NA, rmse = NA, smape = NA),
          perSeries = if (!is.null(arima_validation)) arima_validation$perSeries else list()
        ),
        finalRegressionDiagnostics = summarize_regression_diagnostics(final_regression_diagnostics)
      )
    )

    # Write outputs to S3
    if (is.null(artifact_bucket) || artifact_bucket == "") {
      stop("Missing ARTIFACT_BUCKET environment variable")
    }

    output_prefix <- if (is_batch_run && !is.null(batch_output_prefix) && batch_output_prefix != "") batch_output_prefix else s3_output_prefix
    write_json(paste0(output_prefix, "/daily_forecasts.json"), daily_forecasts_df)
    write_json(paste0(output_prefix, "/metadata.json"), sku_meta)
    write_json(paste0(output_prefix, "/monthly_forecasts.json"), monthly_forecasts)
    write_json(paste0(output_prefix, "/monthly_totals.json"), monthly_totals)
    write_json(paste0(output_prefix, "/report_summary.json"), summary)
    write_json(paste0(output_prefix, "/sku_forecast_values.json"), sku_forecast_values)
    if (!is_batch_run) {
      write_json(projection_key, sku_forecast_projection)
    }
    write_json(paste0(output_prefix, "/replenishment_signals.json"), replenishment_signals)

    if (is_batch_run) {
      update_batch_item_status("DONE")
      run_attrs <- increment_run_batch_counter("completedBatchCount")
      completed_count <- ddb_get_number(run_attrs$Attributes, "completedBatchCount", 0)
      failed_count <- ddb_get_number(run_attrs$Attributes, "failedBatchCount", 0)
      total_batches <- ddb_get_number(run_attrs$Attributes, "batchCount", batch_count)
      if ((completed_count + failed_count) >= total_batches && failed_count == 0 && try_claim_aggregation()) {
        final_summary <- aggregate_batch_outputs()
        update_run_status(ddb, forecast_runs_table, tenant_id, run_id, "DONE", s3_output_prefix, final_summary)
        log_forecast_event("forecast_run_succeeded", "Batch aggregation completed", list(status = "DONE"))
        return(list(status = "success", result = final_summary))
      }
      if ((completed_count + failed_count) >= total_batches && failed_count > 0 && try_claim_aggregation()) {
        failure_summary <- list(stage = "distributed_local_batches", reason = "one_or_more_batches_failed", completedBatchCount = completed_count, failedBatchCount = failed_count, batchCount = total_batches)
        update_run_status(ddb, forecast_runs_table, tenant_id, run_id, "FAILED", summary = failure_summary)
      }
      log_forecast_event("forecast_run_succeeded", "Batch forecast completed", list(status = "DONE"))
      return(list(status = "success", result = summary))
    }

    update_run_status(ddb, forecast_runs_table, tenant_id, run_id, "DONE", s3_output_prefix, summary)
    log_forecast_event("forecast_run_succeeded", "Forecast pipeline completed", list(status = "DONE"))
    return(list(status = "success", result = summary))
  }, error = function(e) {
    error_message <- ifelse(is.null(e$message) || e$message == "", "forecast_pipeline_failed", as.character(e$message))
    failure_summary <- list(
      stage = "forecast_pipeline",
      reason = error_message,
      error = error_message
    )
    message("Forecast pipeline failed for run_id=", run_id, " tenant_id=", tenant_id, " error=", error_message)
    log_forecast_event("forecast_run_failed", "Forecast pipeline failed", list(status = "FAILED", error = error_message))
    if (is_batch_run) {
      update_batch_item_status("FAILED", error_message)
      run_attrs <- increment_run_batch_counter("failedBatchCount")
      completed_count <- ddb_get_number(run_attrs$Attributes, "completedBatchCount", 0)
      failed_count <- ddb_get_number(run_attrs$Attributes, "failedBatchCount", 0)
      total_batches <- ddb_get_number(run_attrs$Attributes, "batchCount", batch_count)
      if ((completed_count + failed_count) >= total_batches && try_claim_aggregation()) {
        failure_summary$completedBatchCount <- completed_count
        failure_summary$failedBatchCount <- failed_count
        failure_summary$batchCount <- total_batches
        update_run_status(ddb, forecast_runs_table, tenant_id, run_id, "FAILED", summary = failure_summary)
      }
    } else {
      update_run_status(ddb, forecast_runs_table, tenant_id, run_id, "FAILED", summary = failure_summary)
    }
    return(list(status = "error", message = e$message))
  })
}
