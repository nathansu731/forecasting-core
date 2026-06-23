# Assistant Evals

## Packs

- `assistant-evals.json`
  Offline pack with canned resolved artifacts. Uses the real assistant response generation path but avoids AWS artifact reads.
- `assistant-evals.staging.json`
  Staging pack that resolves tenant and run data from environment variables.

## Commands

- `npm run validate-assistant-evals`
- `npm run assistant-evals`
- `npm run assistant-evals:offline`
- `npm run assistant-evals:staging`

## Local Eval Environment

The runner auto-loads `src/orchestrator/.env.eval` if present.

- Shell environment variables still take precedence over `.env.eval`.
- Use `.env.eval` for local assistant eval values without polluting frontend env files.

## Staging Environment Variables

- `ASSISTANT_EVAL_STAGING_TENANT_ID`
- `ASSISTANT_EVAL_STAGING_RUN_ID_KPIS`
- `ASSISTANT_EVAL_STAGING_SKU_KPIS`
- `ASSISTANT_EVAL_STAGING_STORE_KPIS`
- `ASSISTANT_EVAL_STAGING_RUN_ID_REPORTS`
- `ASSISTANT_EVAL_STAGING_RUN_ID_NAVIGATOR`
- `ASSISTANT_EVAL_STAGING_SKU_NAVIGATOR`
- `ASSISTANT_EVAL_STAGING_STORE_NAVIGATOR`

If a staging fixture is missing its required environment variables, the runner reports it as `SKIP` instead of failing the full pack.

## Notes

The offline pack is intended for pre-release regression checks. The staging pack is intended for live-like validation against known tenant runs.
