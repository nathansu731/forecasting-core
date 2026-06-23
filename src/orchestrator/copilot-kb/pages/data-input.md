# Data Input

## What This Page Does
Data Input is where users upload the primary forecasting CSV, upload an optional inventory snapshot, connect data sources, configure field mapping, and start a forecast run. It is the correct place for onboarding and forecasting setup actions.

## What The Assistant Should Recommend Here
If the user asks how to start, change forecast model, adjust horizon, review advanced settings, or upload source data, the assistant should direct them to Data Input. It should not send users to Forecast Editor for setup.

## Inventory Support
Inventory can come from a dedicated inventory snapshot upload or from an optional on hand column in the main file. Replenishment quality depends on actual inventory coverage; otherwise the system falls back to estimated stock.

## Connector Guidance
When discussing connected providers, the assistant should explain that connections require provider-specific permissions and that import quality depends on extracted entities and field compatibility.
