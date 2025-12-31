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
#
# ################### FROM AROSHA
#
# run_forecast <- function(input_data) {
#   # Ensure input_data is a named list (from JSON)
#   if (is.null(input_data) || length(input_data) == 0) {
#     stop("No input_data provided")
#   }
#
#   # Convert JSON (list of numeric arrays) into R list 'a'
#   a <- list()
#   idx <- 1
#
#   for (sku in names(input_data)) {
#     values <- input_data[[sku]]
#
#     # Ensure numeric conversion
#     if (!is.numeric(values)) {
#       values <- as.numeric(values)
#     }
#
#     a[[idx]] <- values
#     idx <- idx + 1
#   }
#
#   # Example placeholder: simple forecast output
#   # Replace this with your model logic
#   forecast_result <- lapply(a, function(series) {
#     mean_val <- mean(series, na.rm = TRUE)
#     return(list(
#       length = length(series),
#       mean = mean_val,
#       next_value_estimate = mean_val  # dummy forecast
#     ))
#   })
#
#   # You can return both the processed list and results
#   return(list(
#     input_as_list = a,
#     forecast = forecast_result
#   ))
# }

# ----------------------------------------------------------
# Test forecast generator
# Generates 10 SKUs × 30 random demand points each

# Function	AppSync Resolver Output Shape
# get_skus_metadata_test()	Map<String, SKUMetadata>
# get_sku_forecasts_test()	Map<String, Map<String, Int>>
# get_monthly_totals_test()	Map<String, {value, variance, status}>
# ----------------------------------------------------------

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
