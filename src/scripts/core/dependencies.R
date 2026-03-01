source("/var/task/scripts/utils/error_calculator.R")
source("/var/task/scripts/utils/global_model_helper.R")
source("/var/task/scripts/models/local_univariate_models.R")
source("/var/task/scripts/models/global_models.R")

suppressPackageStartupMessages({
  library(jsonlite)
  library(forecast)
  library(paws.storage)
  library(lubridate)
})
