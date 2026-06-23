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

  decode_jwt_payload <- function(token) {
    if (is.null(token) || !nzchar(as.character(token))) return(NULL)
    parts <- strsplit(as.character(token), ".", fixed = TRUE)[[1]]
    if (length(parts) < 2) return(NULL)
    payload <- gsub("-", "+", parts[[2]], fixed = TRUE)
    payload <- gsub("_", "/", payload, fixed = TRUE)
    remainder <- nchar(payload) %% 4
    if (!identical(remainder, 0L)) {
      payload <- paste0(payload, strrep("=", 4 - remainder))
    }
    raw_payload <- tryCatch(jsonlite::base64_dec(payload), error = function(e) NULL)
    if (is.null(raw_payload)) return(NULL)
    tryCatch(jsonlite::fromJSON(rawToChar(raw_payload), simplifyVector = FALSE), error = function(e) NULL)
  }

  get_tenant_id_from_event <- function(evt) {
    claims <- evt$identity$claims
    claim_tenant_id <- unwrap_value(claims$`custom:tenant_id`) %||%
      unwrap_value(claims$tenant_id) %||%
      unwrap_value(claims$`cognito:username`)
    if (!is.null(claim_tenant_id) && nzchar(as.character(claim_tenant_id))) {
      return(as.character(claim_tenant_id))
    }

    auth_header <- unwrap_value(evt$request$headers$Authorization) %||% unwrap_value(evt$request$headers$authorization)
    if (is.null(auth_header) || !nzchar(as.character(auth_header))) return(NULL)
    payload <- decode_jwt_payload(auth_header)
    if (is.null(payload)) return(NULL)
    token_tenant_id <- unwrap_value(payload$`custom:tenant_id`) %||%
      unwrap_value(payload$tenant_id) %||%
      unwrap_value(payload$`cognito:username`)
    if (is.null(token_tenant_id) || !nzchar(as.character(token_tenant_id))) return(NULL)
    as.character(token_tenant_id)
  }

  tenant_access_required <- function(evt) {
    tenant_id <- get_tenant_id_from_event(evt)
    if (is.null(tenant_id) || !nzchar(tenant_id)) {
      stop("missing_tenant")
    }
    if (!requireNamespace("paws.database", quietly = TRUE)) {
      stop("missing_paws_database")
    }

    tenants_table <- Sys.getenv("TENANTS_TABLE")
    entitlements_table <- Sys.getenv("ENTITLEMENTS_TABLE")
    if (!nzchar(tenants_table)) {
      stop("missing_tenants_table")
    }

    ddb <- paws.database::dynamodb()
    tenant_res <- ddb$get_item(
      TableName = tenants_table,
      Key = list(tenantId = list(S = tenant_id))
    )
    if (is.null(tenant_res$Item)) {
      stop("tenant_not_found")
    }

    tenant_status <- tolower(as.character(tenant_res$Item$status$S %||% ""))
    trial_ends_at <- as.character(tenant_res$Item$trialEndsAt$S %||% "")
    trial_end_time <- suppressWarnings(as.POSIXct(trial_ends_at, tz = "UTC", format = "%Y-%m-%dT%H:%M:%OSZ"))
    now_utc <- Sys.time()
    trial_active <- identical(tenant_status, "trialing") && !is.na(trial_end_time) && trial_end_time > now_utc
    paid_active <- tenant_status %in% c("active", "past_due", "unpaid")

    entitlement_active <- NA
    if (nzchar(entitlements_table)) {
      ent_res <- ddb$get_item(
        TableName = entitlements_table,
        Key = list(tenantId = list(S = tenant_id))
      )
      if (!is.null(ent_res$Item$isActive$BOOL)) {
        entitlement_active <- isTRUE(ent_res$Item$isActive$BOOL)
      }
    }

    restricted <- identical(tenant_status, "trial_expired") ||
      (identical(tenant_status, "trialing") && !trial_active && !paid_active) ||
      (!trial_active && !paid_active && isFALSE(entitlement_active)) ||
      tenant_status %in% c("canceled", "inactive")

    if (restricted) {
      stop("trial_expired")
    }

    tenant_id
  }

  `%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x

  is_sqs_event <- !is.null(event$Records) && length(event$Records) > 0
  if (is_sqs_event) {
    for (record in event$Records) {
      body_raw <- record$body
      if (is.null(body_raw) || !nzchar(as.character(body_raw))) {
        next
      }
      payload <- jsonlite::fromJSON(as.character(body_raw), simplifyVector = FALSE)
      run_forecast_pipeline(payload)
    }
    return(list(status = "success"))
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
      tenant_access_required(event)
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
