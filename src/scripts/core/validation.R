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
