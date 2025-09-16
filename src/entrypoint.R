#!/usr/bin/env Rscript
library(jsonlite)

# Your Lambda-style handler
handler <- function(event, context) {
  # Example: call forecasting logic
  source("scripts/forecast.R")
  result <- run_forecast(event$input_data)
  return(list(status="success", result=result))
}

# Lambda bootstrap will pass the event file path as the first arg
args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 1) stop("No event path provided")

event_path <- args[1]

# Read and parse the incoming event JSON
json <- readChar(event_path, file.info(event_path)$size)
event <- tryCatch(fromJSON(json, simplifyVector = TRUE), error = function(e) NULL)

# Context is not used here but you can pass metadata later
context <- list()

# Call handler
result <- handler(event, context)

# Print as JSON so bootstrap can POST to Lambda Runtime API
cat(toJSON(result, auto_unbox = TRUE))

