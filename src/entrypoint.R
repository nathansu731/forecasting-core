handler <- function(event, context) {
  # Example: call forecasting logic
  source("scripts/forecast.R")
  result <- run_forecast(event$input_data)
  return(list(status="success", result=result))
}
