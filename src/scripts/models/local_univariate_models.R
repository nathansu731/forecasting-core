# Implementations of a set of univariate forecasting models
#
# Each function takes 2 parameters
# time_series - a ts object representing the time series that should be used with model training
# forecast_horizon - expected forecast horizon
#
# If a model fails to provide forecasts, it will return snaive forecasts

fit_auto_arima_safe <- function(time_series, xreg = NULL, use_lambda = TRUE, seasonal = TRUE) {
  time_series <- as.numeric(time_series)
  time_series[!is.finite(time_series)] <- 0
  series_length <- length(time_series)
  # Local Lambda runs need a cheaper ARIMA search when xreg is present or the
  # history is long enough to make exact search expensive.
  use_approximation <- !is.null(xreg) || series_length >= 90
  args <- list(
    y = time_series,
    seasonal = seasonal,
    seasonal.test = "ocsb",
    stepwise = TRUE,
    approximation = use_approximation
  )
  if (!is.null(xreg)) {
    args$xreg <- xreg
  }
  if (isTRUE(use_approximation) && series_length > 180) {
    args$truncate <- 180
  }
  if (isTRUE(use_lambda) && all(is.finite(time_series)) && all(time_series > 0)) {
    args$lambda <- 0
  }
  do.call(forecast:::auto.arima, args)
}


# Calculate ets forecasts
get_ets_forecasts <- function(time_series, forecast_horizon){
  tryCatch(
    forecast(forecast:::ets(time_series), h = forecast_horizon)$mean
    ,error = function(e) {
      warning(e)
      get_snaive_forecasts(time_series, forecast_horizon)
    })
}


# Calculate simple exponential smoothing forecasts
get_ses_forecasts <- function(time_series, forecast_horizon){
  tryCatch(
    forecast(forecast:::ses(time_series, h = forecast_horizon))$mean
    , error = function(e) {   
      warning(e)
      get_snaive_forecasts(time_series, forecast_horizon)
    })
}


# Calculate theta forecasts
get_theta_forecasts <-function(time_series, forecast_horizon){
  tryCatch(
    forecast:::thetaf(y = time_series, h = forecast_horizon)$mean
    , error = function(e) {   
      warning(e)
      get_snaive_forecasts(time_series, forecast_horizon)
    })
}


# Calculate auto.arima forecasts
get_arima_forecasts <- function(time_series, forecast_horizon){
  tryCatch({
    fit <- fit_auto_arima_safe(time_series, use_lambda = TRUE, seasonal = TRUE)
  }, error = function(e) {
    tryCatch({
      fit <<- fit_auto_arima_safe(time_series, use_lambda = FALSE, seasonal = TRUE)
    }, error = function(e){
      fit <<- fit_auto_arima_safe(time_series, use_lambda = FALSE, seasonal = FALSE)
    })
  })
    
  tryCatch({
    forecast:::forecast.Arima(fit, h = forecast_horizon)$mean
  }, error = function(e) { 
    warning(e)
    get_snaive_forecasts(time_series, forecast_horizon)
  })
}


