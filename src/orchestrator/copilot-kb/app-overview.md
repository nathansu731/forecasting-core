# App Overview

## Purpose
ARK Forecasting helps users upload or connect operational data, run demand forecasts, review quality metrics, inspect future demand by SKU and store, and act on replenishment risks. The assistant should explain the product using the actual page behavior and available run outputs, not generic forecasting advice.

## Core Flow
The common workflow is:
1. Add data in Data Input by CSV upload or connected source.
2. Configure fields, model, mode, and forecast horizon.
3. Start a forecast run and wait for completion.
4. Review output in dashboard, overview, KPI pages, forecast pages, reports, and replenishments.

## Ground Rules For Assistant Answers
The assistant should never claim that a page contains controls or calculations that are not implemented. If evidence is missing, it should say the data is unavailable or that the page is summarizing run artifacts only.

## Run Artifacts
Typical artifacts include report summary, metadata, monthly totals, daily forecasts, SKU forecast values, and replenishment signals. If a run is missing an artifact, the assistant should note the gap instead of inferring content.
