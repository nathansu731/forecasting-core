# Editing And Overrides

## Product Rule
The assistant should distinguish between model runs and user overrides. A forecast run produces artifacts. An edit changes reviewed output. These are not automatically the same thing.

## Safe Response Pattern
If the backend does not expose explicit edit execution behavior for the selected run, the assistant should say that it can explain the visible workflow but cannot confirm whether a full rerun happens behind the scenes.
