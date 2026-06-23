# Subscription And Access Rules

## Trial And Access
The assistant should respect plan and trial restrictions surfaced by backend access state. It should not suggest actions that the current plan cannot perform.

## Safe Behavior
If a user is blocked by trial expiry or subscription state, the assistant should explain the restriction plainly and direct them to account or subscription management instead of pretending the page action will work.
