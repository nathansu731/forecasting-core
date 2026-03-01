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

  unwrap_value <- function(x) {
    if (is.null(x)) return(NULL)
    if (is.list(x)) return(x[[1]])
    if (length(x) == 1) return(x[[1]])
    x
  }

  tenant_id <- unwrap_value(event$tenantId)
  run_id <- unwrap_value(event$runId)
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
  selected_seasonality <- unwrap_value(event$seasonality)

  if (is.null(tenant_id) || is.null(run_id) || is.null(s3_bucket) || is.null(s3_key)) {
    return(list(status = "error", message = "missing_inputs"))
  }

  message("Forecast run env: raw_bucket=", raw_bucket, " artifact_bucket=", artifact_bucket, " forecast_runs_table=", forecast_runs_table)
  message("Forecast run input: tenant_id=", tenant_id, " run_id=", run_id, " s3_bucket=", s3_bucket, " s3_key=", s3_key, " output_prefix=", s3_output_prefix, " adjustments_key=", adjustments_key, " model=", selected_model, " mode=", selected_mode)

  s3 <- paws.storage::s3()
  ddb <- NULL
  if (requireNamespace("paws.dynamodb", quietly = TRUE)) {
    ddb <- paws.dynamodb::dynamodb()
  }

  read_json_from_s3 <- function(bucket, key) {
    obj <- s3$get_object(Bucket = bucket, Key = key)
    raw_text <- rawToChar(obj$Body)
    fromJSON(raw_text, simplifyVector = FALSE)
  }

  write_json <- function(key, payload) {
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
    }, error = function(e) {
      message("Failed writing artifact ", key, ": ", e$message)
      stop(e)
    })
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

    df <- read.csv(text = raw_text, stringsAsFactors = FALSE)
    df <- normalize_columns(df)

    required_cols <- c("date", "sku", "quantity", "location", "price", "isholiday", "promotion", "aisle")
    missing_cols <- setdiff(required_cols, names(df))
    if (length(missing_cols) > 0) {
      stop(paste("Missing columns:", paste(missing_cols, collapse = ", ")))
    }

    df$date <- as.Date(df$date)
    df$quantity <- as.numeric(df$quantity)
    df$price <- as.numeric(df$price)
    df$isholiday <- safe_bool(df$isholiday)
    df$revenue <- df$quantity * df$price

    df <- df[!is.na(df$date) & !is.na(df$sku), ]

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

    extract_latest_value <- function(sku_df, column_name) {
      if (is.null(column_name) || !(column_name %in% names(sku_df))) return(NA_real_)
      values <- suppressWarnings(as.numeric(sku_df[[column_name]]))
      idx <- which(!is.na(values))
      if (length(idx) == 0) return(NA_real_)
      ordered <- idx[order(sku_df$date[idx], decreasing = TRUE)]
      as.numeric(values[ordered[1]])
    }

    agg <- aggregate(cbind(quantity, revenue) ~ sku + date, data = df, sum, na.rm = TRUE)
    if (nrow(agg) == 0) {
      stop("No usable data after aggregation")
    }

    unique_skus <- sort(unique(agg$sku))
    forecast_horizon <- 30
    daily_forecasts <- list()
    inventory_by_sku <- list()

    for (sku in unique_skus) {
      sku_df_raw <- df[df$sku == sku, ]
      inventory_by_sku[[sku]] <- list(
        onHand = extract_latest_value(sku_df_raw, onhand_col),
        leadTimeDays = extract_latest_value(sku_df_raw, lead_time_col),
        safetyStockDays = extract_latest_value(sku_df_raw, safety_stock_col),
        reorderPoint = extract_latest_value(sku_df_raw, reorder_point_col)
      )
    }

    model_mode <- resolve_model_mode(selected_mode)
    model_method <- resolve_model_method(selected_model, model_mode)
    seasonality <- get_seasonality("daily", selected_seasonality)

    series_list <- list()
    series_by_sku <- list()
    for (sku in unique_skus) {
      sku_df <- agg[agg$sku == sku, ]
      sku_df <- sku_df[order(sku_df$date), ]
      full_dates <- seq(min(sku_df$date), max(sku_df$date), by = "day")
      series <- merge(data.frame(date = full_dates), sku_df, by = "date", all.x = TRUE)
      series$quantity[is.na(series$quantity)] <- 0
      series_list[[length(series_list) + 1]] <- series$quantity
      series_by_sku[[sku]] <- series$quantity
    }

    if (model_mode == "global" && length(unique_skus) >= 3) {
      lag <- if (is.list(seasonality)) round(seasonality[[1]] * 1.25) else round(seasonality * 1.25)
      forecast_matrix <- start_forecasting(series_list, lag, forecast_horizon, ifelse(model_method == "pooled_regression", "pooled_regression", "pooled_regression"))
      for (i in seq_along(unique_skus)) {
        sku <- unique_skus[i]
        forecast_mean <- as.numeric(forecast_matrix[i, ])
        bounds <- approx_bounds(forecast_mean, series_by_sku[[sku]])
        forecast_dates <- seq(max(agg$date[agg$sku == sku]) + 1, by = "day", length.out = forecast_horizon)
        daily_forecasts[[sku]] <- data.frame(
          sku = sku,
          date = format(forecast_dates, "%Y-%m-%d"),
          forecast = round(forecast_mean, 2),
          lower80 = round(bounds$lower80, 2),
          upper80 = round(bounds$upper80, 2),
          lower95 = round(bounds$lower95, 2),
          upper95 = round(bounds$upper95, 2)
        )
      }
    } else {
      for (sku in unique_skus) {
        series_data <- series_by_sku[[sku]]
        forecast_mean <- forecast_with_model(series_data, model_method, forecast_horizon, seasonality)
        bounds <- approx_bounds(forecast_mean, series_data)
        forecast_dates <- seq(max(agg$date[agg$sku == sku]) + 1, by = "day", length.out = forecast_horizon)
        daily_forecasts[[sku]] <- data.frame(
          sku = sku,
          date = format(forecast_dates, "%Y-%m-%d"),
          forecast = round(forecast_mean, 2),
          lower80 = round(bounds$lower80, 2),
          upper80 = round(bounds$upper80, 2),
          lower95 = round(bounds$lower95, 2),
          upper95 = round(bounds$upper95, 2)
        )
      }
    }

    daily_forecasts_df <- do.call(rbind, daily_forecasts)

    frequency <- if (!is.null(selected_frequency) && selected_frequency != "") selected_frequency else detect_frequency(df$date)
    validation_horizon <- switch(
      frequency,
      daily = 7,
      weekly = 4,
      monthly = 3,
      quarterly = 2,
      yearly = 1,
      7
    )
    forecast_horizon_adj <- if (frequency == "daily") 30 else 12

    # Metadata per SKU
    sku_revenue <- aggregate(revenue ~ sku, data = df, sum, na.rm = TRUE)
    total_revenue <- sum(sku_revenue$revenue, na.rm = TRUE)
    sku_revenue$share <- ifelse(total_revenue > 0, sku_revenue$revenue / total_revenue, 0)
    sku_revenue <- sku_revenue[order(-sku_revenue$share), ]
    sku_revenue$cumshare <- cumsum(sku_revenue$share)

    sku_meta <- list()
    for (i in seq_len(nrow(sku_revenue))) {
      sku <- sku_revenue$sku[i]
      share <- sku_revenue$share[i]
      cumshare <- sku_revenue$cumshare[i]
      abc_class <- if (cumshare <= 0.7) "A" else if (cumshare <= 0.9) "B" else "C"

      locations <- df$location[df$sku == sku]
      store <- if (length(locations) > 0) names(sort(table(locations), decreasing = TRUE))[1] else "Unknown"

      sku_meta[[sku]] <- list(
        store = store,
        skuDesc = paste("SKU", sku),
        forecastMethod = if (model_mode == "global") "POOLED_REGRESSION" else toupper(model_method),
        ABCclass = abc_class,
        ABCpercentage = round(share * 100, 2),
        isApproved = TRUE
      )
    }

    sku_forecast_items <- list()
    model_mode <- resolve_model_mode(selected_mode)
    model_method <- resolve_model_method(selected_model, model_mode)
    seasonality <- get_seasonality(frequency, selected_seasonality)

    period_series_list <- list()
    demand_period_map <- list()

    for (sku in unique_skus) {
      sku_df <- agg[agg$sku == sku, ]
      sku_df <- sku_df[order(sku_df$date), ]
      sku_df$period <- sapply(sku_df$date, period_key, frequency = frequency)
      period_starts <- aggregate(date ~ period, data = transform(sku_df, date = as.Date(sku_df$date)), min)
      demand_period <- aggregate(quantity ~ period, data = sku_df, sum, na.rm = TRUE)
      demand_period <- merge(demand_period, period_starts, by = "period", all.x = TRUE)
      demand_period <- demand_period[order(demand_period$date), ]

      period_series_list[[length(period_series_list) + 1]] <- demand_period$quantity
      demand_period_map[[sku]] <- demand_period
    }

    forecast_matrix <- NULL
    if (model_mode == "global" && length(unique_skus) >= 3) {
      lag <- if (is.list(seasonality)) round(seasonality[[1]] * 1.25) else round(seasonality * 1.25)
      forecast_matrix <- start_forecasting(period_series_list, lag, forecast_horizon_adj, "pooled_regression")
    }

    selected_validation <- if (model_mode == "global") {
      evaluate_global_holdout(period_series_list, seasonality, validation_horizon)
    } else {
      evaluate_local_validation(period_series_list, model_method, seasonality, validation_horizon)
    }
    arima_validation <- evaluate_local_validation(period_series_list, "arima", seasonality, validation_horizon)

    for (i in seq_along(unique_skus)) {
      sku <- unique_skus[i]
      demand_period <- demand_period_map[[sku]]
      series <- demand_period$quantity

      if (model_mode == "global" && !is.null(forecast_matrix)) {
        forecast_mean <- as.numeric(forecast_matrix[i, ])
      } else {
        forecast_mean <- forecast_with_model(series, model_method, forecast_horizon_adj, seasonality)
      }
      bounds <- approx_bounds(forecast_mean, series)

      last_period_date <- tail(demand_period$date, 1)
      future_dates <- sequence_periods(last_period_date, frequency, forecast_horizon_adj)
      forecast_keys <- sapply(future_dates, period_key, frequency = frequency)

      forecast_map <- to_named_map(forecast_keys, round(forecast_mean, 2))
      demand_map <- forecast_map
      lower80_map <- to_named_map(forecast_keys, round(bounds$lower80, 2))
      upper80_map <- to_named_map(forecast_keys, round(bounds$upper80, 2))
      lower95_map <- to_named_map(forecast_keys, round(bounds$lower95, 2))
      upper95_map <- to_named_map(forecast_keys, round(bounds$upper95, 2))

      store <- if (!is.null(sku_meta[[sku]]$store)) sku_meta[[sku]]$store else "Unknown"

      sku_forecast_items[[length(sku_forecast_items) + 1]] <- list(
        sku = sku,
        store = store,
        frequency = frequency,
        periods = forecast_keys,
        demand = demand_map,
        forecastBaseline = forecast_map,
        demandAdjustment = demand_map,
        forecastAdjustment = forecast_map,
        lower80 = lower80_map,
        upper80 = upper80_map,
        lower95 = lower95_map,
        upper95 = upper95_map,
        originalDemand = demand_map,
        originalForecastBaseline = forecast_map,
        model = if (model_mode == "global") "pooled_regression" else model_method
      )
    }

    sku_forecast_values <- list(
      frequency = frequency,
      items = sku_forecast_items
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
    monthly_revenue <- aggregate(revenue ~ month_key, data = transform(agg, month_key = format(date, "%m-%Y")), sum, na.rm = TRUE)
    revenue_map <- setNames(monthly_revenue$revenue, monthly_revenue$month_key)

    monthly_forecasts <- list(
      budget = fill_metric(revenue_map),
      demand = fill_metric(demand_map),
      demandAdjustment = fill_metric(demand_map),
      forecastBaseline = fill_metric(forecast_map),
      forecastAdjustment = fill_metric(forecast_map),
      previousForecasts = fill_metric(forecast_map),
      variance = fill_metric(variance_map),
      revenue = fill_metric(revenue_map)
    )

    # Monthly totals for overview
    total_revenue_value <- round(sum(df$revenue, na.rm = TRUE), 2)
    total_skus <- length(unique_skus)
    locations <- unique(df$location)
    active_accounts <- length(locations)
    month_revenue <- monthly_revenue
    growth_rate <- 0
    if (nrow(month_revenue) >= 2) {
      sorted <- month_revenue[order(month_revenue$month_key), ]
      last <- tail(sorted$revenue, 1)
      prev <- tail(sorted$revenue, 2)[1]
      if (prev != 0) growth_rate <- (last - prev) / prev
    }

    monthly_totals <- list(
      totalRevenue = list(value = total_revenue_value, variance = round(growth_rate, 3), status = calc_status(growth_rate)),
      newCustomers = list(value = total_skus, variance = 0.01, status = "positive"),
      activeAccounts = list(value = active_accounts, variance = 0.0, status = "stable"),
      growthRate = list(value = round(growth_rate * 100, 2), variance = round(growth_rate, 3), status = calc_status(growth_rate))
    )

    default_lead_days <- list(A = 7, B = 14, C = 21)
    default_safety_days <- list(A = 4, B = 6, C = 8)
    default_cover_days <- list(A = 8, B = 14, C = 22)

    replenishment_items <- list()
    for (sku in unique_skus) {
      sku_info <- sku_meta[[sku]]
      abc_class <- if (!is.null(sku_info$ABCclass)) sku_info$ABCclass else "C"
      if (!(abc_class %in% c("A", "B", "C"))) abc_class <- "C"

      forecast_df <- daily_forecasts[[sku]]
      demand_values <- pmax(as.numeric(forecast_df$forecast), 0)
      avg_daily_demand <- if (length(demand_values) > 0) mean(demand_values, na.rm = TRUE) else 0
      horizon_demand <- if (length(demand_values) > 0) sum(demand_values, na.rm = TRUE) else 0

      inventory <- inventory_by_sku[[sku]]
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
        store = if (!is.null(sku_info$store)) sku_info$store else "Unknown",
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

    replenishment_signals <- list(
      generatedAt = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ"),
      horizonDays = forecast_horizon,
      items = replenishment_items
    )

    summary <- list(
      totalSkus = total_skus,
      rows = nrow(df),
      dateStart = format(min(df$date), "%Y-%m-%d"),
      dateEnd = format(max(df$date), "%Y-%m-%d"),
      validation = list(
        frequency = frequency,
        selectedModel = list(
          model = if (model_mode == "global") "pooled_regression" else model_method,
          mode = model_mode,
          strategy = if (!is.null(selected_validation)) selected_validation$strategy else "none",
          horizon = if (!is.null(selected_validation)) selected_validation$horizon else validation_horizon,
          seriesCount = if (!is.null(selected_validation)) selected_validation$seriesCount else 0,
          windows = if (!is.null(selected_validation)) selected_validation$windows else 0,
          metrics = if (!is.null(selected_validation)) selected_validation$metrics else list(mae = NA, rmse = NA, smape = NA)
        ),
        arimaBaseline = list(
          model = "arima",
          mode = "local",
          strategy = if (!is.null(arima_validation)) arima_validation$strategy else "none",
          horizon = if (!is.null(arima_validation)) arima_validation$horizon else validation_horizon,
          seriesCount = if (!is.null(arima_validation)) arima_validation$seriesCount else 0,
          windows = if (!is.null(arima_validation)) arima_validation$windows else 0,
          metrics = if (!is.null(arima_validation)) arima_validation$metrics else list(mae = NA, rmse = NA, smape = NA)
        )
      )
    )

    # Write outputs to S3
    if (is.null(artifact_bucket) || artifact_bucket == "") {
      stop("Missing ARTIFACT_BUCKET environment variable")
    }

    write_json(paste0(s3_output_prefix, "/daily_forecasts.json"), daily_forecasts_df)
    write_json(paste0(s3_output_prefix, "/metadata.json"), sku_meta)
    write_json(paste0(s3_output_prefix, "/monthly_forecasts.json"), monthly_forecasts)
    write_json(paste0(s3_output_prefix, "/monthly_totals.json"), monthly_totals)
    write_json(paste0(s3_output_prefix, "/report_summary.json"), summary)
    write_json(paste0(s3_output_prefix, "/sku_forecast_values.json"), sku_forecast_values)
    write_json(paste0(s3_output_prefix, "/replenishment_signals.json"), replenishment_signals)

    update_run_status(ddb, forecast_runs_table, tenant_id, run_id, "DONE", s3_output_prefix, summary)

    return(list(status = "success", result = summary))
  }, error = function(e) {
    update_run_status(ddb, forecast_runs_table, tenant_id, run_id, "FAILED")
    return(list(status = "error", message = e$message))
  })
}