# Calculate regression arima forecasts
get_regression_arima_forecasts <- function(time_series, forecast_horizon, xreg_train = NULL, xreg_future = NULL){
  annotate_regression_forecast <- function(values, diagnostic) {
    numeric_values <- as.numeric(values)
    attr(numeric_values, "regression_diagnostics") <- diagnostic
    numeric_values
  }
  base_diagnostic <- function(...) {
    modifyList(
      list(
        requestedColumns = character(0),
        usedColumns = character(0),
        retainedColumns = character(0),
        droppedByModelColumns = character(0),
        droppedNonFiniteColumns = character(0),
        droppedConstantColumns = character(0),
        droppedDependentColumns = character(0),
        fitErrorMessage = NULL
      ),
      list(...)
    )
  }

  if (is.null(xreg_train) || is.null(xreg_future)) {
    return(annotate_regression_forecast(
      get_arima_forecasts(time_series, forecast_horizon),
      base_diagnostic(
        modelUsed = "arima_fallback",
        fallbackReason = "missing_xreg"
      )
    ))
  }

  train_matrix <- as.matrix(xreg_train)
  future_matrix <- as.matrix(xreg_future)
  if (nrow(train_matrix) != length(time_series) || nrow(future_matrix) != forecast_horizon || ncol(train_matrix) == 0) {
    return(annotate_regression_forecast(
      get_arima_forecasts(time_series, forecast_horizon),
      base_diagnostic(
        modelUsed = "arima_fallback",
        fallbackReason = "invalid_xreg_dimensions",
        requestedColumns = colnames(train_matrix)
      )
    ))
  }

  original_column_names <- colnames(train_matrix)
  if (is.null(original_column_names) || length(original_column_names) != ncol(train_matrix)) {
    original_column_names <- paste0("xreg_", seq_len(ncol(train_matrix)))
  }

  sanitize_xreg_matrix <- function(matrix_values, reference_values = NULL) {
    matrix_values <- apply(matrix_values, 2, as.numeric)
    if (is.null(dim(matrix_values))) matrix_values <- matrix(matrix_values, ncol = 1)
    for (column_index in seq_len(ncol(matrix_values))) {
      column_values <- matrix_values[, column_index]
      if (all(is.finite(column_values))) next
      reference_column <- if (!is.null(reference_values) && ncol(reference_values) >= column_index) reference_values[, column_index] else column_values
      replacement_candidates <- reference_column[is.finite(reference_column)]
      replacement_value <- if (length(replacement_candidates) > 0) stats::median(replacement_candidates) else 0
      column_values[!is.finite(column_values)] <- replacement_value
      matrix_values[, column_index] <- column_values
    }
    matrix_values
  }

  train_matrix <- sanitize_xreg_matrix(train_matrix)
  future_matrix <- sanitize_xreg_matrix(future_matrix, train_matrix)
  if (is.null(dim(train_matrix))) train_matrix <- matrix(train_matrix, ncol = 1)
  if (is.null(dim(future_matrix))) future_matrix <- matrix(future_matrix, ncol = 1)
  colnames(train_matrix) <- original_column_names
  colnames(future_matrix) <- colnames(train_matrix)

  dropped_non_finite <- character(0)
  finite_columns <- apply(train_matrix, 2, function(column) all(is.finite(column)))
  if (!all(finite_columns)) {
    dropped_non_finite <- colnames(train_matrix)[!finite_columns]
    train_matrix <- train_matrix[, finite_columns, drop = FALSE]
    future_matrix <- future_matrix[, finite_columns, drop = FALSE]
  }
  if (ncol(train_matrix) == 0) {
    return(annotate_regression_forecast(
      get_arima_forecasts(time_series, forecast_horizon),
      base_diagnostic(
        modelUsed = "arima_fallback",
        fallbackReason = "no_finite_xreg_columns",
        requestedColumns = original_column_names,
        droppedNonFiniteColumns = dropped_non_finite
      )
    ))
  }

  dropped_constant <- character(0)
  variable_columns <- apply(train_matrix, 2, function(column) {
    values <- column[is.finite(column)]
    length(values) > 1 && sd(values) > 0
  })
  if (!all(variable_columns)) {
    dropped_constant <- colnames(train_matrix)[!variable_columns]
    train_matrix <- train_matrix[, variable_columns, drop = FALSE]
    future_matrix <- future_matrix[, variable_columns, drop = FALSE]
  }
  if (ncol(train_matrix) == 0) {
    return(annotate_regression_forecast(
      get_arima_forecasts(time_series, forecast_horizon),
      base_diagnostic(
        modelUsed = "arima_fallback",
        fallbackReason = "no_variable_xreg_columns",
        requestedColumns = original_column_names,
        droppedNonFiniteColumns = dropped_non_finite,
        droppedConstantColumns = dropped_constant
      )
    ))
  }

  dropped_dependent <- character(0)
  matrix_rank <- qr(train_matrix)
  if (matrix_rank$rank < ncol(train_matrix)) {
    keep_indices <- sort(matrix_rank$pivot[seq_len(matrix_rank$rank)])
    dropped_dependent <- colnames(train_matrix)[setdiff(seq_len(ncol(train_matrix)), keep_indices)]
    train_matrix <- train_matrix[, keep_indices, drop = FALSE]
    future_matrix <- future_matrix[, keep_indices, drop = FALSE]
  }
  if (ncol(train_matrix) == 0) {
    return(annotate_regression_forecast(
      get_arima_forecasts(time_series, forecast_horizon),
      base_diagnostic(
        modelUsed = "arima_fallback",
        fallbackReason = "no_ranked_xreg_columns",
        requestedColumns = original_column_names,
        droppedNonFiniteColumns = dropped_non_finite,
        droppedConstantColumns = dropped_constant,
        droppedDependentColumns = dropped_dependent
      )
    ))
  }

  fit_error_message <- NULL
  fit <- tryCatch(
    fit_auto_arima_safe(time_series, xreg = train_matrix, use_lambda = TRUE, seasonal = TRUE),
    error = function(primary_error) {
      fit_error_message <<- as.character(primary_error$message)
      tryCatch(
        fit_auto_arima_safe(time_series, xreg = train_matrix, use_lambda = FALSE, seasonal = TRUE),
        error = function(secondary_error) {
          fit_error_message <<- paste(fit_error_message, as.character(secondary_error$message), sep = " | ")
          tryCatch(
            fit_auto_arima_safe(time_series, xreg = train_matrix, use_lambda = FALSE, seasonal = FALSE),
            error = function(final_error) {
              fit_error_message <<- paste(fit_error_message, as.character(final_error$message), sep = " | ")
              NULL
            }
          )
        }
      )
    }
  )
  if (is.null(fit)) {
    return(annotate_regression_forecast(
      get_arima_forecasts(time_series, forecast_horizon),
      base_diagnostic(
        modelUsed = "arima_fallback",
        fallbackReason = "arimax_fit_failed",
        requestedColumns = original_column_names,
        usedColumns = colnames(train_matrix),
        fitErrorMessage = fit_error_message,
        droppedNonFiniteColumns = dropped_non_finite,
        droppedConstantColumns = dropped_constant,
        droppedDependentColumns = dropped_dependent
      )
    ))
  }

  retained_columns <- intersect(colnames(train_matrix), names(fit$coef))
  dropped_by_model <- setdiff(colnames(train_matrix), retained_columns)
  fit_requires_xreg <- length(retained_columns) > 0

  tryCatch({
    forecast_values <- if (fit_requires_xreg) {
      forecast:::forecast.Arima(fit, h = forecast_horizon, xreg = future_matrix)$mean
    } else {
      forecast:::forecast.Arima(fit, h = forecast_horizon)$mean
    }
    annotate_regression_forecast(
      forecast_values,
      base_diagnostic(
        modelUsed = if (fit_requires_xreg) "regression_arima" else "arima_no_regressors_retained",
        fallbackReason = if (fit_requires_xreg) NULL else "no_regressors_retained_by_model",
        requestedColumns = original_column_names,
        usedColumns = colnames(train_matrix),
        retainedColumns = retained_columns,
        droppedByModelColumns = dropped_by_model,
        droppedNonFiniteColumns = dropped_non_finite,
        droppedConstantColumns = dropped_constant,
        droppedDependentColumns = dropped_dependent
      )
    )
  }, error = function(e) {
    warning(e)
    annotate_regression_forecast(
      get_arima_forecasts(time_series, forecast_horizon),
      base_diagnostic(
        modelUsed = "arima_fallback",
        fallbackReason = "forecast_with_xreg_failed",
        requestedColumns = original_column_names,
        usedColumns = colnames(train_matrix),
        retainedColumns = retained_columns,
        droppedByModelColumns = dropped_by_model,
        fitErrorMessage = as.character(e$message),
        droppedNonFiniteColumns = dropped_non_finite,
        droppedConstantColumns = dropped_constant,
        droppedDependentColumns = dropped_dependent
      )
    )
  })
}


