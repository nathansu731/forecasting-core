# source("/var/task/scripts/utils/error_calculator.R")
# source("/var/task/scripts/utils/global_model_helper.R")
# source("/var/task/scripts/models/local_univariate_models.R")
# source("/var/task/scripts/models/global_models.R")
#
#
# # Seasonality values corresponding with the frequencies: 4_seconds, minutely, 10_minutes, 15_minutes, half_hourly, hourly, daily, weekly, monthly, quarterly and yearly
# # Consider multiple seasonalities for frequencies less than daily
# SEASONALITY_VALS <- list()
# SEASONALITY_VALS[[1]] <- c(21600, 151200, 7889400)
# SEASONALITY_VALS[[2]] <- c(1440, 10080, 525960)
# SEASONALITY_VALS[[3]] <- c(144, 1008, 52596)
# SEASONALITY_VALS[[4]] <- c(96, 672, 35064)
# SEASONALITY_VALS[[5]] <- c(48, 336, 17532)
# SEASONALITY_VALS[[6]] <- c(24, 168, 8766)
# SEASONALITY_VALS[[7]] <- 7
# SEASONALITY_VALS[[8]] <- 365.25/7
# SEASONALITY_VALS[[9]] <- 12
# SEASONALITY_VALS[[10]] <- 4
# SEASONALITY_VALS[[11]] <- 1
#
# FREQUENCIES <- c("4_seconds", "minutely", "10_minutes", "15_minutes", "half_hourly", "hourly", "daily", "weekly", "monthly", "quarterly", "yearly")
#
# SEASONALITY_MAP <- list()
#
# for(f in seq_along(FREQUENCIES)){
#   SEASONALITY_MAP[[FREQUENCIES[f]]] <- SEASONALITY_VALS[[f]]
# }
#
#
# # This function performs the fixed horizon evaluation with local models.
# do_local_forecasting <- function(dataset, dataset_name, method, forecast_horizon, frequency){
#
#   if(!is.null(frequency))
#     seasonality <- SEASONALITY_MAP[[frequency]]
#   else
#     seasonality <- 1
#
#   train_series_list <- list()
#   actual_matrix <- matrix(NA, nrow = length(dataset), ncol = forecast_horizon)
#
#   start_time <- Sys.time()
#   print("started Forecasting")
#
#   dir.create(file.path("results", "forecasts", fsep = "/"), showWarnings = FALSE, recursive=TRUE)
#
#   for(s in 1:length(dataset)){
#     print(s)
#     series_data <- as.numeric(unlist(dataset[s], use.names = FALSE))
#
#     if(length(series_data) < forecast_horizon)
#       forecast_horizon <- 1
#
#     train_series_list[[s]] <- series_data[1:(length(series_data) - forecast_horizon)]
#     actual_matrix[s,] <- series_data[(length(series_data) - forecast_horizon + 1):length(series_data)]
#
#     series <- forecast:::msts(train_series_list[[s]], seasonal.periods = seasonality)
#
#     # Forecasting
#     current_method_forecasts <- eval(parse(text = paste0("get_", method, "_forecasts(series, forecast_horizon)")))
#     current_method_forecasts[is.na(current_method_forecasts)] <- 0
#     write.table(t(current_method_forecasts), file.path("results", "forecasts", paste0(dataset_name, "_", method, ".txt"), fsep = "/"), row.names = FALSE, col.names = FALSE, sep = ",", quote = FALSE, append = TRUE)
#   }
#
#   end_time <- Sys.time()
#   print("Finished Forecasting")
#
#   # Execution time
#   exec_time <- end_time - start_time
#   print(exec_time)
#
#   # Error calculations
#   dir.create(file.path("results", "errors", fsep = "/"), showWarnings = FALSE, recursive=TRUE)
#
#   forecast_matrix <- as.matrix(read.csv(file.path("results", "forecasts", paste0(dataset_name, "_", method, ".txt"), fsep = "/"), header = F))
#   calculate_errors(forecast_matrix, actual_matrix, file.path("results", "errors", paste0(dataset_name, "_", method), fsep = "/"))
# }
#
#
# # This function performs the fixed horizon evaluation with global models.
# do_global_forecasting <- function(dataset, dataset_name, method, forecast_horizon, lag, frequency){
#
#   if(!is.null(frequency))
#     seasonality <- SEASONALITY_MAP[[frequency]]
#   else
#     seasonality <- 1
#
#   if(is.null(lag))
#     lag <- round(seasonality[1]*1.25)
#
#   start_time <- Sys.time()
#   print("started Forecasting")
#
#   train_series_list <- list()
#   actual_matrix <- matrix(NA, nrow = length(dataset), ncol = forecast_horizon)
#
#   for(s in 1:length(dataset)){
#     print(s)
#     series_data <- as.numeric(unlist(dataset[s], use.names = FALSE))
#
#     train_series_list[[s]] <- series_data[1:(length(series_data) - forecast_horizon)]
#     actual_matrix[s,] <- series_data[(length(series_data) - forecast_horizon + 1):length(series_data)]
#   }
#
#   # Forecasting
#   forecast_matrix <- start_forecasting(train_series_list, lag, forecast_horizon, method)
#   forecast_matrix[is.na(forecast_matrix)] <- 0
#
#   dir.create(file.path("results", "forecasts", fsep = "/"), showWarnings = FALSE, recursive=TRUE)
#   write.table(forecast_matrix, file.path("results", "forecasts", paste0(dataset_name, "_", method, ".txt"), fsep = "/"), row.names = FALSE, col.names = FALSE, sep = ",", quote = FALSE, append = TRUE)
#
#   end_time <- Sys.time()
#   print("Finished Forecasting")
#
#   # Execution time
#   exec_time <- end_time - start_time
#   print(exec_time)
#
#   # Error calculations
#   dir.create(file.path("results", "errors", fsep = "/"), showWarnings = FALSE, recursive=TRUE)
#   calculate_errors(as.matrix(forecast_matrix), actual_matrix, file.path(BASE_DIR, "results", "errors", paste0(dataset_name, "_", method), fsep = "/"))
# }

