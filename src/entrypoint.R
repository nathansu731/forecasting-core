library(jsonlite)

# Load forecast functions
source("/var/task/scripts/forecast.R")

handler <- function(event, context) {

  if (!is.null(event$mode) && event$mode == "forecast_run") {
    return(run_forecast_pipeline(event))
  }

  field_name <- event$info$fieldName
  message("AppSync field invoked: ", field_name)

  result <- switch(
    field_name,

    "runForecastTest" = {
      input_data <- event$input$input_data
      run_forecast_test(input_data)
    },

    "getSKUsMetadata" = {
      get_skus_metadata_test()
    },

    "getReportSummary" = {
      get_report_summary_test()
    },

    "getSKUForecasts" = {
      get_sku_forecasts_test()
    },

    "getMonthlyTotals" = {
      get_monthly_totals_test()
    },

    {
      stop(paste("Unknown AppSync field:", field_name))
    }
  )

  list(
    status = "success",
    result = result
  )
}
