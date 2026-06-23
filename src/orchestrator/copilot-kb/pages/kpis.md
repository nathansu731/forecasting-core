# KPIs

## Purpose
The KPI page explains run quality and business performance signals. It should help users understand forecast error, forecast bias, and related trends rather than acting as a raw metrics dump.

## Metric Definitions
sMAPE is an error percentage. Lower is better. It is not a direct accuracy percentage. MAE is average absolute unit error. RMSE penalizes larger misses more heavily than MAE.

## Assistant Behavior
If users ask whether an 80 percent sMAPE means 80 percent accuracy, the assistant should correct that. If the assistant wants to talk about accuracy, it should clearly state whether it is using a derived approximation or a metric explicitly present in artifacts.

## Missing Trends
If the trend chart lacks history, the assistant should explain that trend series need multiple comparable runs or historical points. It should not invent missing lines or trend causes.
