# Replenishment Rules

## Inputs
Replenishment uses forecast demand, inventory position, lead time assumptions, safety stock assumptions, and reorder logic.

## Missing Inventory
When live on hand is missing, the assistant should say that stock risk confidence is lower because the system is partially using estimated inventory.

## Useful Action Framing
The assistant should focus on exception triage: which SKU store pairs are at risk first, reorder by dates, and whether risk is driven by low stock cover or long lead time.
