# ----------------- Appsync Resolvers -------------------------
resource "aws_appsync_resolver" "run_forecast_test" {
  api_id      = aws_appsync_graphql_api.api.id
  type        = "Query"
  field       = "runForecastTest"
  data_source = aws_appsync_datasource.lambda.name
  kind        = "UNIT"

  request_template = <<EOF
{
  "version": "2018-05-29",
  "operation": "Invoke",
  "payload": {
    "info": {
      "fieldName": "runForecastTest"
    },
    "input": $util.toJson($context.arguments),
    "identity": $util.toJson($context.identity),
    "request": {
      "headers": $util.toJson($context.request.headers)
    }
  }
}
EOF

  response_template = <<EOF
$util.toJson($context.result)
EOF
}

resource "aws_appsync_resolver" "get_skus_metadata" {
  api_id      = aws_appsync_graphql_api.api.id
  type        = "Query"
  field       = "getSKUsMetadata"
  data_source = aws_appsync_datasource.orchestrator.name
  kind        = "UNIT"

  request_template = <<EOF
{
  "version": "2018-05-29",
  "operation": "Invoke",
  "payload": {
    "info": {
      "fieldName": "getSKUsMetadata"
    },
    "arguments": $util.toJson($context.arguments),
    "identity": $util.toJson($context.identity),
    "request": {
      "headers": $util.toJson($context.request.headers)
    }
  }
}
EOF

  response_template = <<EOF
$util.toJson($context.result)
EOF
}

resource "aws_appsync_resolver" "get_report_summary" {
  api_id      = aws_appsync_graphql_api.api.id
  type        = "Query"
  field       = "getReportSummary"
  data_source = aws_appsync_datasource.orchestrator.name
  kind        = "UNIT"

  request_template = <<EOF
{
  "version": "2018-05-29",
  "operation": "Invoke",
  "payload": {
    "info": {
      "fieldName": "getReportSummary"
    },
    "arguments": $util.toJson($context.arguments),
    "identity": $util.toJson($context.identity),
    "request": {
      "headers": $util.toJson($context.request.headers)
    }
  }
}
EOF

  response_template = <<EOF
$util.toJson($context.result)
EOF
}

resource "aws_appsync_resolver" "get_sku_forecasts" {
  api_id      = aws_appsync_graphql_api.api.id
  type        = "Query"
  field       = "getSKUForecasts"
  data_source = aws_appsync_datasource.orchestrator.name
  kind        = "UNIT"

  request_template = <<EOF
{
  "version": "2018-05-29",
  "operation": "Invoke",
  "payload": {
    "info": {
      "fieldName": "getSKUForecasts"
    },
    "arguments": $util.toJson($context.arguments),
    "identity": $util.toJson($context.identity),
    "request": {
      "headers": $util.toJson($context.request.headers)
    }
  }
}
EOF

  response_template = <<EOF
$util.toJson($context.result)
EOF
}

resource "aws_appsync_resolver" "get_monthly_totals" {
  api_id      = aws_appsync_graphql_api.api.id
  type        = "Query"
  field       = "getMonthlyTotals"
  data_source = aws_appsync_datasource.orchestrator.name
  kind        = "UNIT"

  request_template = <<EOF
{
  "version": "2018-05-29",
  "operation": "Invoke",
  "payload": {
    "info": {
      "fieldName": "getMonthlyTotals"
    },
    "arguments": $util.toJson($context.arguments),
    "identity": $util.toJson($context.identity),
    "request": {
      "headers": $util.toJson($context.request.headers)
    }
  }
}
EOF

  response_template = <<EOF
$util.toJson($context.result)
EOF
}

resource "aws_appsync_resolver" "get_daily_forecasts" {
  api_id      = aws_appsync_graphql_api.api.id
  type        = "Query"
  field       = "getDailyForecasts"
  data_source = aws_appsync_datasource.orchestrator.name
  kind        = "UNIT"

  request_template = <<EOF
{
  "version": "2018-05-29",
  "operation": "Invoke",
  "payload": {
    "info": {
      "fieldName": "getDailyForecasts"
    },
    "arguments": $util.toJson($context.arguments),
    "identity": $util.toJson($context.identity),
    "request": {
      "headers": $util.toJson($context.request.headers)
    }
  }
}
EOF

  response_template = <<EOF
$util.toJson($context.result)
EOF
}

