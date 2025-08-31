source(file.path("utils", "error_calculator.R", fsep = "/"))
source(file.path("utils", "global_model_helper.R", fsep = "/"))
source(file.path("models", "local_univariate_models.R", fsep = "/"))
source(file.path("models", "global_models.R", fsep = "/"))


# Seasonality values corresponding with the frequencies: 4_seconds, minutely, 10_minutes, 15_minutes, half_hourly, hourly, daily, weekly, monthly, quarterly and yearly
# Consider multiple seasonalities for frequencies less than daily
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


# This function performs the fixed horizon evaluation with local models.
do_local_forecasting <- function(dataset, dataset_name, method, forecast_horizon, frequency){
  
  if(!is.null(frequency))
    seasonality <- SEASONALITY_MAP[[frequency]]
  else
    seasonality <- 1
  
  train_series_list <- list()
  actual_matrix <- matrix(NA, nrow = length(dataset), ncol = forecast_horizon)
  
  start_time <- Sys.time()
  print("started Forecasting")
  
  dir.create(file.path("results", "forecasts", fsep = "/"), showWarnings = FALSE, recursive=TRUE)
  
  for(s in 1:length(dataset)){
    print(s)
    series_data <- as.numeric(unlist(dataset[s], use.names = FALSE))
    
    if(length(series_data) < forecast_horizon)
      forecast_horizon <- 1
    
    train_series_list[[s]] <- series_data[1:(length(series_data) - forecast_horizon)]
    actual_matrix[s,] <- series_data[(length(series_data) - forecast_horizon + 1):length(series_data)]
    
    series <- forecast:::msts(train_series_list[[s]], seasonal.periods = seasonality)
    
    # Forecasting
    current_method_forecasts <- eval(parse(text = paste0("get_", method, "_forecasts(series, forecast_horizon)")))
    current_method_forecasts[is.na(current_method_forecasts)] <- 0
    write.table(t(current_method_forecasts), file.path("results", "forecasts", paste0(dataset_name, "_", method, ".txt"), fsep = "/"), row.names = FALSE, col.names = FALSE, sep = ",", quote = FALSE, append = TRUE)
  }
  
  end_time <- Sys.time()
  print("Finished Forecasting")
  
  # Execution time
  exec_time <- end_time - start_time
  print(exec_time)

  # Error calculations
  dir.create(file.path("results", "errors", fsep = "/"), showWarnings = FALSE, recursive=TRUE)
  
  forecast_matrix <- as.matrix(read.csv(file.path("results", "forecasts", paste0(dataset_name, "_", method, ".txt"), fsep = "/"), header = F))
  calculate_errors(forecast_matrix, actual_matrix, file.path("results", "errors", paste0(dataset_name, "_", method), fsep = "/"))
}


# This function performs the fixed horizon evaluation with global models.
do_global_forecasting <- function(dataset, dataset_name, method, forecast_horizon, lag, frequency){
  
  if(!is.null(frequency))
    seasonality <- SEASONALITY_MAP[[frequency]]
  else
    seasonality <- 1
  
  if(is.null(lag))
    lag <- round(seasonality[1]*1.25)
  
  start_time <- Sys.time()
  print("started Forecasting")
  
  train_series_list <- list()
  actual_matrix <- matrix(NA, nrow = length(dataset), ncol = forecast_horizon)
  
  for(s in 1:length(dataset)){
    print(s)
    series_data <- as.numeric(unlist(dataset[s], use.names = FALSE))
    
    train_series_list[[s]] <- series_data[1:(length(series_data) - forecast_horizon)]
    actual_matrix[s,] <- series_data[(length(series_data) - forecast_horizon + 1):length(series_data)]
  }
  
  # Forecasting
  forecast_matrix <- start_forecasting(train_series_list, lag, forecast_horizon, method)
  forecast_matrix[is.na(forecast_matrix)] <- 0
  
  dir.create(file.path("results", "forecasts", fsep = "/"), showWarnings = FALSE, recursive=TRUE)
  write.table(forecast_matrix, file.path("results", "forecasts", paste0(dataset_name, "_", method, ".txt"), fsep = "/"), row.names = FALSE, col.names = FALSE, sep = ",", quote = FALSE, append = TRUE)
  
  end_time <- Sys.time()
  print("Finished Forecasting")
  
  # Execution time
  exec_time <- end_time - start_time
  print(exec_time)
  
  # Error calculations
  dir.create(file.path("results", "errors", fsep = "/"), showWarnings = FALSE, recursive=TRUE)
  calculate_errors(as.matrix(forecast_matrix), actual_matrix, file.path(BASE_DIR, "results", "errors", paste0(dataset_name, "_", method), fsep = "/"))
}

