get_seasonality <- function(frequency, seasonality_override = NULL) {
  if (!is.null(seasonality_override) && seasonality_override != "auto") {
    if (seasonality_override %in% names(SEASONALITY_MAP)) {
      return(SEASONALITY_MAP[[seasonality_override]])
    }
  }
  if (!is.null(frequency) && frequency %in% names(SEASONALITY_MAP)) {
    return(SEASONALITY_MAP[[frequency]])
  }
  1
}

resolve_model_mode <- function(mode) {
  mode_value <- tolower(ifelse(is.null(mode), "", mode))
  if (mode_value %in% c("local", "global")) return(mode_value)
  "local"
}

resolve_model_method <- function(method, mode = "local") {
  if (mode == "global") {
    model_value <- tolower(ifelse(is.null(method), "", method))
    if (model_value %in% VALID_GLOBAL_MODELS) return(model_value)
    return("xgboost")
  }
  model_value <- tolower(ifelse(is.null(method), "", method))
  if (model_value %in% VALID_LOCAL_MODELS) return(model_value)
  "arima"
}


normalize_local_series_xreg <- function(xreg_values) {
  if (is.null(xreg_values)) return(NULL)
  matrix_values <- as.matrix(xreg_values)
  if (is.null(dim(matrix_values))) matrix_values <- matrix(matrix_values, ncol = 1)
  matrix_values <- apply(matrix_values, 2, as.numeric)
  if (is.null(dim(matrix_values))) matrix_values <- matrix(matrix_values, ncol = 1)
  matrix_values
}

plan_local_series_method <- function(requested_method, series_data, xreg_train = NULL) {
  method_value <- resolve_model_method(requested_method, "local")
  base_plan <- list(
    requestedMethod = method_value,
    plannedMethod = method_value,
    routingReason = NULL,
    stats = list(
      length = length(series_data),
      nonPositiveShare = 0,
      zeroShare = 0,
      informativeExternalRegressorCount = 0,
      binaryExternalRegressorCount = 0,
      continuousExternalRegressorCount = 0
    )
  )
  if (method_value != "regression_arima") return(base_plan)

  numeric_series <- as.numeric(series_data)
  numeric_series[!is.finite(numeric_series)] <- 0
  series_length <- length(numeric_series)
  non_positive_share <- if (series_length > 0) mean(numeric_series <= 0, na.rm = TRUE) else 1
  zero_share <- if (series_length > 0) mean(numeric_series == 0, na.rm = TRUE) else 1

  base_plan$stats$length <- series_length
  base_plan$stats$nonPositiveShare <- round(non_positive_share, 4)
  base_plan$stats$zeroShare <- round(zero_share, 4)

  if (series_length < 56) {
    base_plan$plannedMethod <- "arima"
    base_plan$routingReason <- "insufficient_history_for_regression_arima"
    return(base_plan)
  }
  if (non_positive_share > 0.2) {
    base_plan$plannedMethod <- if (zero_share >= 0.5) "croston" else "arima"
    base_plan$routingReason <- "non_positive_target_share_too_high"
    return(base_plan)
  }

  train_matrix <- normalize_local_series_xreg(xreg_train)
  if (is.null(train_matrix) || ncol(train_matrix) == 0 || nrow(train_matrix) != series_length) {
    base_plan$plannedMethod <- "arima"
    base_plan$routingReason <- "missing_or_invalid_regressors"
    return(base_plan)
  }

  column_names <- colnames(train_matrix)
  if (is.null(column_names)) column_names <- paste0("xreg_", seq_len(ncol(train_matrix)))
  colnames(train_matrix) <- column_names
  external_columns <- setdiff(column_names, c("trend", grep("^dow_", column_names, value = TRUE)))
  if (length(external_columns) == 0) {
    base_plan$plannedMethod <- "arima"
    base_plan$routingReason <- "no_external_regressors"
    return(base_plan)
  }

  informative_external_count <- 0
  binary_external_count <- 0
  continuous_external_count <- 0
  for (column_name in external_columns) {
    column_values <- as.numeric(train_matrix[, column_name])
    column_values <- column_values[is.finite(column_values)]
    if (length(column_values) <= 1) next
    unique_values <- sort(unique(column_values))
    if (length(unique_values) <= 1) next
    is_binary_like <- length(unique_values) <= 2 && all(unique_values %in% c(0, 1))
    if (is_binary_like) {
      active_share <- mean(column_values > 0, na.rm = TRUE)
      if (active_share >= 0.02 && active_share <= 0.98) {
        informative_external_count <- informative_external_count + 1
        binary_external_count <- binary_external_count + 1
      }
      next
    }
    if (stats::sd(column_values, na.rm = TRUE) > 0 && length(unique_values) >= 8) {
      informative_external_count <- informative_external_count + 1
      continuous_external_count <- continuous_external_count + 1
    }
  }

  base_plan$stats$informativeExternalRegressorCount <- informative_external_count
  base_plan$stats$binaryExternalRegressorCount <- binary_external_count
  base_plan$stats$continuousExternalRegressorCount <- continuous_external_count

  if (informative_external_count == 0) {
    base_plan$plannedMethod <- if (zero_share >= 0.5) "croston" else "arima"
    base_plan$routingReason <- "no_informative_external_regressors"
    return(base_plan)
  }
  if (continuous_external_count == 0 && binary_external_count < 2) {
    base_plan$plannedMethod <- "arima"
    base_plan$routingReason <- "insufficient_external_regressor_signal"
    return(base_plan)
  }
  if ((series_length / max(1, informative_external_count)) < 25) {
    base_plan$plannedMethod <- "arima"
    base_plan$routingReason <- "low_history_to_regressor_ratio"
    return(base_plan)
  }

  base_plan
}