#####################  FROM AROSHA

run_forecast_test <- function(input_data) {
  message("TEST Forecasting: ", toJSON(input_data, auto_unbox = TRUE))
  set.seed(123) # reproducible random output

  skus <- paste0("SKU_", sprintf("%02d", 1:10))
  days <- 30

  df <- data.frame(
    sku = rep(skus, each = days),
    day = rep(1:days, times = length(skus)),
    demand = rpois(days * length(skus), lambda = 20) # random demand ~ 20 avg
  )

  return(df)
}

get_skus_metadata_test <- function() {
  set.seed(123)

  skus <- paste0("SKU_", sprintf("%02d", 1:10))
  stores <- c("Melbourne", "Sydney", "Brisbane")
  forecast_methods <- c("ARIMA", "ETS", "Prophet")
  abc_classes <- c("A", "B", "C")

  metadata <- lapply(skus, function(sku) {
    abc_class <- sample(abc_classes, 1)
    abc_pct <- if (abc_class == "A") runif(1, 70, 80)
    else if (abc_class == "B") runif(1, 15, 25)
    else runif(1, 5, 10)

    list(
      store = sample(stores, 1),
      skuDesc = paste("Description for", sku),
      forecastMethod = sample(forecast_methods, 1),
      ABCclass = abc_class,
      ABCpercentage = round(abc_pct, 2),
      isApproved = sample(c(TRUE, FALSE), 1)
    )
  })

  names(metadata) <- skus
  return(metadata)
}

