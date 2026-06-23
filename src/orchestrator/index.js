const { dispatchField, handleQueueRecords } = require("./lib/handlers");
const { ARTIFACT_BUCKET, FORECAST_RUNS_TABLE, DATA_SNAPSHOTS_TABLE, FORECAST_LAMBDA_ARN, requireEnv } = require("./lib/shared");

exports.handler = async (event) => {
  try {
    requireEnv(ARTIFACT_BUCKET, "ARTIFACT_BUCKET");
    requireEnv(FORECAST_RUNS_TABLE, "FORECAST_RUNS_TABLE");

    if (Array.isArray(event?.Records) && event.Records.length > 0) {
      return handleQueueRecords(event);
    }

    const fieldName = event?.info?.fieldName || "";
    if (fieldName === "startForecastRun") {
      requireEnv(DATA_SNAPSHOTS_TABLE, "DATA_SNAPSHOTS_TABLE");
      requireEnv(FORECAST_LAMBDA_ARN, "FORECAST_LAMBDA_ARN");
    }

    if (process.env.ORCHESTRATOR_DEBUG_LOGS === "1") {
      const identityKeys = event?.identity ? Object.keys(event.identity) : [];
      const claimKeys = event?.identity?.claims ? Object.keys(event.identity.claims) : [];
      const headerKeys = event?.request?.headers ? Object.keys(event.request.headers) : [];
      console.log(
        JSON.stringify({
          msg: "orchestrator_identity_debug",
          identityKeys,
          claimKeys,
          headerKeys,
          authHeaderPresent: Boolean(event?.request?.headers?.Authorization || event?.request?.headers?.authorization),
        })
      );
    }

    return dispatchField(fieldName, event);
  } catch (err) {
    if (Array.isArray(event?.Records) && event.Records.length > 0) {
      throw err;
    }
    throw err;
  }
};
