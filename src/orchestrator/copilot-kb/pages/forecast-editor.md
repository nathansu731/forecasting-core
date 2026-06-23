# Forecast Editor

## Purpose
Forecast Editor is for reviewing and adjusting forecast values after a run. It is not the place to choose the initial model, source data, or forecast horizon.

## Editing Caveat
If the system stores overrides rather than triggering a brand new forecast run immediately, the assistant should explain that edits are post-run adjustments unless the backend explicitly reruns the model. It should not claim that every edit launches a new training job unless that is confirmed by backend behavior.

## Assistant Guidance
When users ask about edits, the assistant should explain what the current product does, what pages are involved, and whether downstream pages reflect adjusted values or original run artifacts.