resource "aws_appsync_resolver" "get_sku_forecast_values" {
  api_id      = aws_appsync_graphql_api.api.id
  type        = "Query"
  field       = "getSkuForecastValues"
  data_source = aws_appsync_datasource.orchestrator.name
  kind        = "UNIT"

  request_template = <<EOF
{
  "version": "2018-05-29",
  "operation": "Invoke",
  "payload": {
    "info": {
      "fieldName": "getSkuForecastValues"
    },
    "arguments": $util.toJson($context.arguments),
    "identity": $util.toJson($context.identity),
    "request": {
      "headers": $util.toJson($context.request.headers)
    }
  }
}
EOF

  response_template = <<EOF
$util.toJson($context.result)
EOF
}

resource "aws_appsync_resolver" "get_merged_sku_forecast_values" {
  api_id      = aws_appsync_graphql_api.api.id
  type        = "Query"
  field       = "getMergedSkuForecastValues"
  data_source = aws_appsync_datasource.orchestrator.name
  kind        = "UNIT"

  request_template = <<EOF
{
  "version": "2018-05-29",
  "operation": "Invoke",
  "payload": {
    "info": {
      "fieldName": "getMergedSkuForecastValues"
    },
    "arguments": $util.toJson($context.arguments),
    "identity": $util.toJson($context.identity),
    "request": {
      "headers": $util.toJson($context.request.headers)
    }
  }
}
EOF

  response_template = <<EOF
$util.toJson($context.result)
EOF
}

resource "aws_appsync_resolver" "get_replenishment_signals" {
  api_id      = aws_appsync_graphql_api.api.id
  type        = "Query"
  field       = "getReplenishmentSignals"
  data_source = aws_appsync_datasource.orchestrator.name
  kind        = "UNIT"

  request_template = <<EOF
{
  "version": "2018-05-29",
  "operation": "Invoke",
  "payload": {
    "info": {
      "fieldName": "getReplenishmentSignals"
    },
    "arguments": $util.toJson($context.arguments),
    "identity": $util.toJson($context.identity),
    "request": {
      "headers": $util.toJson($context.request.headers)
    }
  }
}
EOF

  response_template = <<EOF
$util.toJson($context.result)
EOF
}

resource "aws_appsync_resolver" "start_forecast_run" {
  api_id      = aws_appsync_graphql_api.api.id
  type        = "Mutation"
  field       = "startForecastRun"
  data_source = aws_appsync_datasource.orchestrator.name
  kind        = "UNIT"

  request_template = <<EOF
{
  "version": "2018-05-29",
  "operation": "Invoke",
  "payload": {
    "info": {
      "fieldName": "startForecastRun"
    },
    "input": $util.toJson($context.arguments),
    "identity": $util.toJson($context.identity),
    "request": {
      "headers": $util.toJson($context.request.headers)
    }
  }
}
EOF

  response_template = <<EOF
$util.toJson($context.result)
EOF
}

resource "aws_appsync_resolver" "get_forecast_run" {
  api_id      = aws_appsync_graphql_api.api.id
  type        = "Query"
  field       = "getForecastRun"
  data_source = aws_appsync_datasource.orchestrator.name
  kind        = "UNIT"

  request_template = <<EOF
{
  "version": "2018-05-29",
  "operation": "Invoke",
  "payload": {
    "info": {
      "fieldName": "getForecastRun"
    },
    "input": $util.toJson($context.arguments),
    "identity": $util.toJson($context.identity),
    "request": {
      "headers": $util.toJson($context.request.headers)
    }
  }
}
EOF

  response_template = <<EOF
$util.toJson($context.result)
EOF
}