# Calculate tbats forecasts
get_tbats_forecasts <- function(time_series, forecast_horizon){
  tryCatch(
    forecast(forecast:::tbats(time_series), h = forecast_horizon)$mean
    , error = function(e) {   
      warning(e)
      get_snaive_forecasts(time_series, forecast_horizon)
    })
}


# Calculate dynamic harmonic regression arima forecasts
get_dhr_arima_forecasts <- function(time_series, forecast_horizon){
  tryCatch({
    xreg <- forecast:::fourier(time_series, K = 1)
    model <- forecast:::auto.arima(time_series, xreg = xreg, seasonal = FALSE)
    xreg1 <- forecast:::fourier(time_series, K = 1, h = forecast_horizon)
    forecast(model, xreg = xreg1)$mean
  }, error = function(e) {   
    warning(e)
    get_snaive_forecasts(time_series, forecast_horizon)
  })
}


# Calculate snaive forecasts
get_snaive_forecasts <- function(time_series, forecast_horizon){
  forecast:::snaive(time_series, h = forecast_horizon)$mean
}


# Calculate naive forecasts
get_naive_forecasts <- function(time_series, forecast_horizon){
  forecast:::naive(time_series, h = forecast_horizon)$mean
}


# Calculate croston forecasts
get_croston_forecasts <- function(time_series, forecast_horizon){
  tryCatch(
    forecast(forecast:::croston(time_series, h = forecast_horizon))$mean
    , error = function(e) {   
      warning(e)
      get_snaive_forecasts(time_series, forecast_horizon)
    })
}
