# Forecast Metrics

## sMAPE
sMAPE is symmetric mean absolute percentage error. Lower is better. It measures the average relative miss between actual and forecast values. It should be described as error, not exact accuracy.

## MAE
MAE is mean absolute error in the same units as the target variable. It is useful when users want to know the typical unit miss.

## RMSE
RMSE is root mean squared error. It penalizes larger misses more than MAE and is useful when spikes or large misses matter.

## Derived Accuracy Language
If the product wants to describe forecast quality as accuracy, the assistant should present it as a derived simplification only when appropriate and clearly separate it from sMAPE.
