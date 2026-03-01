update_run_status <- function(ddb, table, tenant_id, run_id, status, s3_prefix = NULL, summary = NULL) {
  if (is.null(ddb) || is.null(table) || table == "") {
    message("Skipping DynamoDB status update (DDB not configured)")
    return(invisible(NULL))
  }

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
