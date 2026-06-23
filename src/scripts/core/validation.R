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

summarize_regression_diagnostics <- function(diagnostics_list) {
  if (is.null(diagnostics_list) || length(diagnostics_list) == 0) {
    return(NULL)
  }

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

evaluate_local_validation <- function(series_list, method, seasonality, horizon, xreg_list = NULL, series_metadata = NULL, series_method_plans = NULL, validation_strategy = "auto") {
  actual_all <- c()
  predicted_all <- c()
  windows_used <- 0
  series_used <- 0
  rolling_used <- FALSE
  regression_diagnostics <- list()

  per_series_results <- list()

  for (series_index in seq_along(series_list)) {
    series <- series_list[[series_index]]
    series_info <- if (!is.null(series_metadata) && length(series_metadata) >= series_index) series_metadata[[series_index]] else list()
    series_key <- if (!is.null(series_info$seriesKey)) as.character(series_info$seriesKey) else paste0("series_", series_index)
    sku <- if (!is.null(series_info$sku)) as.character(series_info$sku) else NULL
    store <- if (!is.null(series_info$store)) as.character(series_info$store) else NULL
    series_plan <- if (!is.null(series_method_plans) && length(series_method_plans) >= series_index) series_method_plans[[series_index]] else NULL
    method_to_use <- if (!is.null(series_plan$plannedMethod)) as.character(series_plan$plannedMethod) else method
    n <- length(series)
    if (n < 8) next

    h <- max(1, min(horizon, floor(n / 3)))
    if (n <= (h + 2)) next

    use_rolling <- identical(validation_strategy, "auto") && n >= (h * 3 + 2)
    cutoffs <- c(n - h)
    if (use_rolling) {
      cutoffs <- seq(n - (h * 3), n - h, by = h)
      rolling_used <- TRUE
    }

    series_used <- series_used + 1
    series_actual <- c()
    series_predicted <- c()
    series_windows_used <- 0
    series_regression_diagnostics <- list()
    series_window_results <- list()
    for (cutoff in cutoffs) {
      train <- series[1:cutoff]
      actual <- series[(cutoff + 1):(cutoff + h)]
      if (length(train) < 2 || length(actual) == 0) next
      train_xreg <- NULL
      future_xreg <- NULL
      if (!is.null(xreg_list) && length(xreg_list) >= series_index && !is.null(xreg_list[[series_index]])) {
        xreg_matrix <- as.matrix(xreg_list[[series_index]])
        if (nrow(xreg_matrix) >= (cutoff + h)) {
          train_xreg <- xreg_matrix[1:cutoff, , drop = FALSE]
          future_xreg <- xreg_matrix[(cutoff + 1):(cutoff + h), , drop = FALSE]
        }
      }
      predicted <- forecast_with_model(train, method_to_use, length(actual), seasonality, train_xreg, future_xreg)
      diagnostic <- if (method_to_use == "regression_arima") attr(predicted, "regression_diagnostics") else NULL
      if (!is.null(diagnostic)) {
        diagnostic$seriesKey <- series_key
        diagnostic$sku <- sku
        diagnostic$store <- store
        diagnostic$validationWindow <- series_windows_used + 1
        regression_diagnostics[[length(regression_diagnostics) + 1]] <- diagnostic
        series_regression_diagnostics[[length(series_regression_diagnostics) + 1]] <- diagnostic
      }
      if (length(predicted) != length(actual)) next
      window_metrics <- calculate_validation_metrics(as.numeric(actual), as.numeric(predicted))
      series_window_results[[length(series_window_results) + 1]] <- list(
        window = series_windows_used + 1,
        trainLength = length(train),
        forecastLength = length(actual),
        metrics = window_metrics,
        plannedMethod = method_to_use,
        modelUsed = if (!is.null(diagnostic$modelUsed)) diagnostic$modelUsed else method_to_use,
        fallbackReason = if (!is.null(diagnostic$fallbackReason)) diagnostic$fallbackReason else NULL,
        fitErrorMessage = if (!is.null(diagnostic$fitErrorMessage)) diagnostic$fitErrorMessage else NULL
      )
      actual_all <- c(actual_all, as.numeric(actual))
      predicted_all <- c(predicted_all, as.numeric(predicted))
      series_actual <- c(series_actual, as.numeric(actual))
      series_predicted <- c(series_predicted, as.numeric(predicted))
      windows_used <- windows_used + 1
      series_windows_used <- series_windows_used + 1
    }
    per_series_results[[length(per_series_results) + 1]] <- list(
      seriesKey = series_key,
      sku = sku,
      store = store,
      windows = series_windows_used,
      metrics = calculate_validation_metrics(series_actual, series_predicted),
      plannedMethod = method_to_use,
      routingReason = if (!is.null(series_plan$routingReason)) series_plan$routingReason else NULL,
      planStats = if (!is.null(series_plan$stats)) series_plan$stats else NULL,
      regressionDiagnostics = if (method_to_use == "regression_arima") summarize_regression_diagnostics(series_regression_diagnostics) else NULL,
      windowResults = series_window_results
    )
  }

  metrics <- calculate_validation_metrics(actual_all, predicted_all)
  if (is.null(metrics)) return(NULL)
  list(
    strategy = ifelse(rolling_used, "rolling_window", "holdout"),
    horizon = horizon,
    seriesCount = series_used,
    windows = windows_used,
    metrics = metrics,
    regressionDiagnostics = if (method == "regression_arima") summarize_regression_diagnostics(regression_diagnostics) else NULL,
    perSeries = per_series_results
  )
}

evaluate_global_holdout <- function(series_list, seasonality, horizon, method = "xgboost", series_metadata = NULL) {
  if (length(series_list) < 3) return(NULL)

  lengths <- sapply(series_list, length)
  max_h <- floor(min(lengths) / 3)
  h <- max(1, min(horizon, max_h))
  if (h < 1) return(NULL)

  train_list <- list()
  test_list <- list()
  per_series_meta <- list()
  for (series_index in seq_along(series_list)) {
    series <- series_list[[series_index]]
    n <- length(series)
    if (n <= (h + 2)) next
    train_list[[length(train_list) + 1]] <- series[1:(n - h)]
    test_list[[length(test_list) + 1]] <- series[(n - h + 1):n]
    per_series_meta[[length(per_series_meta) + 1]] <- if (!is.null(series_metadata) && length(series_metadata) >= series_index) series_metadata[[series_index]] else list()
  }
  if (length(train_list) < 3) return(NULL)

  lag <- if (is.list(seasonality)) round(seasonality[[1]] * 1.25) else round(seasonality * 1.25)
  forecast_matrix <- tryCatch({
    start_forecasting(train_list, lag, h, method)
  }, error = function(e) NULL)
  if (is.null(forecast_matrix)) return(NULL)

  usable_rows <- min(nrow(forecast_matrix), length(test_list))
  if (usable_rows == 0) return(NULL)

  forecast_slice <- forecast_matrix[seq_len(usable_rows), seq_len(h), drop = FALSE]
  predicted_all <- as.numeric(c(t(forecast_slice)))
  actual_all <- as.numeric(unlist(test_list[seq_len(usable_rows)], use.names = FALSE))
  per_series_results <- list()
  for (row_index in seq_len(usable_rows)) {
    series_info <- if (length(per_series_meta) >= row_index) per_series_meta[[row_index]] else list()
    actual_series <- as.numeric(test_list[[row_index]])
    predicted_series <- as.numeric(forecast_slice[row_index, seq_len(h)])
    per_series_results[[length(per_series_results) + 1]] <- list(
      seriesKey = if (!is.null(series_info$seriesKey)) as.character(series_info$seriesKey) else paste0("series_", row_index),
      sku = if (!is.null(series_info$sku)) as.character(series_info$sku) else NULL,
      store = if (!is.null(series_info$store)) as.character(series_info$store) else NULL,
      windows = 1,
      metrics = calculate_validation_metrics(actual_series, predicted_series),
      windowResults = list(
        list(
          window = 1,
          trainLength = length(train_list[[row_index]]),
          forecastLength = length(actual_series),
          metrics = calculate_validation_metrics(actual_series, predicted_series),
          plannedMethod = method,
          modelUsed = method,
          fallbackReason = NULL,
          fitErrorMessage = NULL
        )
      )
    )
  }

  metrics <- calculate_validation_metrics(actual_all, predicted_all)
  if (is.null(metrics)) return(NULL)
  list(
    strategy = "holdout",
    horizon = h,
    seriesCount = usable_rows,
    windows = usable_rows,
    metrics = metrics,
    perSeries = per_series_results
  )
}
