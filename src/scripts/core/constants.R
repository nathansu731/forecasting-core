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
for (f in seq_along(FREQUENCIES)) {
  SEASONALITY_MAP[[FREQUENCIES[f]]] <- SEASONALITY_VALS[[f]]
}

VALID_LOCAL_MODELS <- c("arima", "ets", "ses", "theta", "tbats", "dhr_arima", "naive", "snaive", "croston")
