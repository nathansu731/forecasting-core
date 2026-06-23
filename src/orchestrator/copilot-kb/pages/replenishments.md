# Replenishments

## Purpose
The replenishments page turns forecast demand plus inventory position into reorder signals, stock cover, and stockout risk.

## Inventory Caveat
If live inventory is not available for a SKU and store, the system may use estimated on hand values derived from forecast demand assumptions. In that case the assistant should explicitly mention that the signal is partially proxy based.

## Risk Interpretation
Healthy, medium, and high risk labels should be explained using supporting evidence such as days of cover, reorder point, predicted stockout date, and recommended reorder quantity. The assistant should not flatten all rows into a generic recommendation.

## What Users Expect
Users expect to know which SKU store pairs need attention now, why they are at risk, and what to order or investigate first. The assistant should prioritize exception handling over generic inventory theory.