resource "aws_appsync_resolver" "list_forecast_runs" {
  api_id      = aws_appsync_graphql_api.api.id
  type        = "Query"
  field       = "listForecastRuns"
  data_source = aws_appsync_datasource.orchestrator.name
  kind        = "UNIT"

  request_template = <<EOF
{
  "version": "2018-05-29",
  "operation": "Invoke",
  "payload": {
    "info": {
      "fieldName": "listForecastRuns"
    },
    "input": $util.toJson($context.arguments),
    "identity": $util.toJson($context.identity),
    "request": {
      "headers": $util.toJson($context.request.headers)
    }
  }
}
EOF

  response_template = <<EOF
$util.toJson($context.result)
EOF
}

resource "aws_appsync_resolver" "list_notifications" {
  api_id      = aws_appsync_graphql_api.api.id
  type        = "Query"
  field       = "listNotifications"
  data_source = aws_appsync_datasource.orchestrator.name
  kind        = "UNIT"

  request_template = <<EOF
{
  "version": "2018-05-29",
  "operation": "Invoke",
  "payload": {
    "info": {
      "fieldName": "listNotifications"
    },
    "input": $util.toJson($context.arguments),
    "identity": $util.toJson($context.identity),
    "request": {
      "headers": $util.toJson($context.request.headers)
    }
  }
}
EOF

  response_template = <<EOF
$util.toJson($context.result)
EOF
}

resource "aws_appsync_resolver" "mark_notification_read" {
  api_id      = aws_appsync_graphql_api.api.id
  type        = "Mutation"
  field       = "markNotificationRead"
  data_source = aws_appsync_datasource.orchestrator.name
  kind        = "UNIT"

  request_template = <<EOF
{
  "version": "2018-05-29",
  "operation": "Invoke",
  "payload": {
    "info": {
      "fieldName": "markNotificationRead"
    },
    "input": $util.toJson($context.arguments),
    "identity": $util.toJson($context.identity),
    "request": {
      "headers": $util.toJson($context.request.headers)
    }
  }
}
EOF

  response_template = <<EOF
$util.toJson($context.result)
EOF
}

resource "aws_appsync_resolver" "mark_all_notifications_read" {
  api_id      = aws_appsync_graphql_api.api.id
  type        = "Mutation"
  field       = "markAllNotificationsRead"
  data_source = aws_appsync_datasource.orchestrator.name
  kind        = "UNIT"

  request_template = <<EOF
{
  "version": "2018-05-29",
  "operation": "Invoke",
  "payload": {
    "info": {
      "fieldName": "markAllNotificationsRead"
    },
    "identity": $util.toJson($context.identity),
    "request": {
      "headers": $util.toJson($context.request.headers)
    }
  }
}
EOF

  response_template = <<EOF
$util.toJson($context.result)
EOF
}

resource "aws_appsync_resolver" "clear_completed_notifications" {
  api_id      = aws_appsync_graphql_api.api.id
  type        = "Mutation"
  field       = "clearCompletedNotifications"
  data_source = aws_appsync_datasource.orchestrator.name
  kind        = "UNIT"

  request_template = <<EOF
{
  "version": "2018-05-29",
  "operation": "Invoke",
  "payload": {
    "info": {
      "fieldName": "clearCompletedNotifications"
    },
    "identity": $util.toJson($context.identity),
    "request": {
      "headers": $util.toJson($context.request.headers)
    }
  }
}
EOF

  response_template = <<EOF
$util.toJson($context.result)
EOF
}

resource "aws_appsync_resolver" "get_tenant_settings" {
  api_id      = aws_appsync_graphql_api.api.id
  type        = "Query"
  field       = "getTenantSettings"
  data_source = aws_appsync_datasource.orchestrator.name
  kind        = "UNIT"

  request_template = <<EOF
{
  "version": "2018-05-29",
  "operation": "Invoke",
  "payload": {
    "info": {
      "fieldName": "getTenantSettings"
    },
    "identity": $util.toJson($context.identity),
    "request": {
      "headers": $util.toJson($context.request.headers)
    }
  }
}
EOF

  response_template = <<EOF
$util.toJson($context.result)
EOF
}

