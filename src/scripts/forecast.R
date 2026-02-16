source("/var/task/scripts/utils/error_calculator.R")
source("/var/task/scripts/utils/global_model_helper.R")
source("/var/task/scripts/models/local_univariate_models.R")
source("/var/task/scripts/models/global_models.R")
#
#
SEASONALITY_VALS <- list()
SEASONALITY_VALS[[1]] <- c(21600, 151200, 7889400)
SEASONALITY_VALS[[2]] <- c(1440, 10080, 525960)
SEASONALITY_VALS[[3]] <- c(144, 1008, 52596)
SEASONALITY_VALS[[4]] <- c(96, 672, 35064)
SEASONALITY_VALS[[5]] <- c(48, 336, 17532)
SEASONALITY_VALS[[6]] <- c(24, 168, 8766)
SEASONALITY_VALS[[7]] <- 7
SEASONALITY_VALS[[8]] <- 365.25/7
SEASONALITY_VALS[[9]] <- 12
SEASONALITY_VALS[[10]] <- 4
SEASONALITY_VALS[[11]] <- 1

FREQUENCIES <- c("4_seconds", "minutely", "10_minutes", "15_minutes", "half_hourly", "hourly", "daily", "weekly", "monthly", "quarterly", "yearly")

SEASONALITY_MAP <- list()

for(f in seq_along(FREQUENCIES)){
  SEASONALITY_MAP[[FREQUENCIES[f]]] <- SEASONALITY_VALS[[f]]
}
#
#

suppressPackageStartupMessages({
  library(jsonlite)
  library(forecast)
  library(paws.storage)
  library(lubridate)
})

normalize_columns <- function(df) {
  names(df) <- trimws(tolower(names(df)))
  if ("isle" %in% names(df) && !("aisle" %in% names(df))) {
    names(df)[names(df) == "isle"] <- "aisle"
  }
  df
}

safe_bool <- function(x) {
  value <- tolower(as.character(x))
  value %in% c("true", "1", "yes", "y")
}

calc_status <- function(variance) {
  if (is.na(variance)) return("stable")
  if (variance > 0.05) return("positive")
  if (variance < -0.05) return("negative")
  "stable"
}

detect_frequency <- function(dates) {
  unique_dates <- sort(unique(as.Date(dates)))
  if (length(unique_dates) < 2) return("daily")
  diffs <- diff(unique_dates)
  median_days <- median(as.numeric(diffs))
  if (is.na(median_days) || median_days <= 1) return("daily")
  if (median_days <= 7) return("weekly")
  if (median_days <= 31) return("monthly")
  if (median_days <= 92) return("quarterly")
  "yearly"
}

period_key <- function(date, frequency) {
  d <- as.Date(date)
  if (frequency == "daily") return(format(d, "%Y-%m-%d"))
  if (frequency == "weekly") {
    start <- d - as.integer(format(d, "%u")) + 1
    return(format(start, "%Y-%m-%d"))
  }
  if (frequency == "monthly") return(format(d, "%m-%Y"))
  if (frequency == "quarterly") {
    q <- ((as.integer(format(d, "%m")) - 1) %/% 3) + 1
    return(paste0("Q", q, "-", format(d, "%Y")))
  }
  return(format(d, "%Y"))
}

period_start <- function(date, frequency) {
  d <- as.Date(date)
  if (frequency == "daily") return(d)
  if (frequency == "weekly") return(d - as.integer(format(d, "%u")) + 1)
  if (frequency == "monthly") return(as.Date(format(d, "%Y-%m-01")))
  if (frequency == "quarterly") {
    m <- as.integer(format(d, "%m"))
    q_start <- (m - 1) %/% 3 * 3 + 1
    return(as.Date(paste0(format(d, "%Y"), "-", sprintf("%02d", q_start), "-01")))
  }
  return(as.Date(paste0(format(d, "%Y"), "-01-01")))
}

sequence_periods <- function(last_date, frequency, horizon) {
  if (frequency == "daily") return(seq(last_date + 1, by = "day", length.out = horizon))
  if (frequency == "weekly") return(seq(last_date + 7, by = "7 days", length.out = horizon))
  if (frequency == "monthly") return(seq(last_date %m+% months(1), by = "1 month", length.out = horizon))
  if (frequency == "quarterly") return(seq(last_date %m+% months(3), by = "3 months", length.out = horizon))
  seq(last_date %m+% years(1), by = "1 year", length.out = horizon)
}

