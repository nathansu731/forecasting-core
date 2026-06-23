update_run_status <- function(ddb, table, tenant_id, run_id, status, s3_prefix = NULL, summary = NULL) {
  if (is.null(ddb) || is.null(table) || table == "") {
    if (is.null(ddb) && (is.null(table) || table == "")) {
      message("Skipping DynamoDB status update (DDB client unavailable and table not configured)")
    } else if (is.null(ddb)) {
      message("Skipping DynamoDB status update (DDB client unavailable; check paws.database in runtime image)")
    } else {
      message("Skipping DynamoDB status update (FORECAST_RUNS_TABLE not configured)")
    }
  } else {
    expr_names <- list("#status" = "status")
    expr_values <- list(":status" = list(S = status), ":updatedAt" = list(S = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ")))
    update_expr <- "SET #status = :status, updatedAt = :updatedAt"

    if (!is.null(s3_prefix)) {
      expr_values[[":prefix"]] <- list(S = s3_prefix)
      update_expr <- paste(update_expr, ", s3OutputPrefix = :prefix")
    }

    if (!is.null(summary)) {
      expr_values[[":summary"]] <- list(S = toJSON(summary, auto_unbox = TRUE))
      update_expr <- paste(update_expr, ", summary = :summary")
    }

    ddb$update_item(
      TableName = table,
      Key = list(
        PK = list(S = paste0("TENANT#", tenant_id)),
        SK = list(S = paste0("RUN#", run_id))
      ),
      UpdateExpression = update_expr,
      ExpressionAttributeNames = expr_names,
      ExpressionAttributeValues = expr_values
    )
  }

  appsync_url <- Sys.getenv("APPSYNC_API_URL")
  appsync_key <- Sys.getenv("APPSYNC_API_KEY")
  if (appsync_url != "" && appsync_key != "") {
    summary_json <- NULL
    if (!is.null(summary)) {
      summary_json <- toJSON(summary, auto_unbox = TRUE)
    }
    mutation <- "mutation UpdateForecastRunStatus($input: UpdateForecastRunStatusInput!) { updateForecastRunStatus(input: $input) { __typename } }"
    payload <- list(
      query = mutation,
      variables = list(
        input = list(
          tenantId = tenant_id,
          runId = run_id,
          status = status,
          s3OutputPrefix = s3_prefix,
          summaryJson = summary_json
        )
      )
    )
    tryCatch(
      {
        response <- httr::POST(
          url = appsync_url,
          httr::add_headers(
            `Content-Type` = "application/json",
            `x-api-key` = appsync_key
          ),
          body = payload,
          encode = "json"
        )
        status_code <- httr::status_code(response)
        body_text <- httr::content(response, as = "text", encoding = "UTF-8")
        if (status_code >= 300) {
          message("AppSync status update HTTP error: ", status_code, " body=", body_text)
        } else {
          parsed <- tryCatch(jsonlite::fromJSON(body_text, simplifyVector = FALSE), error = function(e) NULL)
          if (!is.null(parsed$errors)) {
            message("AppSync status update GraphQL errors: ", jsonlite::toJSON(parsed$errors, auto_unbox = TRUE))
          }
        }
      },
      error = function(e) {
        message("Skipping AppSync subscription update: ", e$message)
      }
    )
  }
}