resource "aws_appsync_resolver" "set_tenant_settings" {
  api_id      = aws_appsync_graphql_api.api.id
  type        = "Mutation"
  field       = "setTenantSettings"
  data_source = aws_appsync_datasource.orchestrator.name
  kind        = "UNIT"

  request_template = <<EOF
{
  "version": "2018-05-29",
  "operation": "Invoke",
  "payload": {
    "info": {
      "fieldName": "setTenantSettings"
    },
    "input": $util.toJson($context.arguments),
    "identity": $util.toJson($context.identity),
    "request": {
      "headers": $util.toJson($context.request.headers)
    }
  }
}
EOF

  response_template = <<EOF
$util.toJson($context.result)
EOF
}

resource "aws_appsync_resolver" "get_forecast_approvals" {
  api_id      = aws_appsync_graphql_api.api.id
  type        = "Query"
  field       = "getForecastApprovals"
  data_source = aws_appsync_datasource.orchestrator.name
  kind        = "UNIT"

  request_template = <<EOF
{
  "version": "2018-05-29",
  "operation": "Invoke",
  "payload": {
    "info": {
      "fieldName": "getForecastApprovals"
    },
    "identity": $util.toJson($context.identity),
    "request": {
      "headers": $util.toJson($context.request.headers)
    }
  }
}
EOF

  response_template = <<EOF
$util.toJson($context.result)
EOF
}

resource "aws_appsync_resolver" "set_forecast_approval" {
  api_id      = aws_appsync_graphql_api.api.id
  type        = "Mutation"
  field       = "setForecastApproval"
  data_source = aws_appsync_datasource.orchestrator.name
  kind        = "UNIT"

  request_template = <<EOF
{
  "version": "2018-05-29",
  "operation": "Invoke",
  "payload": {
    "info": {
      "fieldName": "setForecastApproval"
    },
    "input": $util.toJson($context.arguments),
    "identity": $util.toJson($context.identity),
    "request": {
      "headers": $util.toJson($context.request.headers)
    }
  }
}
EOF

  response_template = <<EOF
$util.toJson($context.result)
EOF
}

resource "aws_appsync_resolver" "update_forecast_run_status" {
  api_id      = aws_appsync_graphql_api.api.id
  type        = "Mutation"
  field       = "updateForecastRunStatus"
  data_source = aws_appsync_datasource.orchestrator.name
  kind        = "UNIT"

  request_template = <<EOF
{
  "version": "2018-05-29",
  "operation": "Invoke",
  "payload": {
    "info": {
      "fieldName": "updateForecastRunStatus"
    },
    "input": $util.toJson($context.arguments),
    "identity": $util.toJson($context.identity),
    "request": {
      "headers": $util.toJson($context.request.headers)
    }
  }
}
EOF

  response_template = <<EOF
$util.toJson($context.result)
EOF
}

resource "aws_appsync_resolver" "forecast_assistant" {
  api_id      = aws_appsync_graphql_api.api.id
  type        = "Query"
  field       = "forecastAssistant"
  data_source = aws_appsync_datasource.orchestrator.name
  kind        = "UNIT"

  request_template = <<EOF
{
  "version": "2018-05-29",
  "operation": "Invoke",
  "payload": {
    "info": {
      "fieldName": "forecastAssistant"
    },
    "input": $util.toJson($context.arguments),
    "identity": $util.toJson($context.identity),
    "request": {
      "headers": $util.toJson($context.request.headers)
    }
  }
}
EOF

  response_template = <<EOF
$util.toJson($context.result)
EOF
}

resource "aws_appsync_resolver" "get_assistant_usage" {
  api_id      = aws_appsync_graphql_api.api.id
  type        = "Query"
  field       = "getAssistantUsage"
  data_source = aws_appsync_datasource.orchestrator.name
  kind        = "UNIT"

  request_template = <<EOF
{
  "version": "2018-05-29",
  "operation": "Invoke",
  "payload": {
    "info": {
      "fieldName": "getAssistantUsage"
    },
    "identity": $util.toJson($context.identity),
    "request": {
      "headers": $util.toJson($context.request.headers)
    }
  }
}
EOF

  response_template = <<EOF
$util.toJson($context.result)
EOF
}

# ------------------ /Appsync Resolvers -------------------------