to_named_map <- function(keys, values) {
  result <- as.list(values)
  names(result) <- keys
  result
}

get_seasonality <- function(frequency, seasonality_override = NULL) {
  if (!is.null(seasonality_override) && seasonality_override != "auto") {
    if (seasonality_override %in% names(SEASONALITY_MAP)) {
      return(SEASONALITY_MAP[[seasonality_override]])
    }
  }
  if (!is.null(frequency) && frequency %in% names(SEASONALITY_MAP)) {
    return(SEASONALITY_MAP[[frequency]])
  }
  return(1)
}

VALID_LOCAL_MODELS <- c("arima", "ets", "ses", "theta", "tbats", "dhr_arima", "naive", "snaive", "croston")

resolve_model_mode <- function(mode) {
  mode_value <- tolower(ifelse(is.null(mode), "", mode))
  if (mode_value %in% c("local", "global")) return(mode_value)
  "local"
}

resolve_model_method <- function(method, mode = "local") {
  if (mode == "global") return("pooled_regression")
  model_value <- tolower(ifelse(is.null(method), "", method))
  if (model_value %in% VALID_LOCAL_MODELS) return(model_value)
  "arima"
}

get_model_forecast_fn <- function(method) {
  switch(
    method,
    arima = get_arima_forecasts,
    ets = get_ets_forecasts,
    ses = get_ses_forecasts,
    theta = get_theta_forecasts,
    tbats = get_tbats_forecasts,
    dhr_arima = get_dhr_arima_forecasts,
    naive = get_naive_forecasts,
    snaive = get_snaive_forecasts,
    croston = get_croston_forecasts,
    get_arima_forecasts
  )
}

forecast_with_model <- function(series_data, method, forecast_horizon, seasonality) {
  if (length(series_data) < 2) {
    return(rep(0, forecast_horizon))
  }
  series <- forecast:::msts(series_data, seasonal.periods = seasonality)
  forecast_fn <- get_model_forecast_fn(method)
  current_method_forecasts <- forecast_fn(series, forecast_horizon)
  current_method_forecasts[is.na(current_method_forecasts)] <- 0
  as.numeric(current_method_forecasts)
}

calculate_validation_metrics <- function(actual, predicted) {
  if (length(actual) == 0 || length(predicted) == 0 || length(actual) != length(predicted)) {
    return(NULL)
  }
  epsilon <- 0.1
  abs_err <- abs(predicted - actual)
  denom <- pmax(0.5 + epsilon, abs(predicted) + abs(actual) + epsilon)
  smape <- mean((2 * abs_err) / denom, na.rm = TRUE) * 100
  mae <- mean(abs_err, na.rm = TRUE)
  rmse <- sqrt(mean((predicted - actual)^2, na.rm = TRUE))
  list(
    mae = round(mae, 4),
    rmse = round(rmse, 4),
    smape = round(smape, 4)
  )
}

evaluate_local_validation <- function(series_list, method, seasonality, horizon) {
  actual_all <- c()
  predicted_all <- c()
  windows_used <- 0
  series_used <- 0
  rolling_used <- FALSE

  for (series in series_list) {
    n <- length(series)
    if (n < 8) next

    h <- max(1, min(horizon, floor(n / 3)))
    if (n <= (h + 2)) next

    cutoffs <- c(n - h)
    if (n >= (h * 3 + 2)) {
      cutoffs <- seq(n - (h * 3), n - h, by = h)
      rolling_used <- TRUE
    }

    series_used <- series_used + 1
    for (cutoff in cutoffs) {
      train <- series[1:cutoff]
      actual <- series[(cutoff + 1):(cutoff + h)]
      if (length(train) < 2 || length(actual) == 0) next
      predicted <- forecast_with_model(train, method, length(actual), seasonality)
      if (length(predicted) != length(actual)) next
      actual_all <- c(actual_all, as.numeric(actual))
      predicted_all <- c(predicted_all, as.numeric(predicted))
      windows_used <- windows_used + 1
    }
  }

  metrics <- calculate_validation_metrics(actual_all, predicted_all)
  if (is.null(metrics)) return(NULL)
  list(
    strategy = ifelse(rolling_used, "rolling_window", "holdout"),
    horizon = horizon,
    seriesCount = series_used,
    windows = windows_used,
    metrics = metrics
  )
}