get_report_summary_test <- function() {
  set.seed(321)

  report_ids <- paste0("report_", sprintf("%02d", 1:100))
  dates <- seq(as.Date("2024-01-01"), by = "7 days", length.out = length(report_ids))
  regions <- c("North America", "Europe", "APAC", "LATAM")
  products <- c("Product A", "Product B", "Product C", "Product D")
  methods <- c("ARIMA", "ETS", "Prophet", "XGBoost")
  statuses <- c("Completed", "In Progress", "Delayed")

  reports <- lapply(seq_along(report_ids), function(i) {
    revenue_value <- sample(seq(50000, 500000, by = 1000), 1)
    list(
      date = format(dates[i], "%Y-%m-%d"),
      region = sample(regions, 1),
      product = sample(products, 1),
      revenue = paste0("$", formatC(revenue_value, format = "d", big.mark = ",")),
      forecast_method = sample(methods, 1),
      accuracy = paste0(formatC(runif(1, 85, 99), format = "f", digits = 1), "%"),
      status = sample(statuses, 1),
      variance = round(runif(1, -5, 5), 1)
    )
  })

  names(reports) <- report_ids
  return(reports)
}

get_sku_forecasts_test <- function() {
  set.seed(456)

  metrics <- c(
    "budget",
    "demand",
    "demandAdjustment",
    "forecastBaseline",
    "forecastAdjustment",
    "previousForecasts",
    "variance",
    "revenue",
    "accuracy",
    "error",
    "biasPercent",
    "bias"
  )

  months <- format(
    seq(
      as.Date("2025-01-01"),
      by = "month",
      length.out = 12
    ),
    "%m-%Y"
  )

  # reverse to match 12-2025 → 01-2025
  months <- rev(months)

  metric_data <- lapply(metrics, function(metric) {
    values <- sample(-1000:9999, length(months), replace = TRUE)
    names(values) <- months
    values_list <- as.list(values)
    values_list$average <- round(mean(values), 2)
    values_list
  })

  names(metric_data) <- metrics
  return(metric_data)
}

get_monthly_totals_test <- function() {
  set.seed(789)

  metrics <- c(
    "totalRevenue",
    "newCustomers",
    "activeAccounts",
    "growthRate",
    "operatingExpenses",
    "netIncome",
    "grossMargin",
    "ebitda",
    "cashFlow",
    "marketShare",
    "customerAcquisition",
    "totalSKUs",
    "forecastAccuracy",
    "OutOfStockRisk",
    "AvgLeadTime"
  )

  totals <- lapply(metrics, function(metric) {
    value <- round(runif(1, 10000, 500000), 2)
    variance <- round(runif(1, -0.3, 0.3), 3)

    status <- if (variance > 0.05) {
      "positive"
    } else if (variance < -0.05) {
      "negative"
    } else {
      "stable"
    }

    list(
      value = value,
      variance = variance,
      status = status
    )
  })

  names(totals) <- metrics
  return(totals)
}



