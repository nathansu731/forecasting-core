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
