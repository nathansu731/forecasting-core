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
    "input": $util.toJson($context.arguments)
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