##################### / FROM AROSHA

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

  if (is.null(tenant_id) || is.null(run_id) || is.null(s3_bucket) || is.null(s3_key)) {
    return(list(status = "error", message = "missing_inputs"))
  }

  message("Forecast run env: raw_bucket=", raw_bucket, " artifact_bucket=", artifact_bucket, " forecast_runs_table=", forecast_runs_table)
  message("Forecast run input: tenant_id=", tenant_id, " run_id=", run_id, " s3_bucket=", s3_bucket, " s3_key=", s3_key, " output_prefix=", s3_output_prefix, " adjustments_key=", adjustments_key)

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

    agg <- aggregate(cbind(quantity, revenue) ~ sku + date, data = df, sum, na.rm = TRUE)
    if (nrow(agg) == 0) {
      stop("No usable data after aggregation")
    }

    unique_skus <- sort(unique(agg$sku))
    forecast_horizon <- 30
    daily_forecasts <- list()

    for (sku in unique_skus) {
      sku_df <- agg[agg$sku == sku, ]
      sku_df <- sku_df[order(sku_df$date), ]
      full_dates <- seq(min(sku_df$date), max(sku_df$date), by = "day")
      series <- merge(data.frame(date = full_dates), sku_df, by = "date", all.x = TRUE)
      series$quantity[is.na(series$quantity)] <- 0

      ts_data <- ts(series$quantity, frequency = 7)
      forecast_mean <- rep(mean(series$quantity, na.rm = TRUE), forecast_horizon)
      lower_80 <- rep(min(series$quantity, na.rm = TRUE), forecast_horizon)
      upper_80 <- rep(max(series$quantity, na.rm = TRUE), forecast_horizon)
      lower_95 <- lower_80
      upper_95 <- upper_80

      fit <- tryCatch({
        forecast::auto.arima(ts_data)
      }, error = function(e) NULL)

      if (!is.null(fit)) {
        fc <- forecast::forecast(fit, h = forecast_horizon, level = c(80, 95))
        forecast_mean <- as.numeric(fc$mean)
        lower_80 <- as.numeric(fc$lower[, 1])
        upper_80 <- as.numeric(fc$upper[, 1])
        lower_95 <- as.numeric(fc$lower[, 2])
        upper_95 <- as.numeric(fc$upper[, 2])
      }

      forecast_dates <- seq(max(series$date) + 1, by = "day", length.out = forecast_horizon)
      daily_forecasts[[sku]] <- data.frame(
        sku = sku,
        date = format(forecast_dates, "%Y-%m-%d"),
        forecast = round(forecast_mean, 2),
        lower80 = round(lower_80, 2),
        upper80 = round(upper_80, 2),
        lower95 = round(lower_95, 2),
        upper95 = round(upper_95, 2)
      )
    }

    daily_forecasts_df <- do.call(rbind, daily_forecasts)

    frequency <- if (!is.null(selected_frequency) && selected_frequency != "") selected_frequency else detect_frequency(df$date)
    freq_value <- switch(
      frequency,
      daily = 7,
      weekly = 52,
      monthly = 12,
      quarterly = 4,
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
        forecastMethod = "ARIMA",
        ABCclass = abc_class,
        ABCpercentage = round(share * 100, 2),
        isApproved = TRUE
      )
    }

    sku_forecast_items <- list()
    for (sku in unique_skus) {
      sku_df <- agg[agg$sku == sku, ]
      sku_df <- sku_df[order(sku_df$date), ]
      sku_df$period <- sapply(sku_df$date, period_key, frequency = frequency)
      period_starts <- aggregate(date ~ period, data = transform(sku_df, date = as.Date(sku_df$date)), min)
      demand_period <- aggregate(quantity ~ period, data = sku_df, sum, na.rm = TRUE)
      demand_period <- merge(demand_period, period_starts, by = "period", all.x = TRUE)
      demand_period <- demand_period[order(demand_period$date), ]

      series <- demand_period$quantity
      ts_data <- ts(series, frequency = freq_value)
      forecast_mean <- rep(mean(series, na.rm = TRUE), forecast_horizon_adj)
      lower_80 <- rep(min(series, na.rm = TRUE), forecast_horizon_adj)
      upper_80 <- rep(max(series, na.rm = TRUE), forecast_horizon_adj)
      lower_95 <- lower_80
      upper_95 <- upper_80

      fit <- tryCatch({
        forecast::auto.arima(ts_data)
      }, error = function(e) NULL)

      if (!is.null(fit)) {
        fc <- forecast::forecast(fit, h = forecast_horizon_adj, level = c(80, 95))
        forecast_mean <- as.numeric(fc$mean)
        lower_80 <- as.numeric(fc$lower[, 1])
        upper_80 <- as.numeric(fc$upper[, 1])
        lower_95 <- as.numeric(fc$lower[, 2])
        upper_95 <- as.numeric(fc$upper[, 2])
      }

      last_period_date <- tail(demand_period$date, 1)
      future_dates <- sequence_periods(last_period_date, frequency, forecast_horizon_adj)
      forecast_keys <- sapply(future_dates, period_key, frequency = frequency)

      forecast_map <- to_named_map(forecast_keys, round(forecast_mean, 2))
      demand_map <- forecast_map
      lower80_map <- to_named_map(forecast_keys, round(lower_80, 2))
      upper80_map <- to_named_map(forecast_keys, round(upper_80, 2))
      lower95_map <- to_named_map(forecast_keys, round(lower_95, 2))
      upper95_map <- to_named_map(forecast_keys, round(upper_95, 2))

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
        originalForecastBaseline = forecast_map
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
      dateEnd = format(max(df$date), "%Y-%m-%d")
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
