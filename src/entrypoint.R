library(jsonlite)

# Load forecast functions
source("/var/task/scripts/forecast.R")
source("/var/task/scripts/forecast-test.R")

handler <- function(event, context) {
  unwrap_value <- function(x) {
    if (is.null(x)) return(NULL)
    if (is.list(x) && length(x) == 1) return(x[[1]])
    if (length(x) == 1) return(x[[1]])
    x
  }

  invocation_type <- unwrap_value(event$invocationType)
  mode_value <- unwrap_value(event$mode)
  has_run_payload <- !is.null(unwrap_value(event$runId)) && !is.null(unwrap_value(event$s3Key))

  if ((!is.null(invocation_type) && invocation_type == "forecast_run") || has_run_payload || (!is.null(mode_value) && mode_value == "forecast_run")) {
    return(run_forecast_pipeline(event))
  }

  field_name <- unwrap_value(event$info$fieldName)
  if (is.null(field_name) || !nzchar(as.character(field_name))) {
    stop("Missing AppSync fieldName for non-forecast invocation")
  }
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