evaluate_global_holdout <- function(series_list, seasonality, horizon) {
  if (length(series_list) < 3) return(NULL)

  lengths <- sapply(series_list, length)
  max_h <- floor(min(lengths) / 3)
  h <- max(1, min(horizon, max_h))
  if (h < 1) return(NULL)

  train_list <- list()
  test_list <- list()
  for (series in series_list) {
    n <- length(series)
    if (n <= (h + 2)) next
    train_list[[length(train_list) + 1]] <- series[1:(n - h)]
    test_list[[length(test_list) + 1]] <- series[(n - h + 1):n]
  }
  if (length(train_list) < 3) return(NULL)

  lag <- if (is.list(seasonality)) round(seasonality[[1]] * 1.25) else round(seasonality * 1.25)
  forecast_matrix <- tryCatch({
    start_forecasting(train_list, lag, h, "pooled_regression")
  }, error = function(e) NULL)
  if (is.null(forecast_matrix)) return(NULL)

  usable_rows <- min(nrow(forecast_matrix), length(test_list))
  if (usable_rows == 0) return(NULL)

  forecast_slice <- forecast_matrix[seq_len(usable_rows), seq_len(h), drop = FALSE]
  predicted_all <- as.numeric(c(t(forecast_slice)))
  actual_all <- as.numeric(unlist(test_list[seq_len(usable_rows)], use.names = FALSE))

  metrics <- calculate_validation_metrics(actual_all, predicted_all)
  if (is.null(metrics)) return(NULL)
  list(
    strategy = "holdout",
    horizon = h,
    seriesCount = usable_rows,
    windows = usable_rows,
    metrics = metrics
  )
}

approx_bounds <- function(mean_values, series_data) {
  sigma <- sd(series_data, na.rm = TRUE)
  if (is.na(sigma) || sigma == 0) sigma <- 1
  z80 <- 1.2816
  z95 <- 1.96
  lower80 <- mean_values - z80 * sigma
  upper80 <- mean_values + z80 * sigma
  lower95 <- mean_values - z95 * sigma
  upper95 <- mean_values + z95 * sigma
  list(lower80 = lower80, upper80 = upper80, lower95 = lower95, upper95 = upper95)
}

update_run_status <- function(ddb, table, tenant_id, run_id, status, s3_prefix = NULL, summary = NULL) {
  if (is.null(ddb) || is.null(table) || table == "") {
    message("Skipping DynamoDB status update (DDB not configured)")
    return(invisible(NULL))
  }

  expr_names <- list("#status" = "status")
  expr_values <- list(":status" = list(S = status), ":updatedAt" = list(S = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ")))
  update_expr <- "SET #status = :status, updatedAt = :updatedAt"

  if (!is.null(s3_prefix)) {
    expr_values[[":prefix"]] <- list(S = s3_prefix)
    update_expr <- paste(update_expr, ", s3OutputPrefix = :prefix")
  }

  if (!is.null(summary)) {
    expr_values[[":summary"]] <- list(S = toJSON(summary, auto_unbox = TRUE))
    update_expr <- paste(update_expr, ", summary = :summary")
  }

  ddb$update_item(
    TableName = table,
    Key = list(
      PK = list(S = paste0("TENANT#", tenant_id)),
      SK = list(S = paste0("RUN#", run_id))
    ),
    UpdateExpression = update_expr,
    ExpressionAttributeNames = expr_names,
    ExpressionAttributeValues = expr_values
  )
}

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

      base_files <- c("daily_forecasts.json", "monthly_forecasts.json", "monthly_totals.json", "metadata.json", "report_summary.json")
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

    if (!is.null(selected_sku) && selected_sku != "") {
      df <- df[df$sku == selected_sku, ]
    }
    if (!is.null(selected_store) && selected_store != "") {
      df <- df[df$location == selected_store, ]
    }

    agg <- aggregate(cbind(quantity, revenue) ~ sku + date, data = df, sum, na.rm = TRUE)
    if (nrow(agg) == 0) {
      stop("No usable data after aggregation")
    }

    unique_skus <- sort(unique(agg$sku))
    forecast_horizon <- 30
    daily_forecasts <- list()

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

    update_run_status(ddb, forecast_runs_table, tenant_id, run_id, "DONE", s3_output_prefix, summary)

    return(list(status = "success", result = summary))
  }, error = function(e) {
    update_run_status(ddb, forecast_runs_table, tenant_id, run_id, "FAILED")
    return(list(status = "error", message = e$message))
  })
}