get_model_forecast_fn <- function(method) {
  switch(
    method,
    arima = get_arima_forecasts,
    regression_arima = get_regression_arima_forecasts,
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

forecast_with_model <- function(series_data, method, forecast_horizon, seasonality, xreg_train = NULL, xreg_future = NULL) {
  if (length(series_data) < 2) {
    return(rep(0, forecast_horizon))
  }
  series <- forecast:::msts(series_data, seasonal.periods = seasonality)
  forecast_fn <- get_model_forecast_fn(method)
  current_method_forecasts <- tryCatch({
    setTimeLimit(cpu = Inf, elapsed = 20, transient = TRUE)
    on.exit(setTimeLimit(cpu = Inf, elapsed = Inf, transient = TRUE), add = TRUE)
    if (method == "regression_arima") {
      forecast_fn(series, forecast_horizon, xreg_train, xreg_future)
    } else {
      forecast_fn(series, forecast_horizon)
    }
  }, error = function(e) {
    fallback_reason <- if (grepl("time limit", as.character(e$message), ignore.case = TRUE)) "model_timeout" else "model_execution_failed"
    if (method == "regression_arima") {
      fallback_values <- get_arima_forecasts(series, forecast_horizon)
      attr(fallback_values, "regression_diagnostics") <- list(
        modelUsed = "arima_fallback",
        fallbackReason = fallback_reason,
        fitErrorMessage = as.character(e$message),
        requestedColumns = if (!is.null(xreg_train)) colnames(as.matrix(xreg_train)) else character(0),
        usedColumns = character(0),
        retainedColumns = character(0),
        droppedByModelColumns = character(0),
        droppedNonFiniteColumns = character(0),
        droppedConstantColumns = character(0),
        droppedDependentColumns = character(0)
      )
      return(fallback_values)
    }
    warning(e)
    get_snaive_forecasts(series, forecast_horizon)
  })
  regression_diagnostics <- attr(current_method_forecasts, "regression_diagnostics")
  current_method_forecasts[is.na(current_method_forecasts)] <- 0
  current_method_forecasts <- as.numeric(current_method_forecasts)
  if (!is.null(regression_diagnostics)) {
    attr(current_method_forecasts, "regression_diagnostics") <- regression_diagnostics
  }
  current_method_forecasts
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
