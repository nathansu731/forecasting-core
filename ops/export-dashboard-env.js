#!/usr/bin/env node

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

const args = process.argv.slice(2);
const getArg = (name, fallback = "") => {
  const index = args.indexOf(name);
  if (index === -1) return fallback;
  return args[index + 1] || fallback;
};

const runTerraform = (terraformDir, terraformArgs, extraEnv = {}) =>
  spawnSync("terraform", ["-chdir=" + terraformDir, ...terraformArgs], {
    encoding: "utf8",
    env: {
      ...process.env,
      ...extraEnv,
    },
  });

const normalizeEnvName = (workspaceName) => {
  const value = String(workspaceName || "").trim().toLowerCase();
  if (!value || value === "default" || value === "dev" || value === "develop" || value === "development") {
    return "develop";
  }
  if (value === "prod" || value === "production") {
    return "production";
  }
  return value;
};

const resolveWorkspaceForEnv = (envName, currentWorkspace) => {
  const normalized = String(envName || "").trim().toLowerCase();
  if (!normalized) {
    return String(currentWorkspace || "").trim();
  }
  if (normalized === "develop" || normalized === "development" || normalized === "dev") {
    return "default";
  }
  if (normalized === "production" || normalized === "prod") {
    return "prod";
  }
  return normalized;
};

const repoRoot = path.resolve(__dirname, "..");
const defaultTerraformDir = path.join(repoRoot, "terraform");
const terraformDir = path.resolve(getArg("--tf-dir", defaultTerraformDir));
const workspaceResult = runTerraform(terraformDir, ["workspace", "show"]);

if (workspaceResult.status !== 0) {
  process.stderr.write(workspaceResult.stderr || workspaceResult.stdout || "terraform workspace show failed\n");
  process.exit(workspaceResult.status || 1);
}

const currentWorkspace = String(workspaceResult.stdout || "").trim();
const envName = getArg("--env", normalizeEnvName(currentWorkspace));
const targetWorkspace = getArg("--workspace", resolveWorkspaceForEnv(envName, currentWorkspace));
const defaultOutFile = path.resolve(repoRoot, "..", "inventory-dashboard", `.env.${envName}.generated`);
const outFile = path.resolve(getArg("--out", defaultOutFile));

const result = runTerraform(terraformDir, ["output", "-json"], {
  TF_WORKSPACE: targetWorkspace,
});

if (result.status !== 0) {
  process.stderr.write(result.stderr || result.stdout || "terraform output failed\n");
  process.exit(result.status || 1);
}

let outputs;
try {
  outputs = JSON.parse(result.stdout);
} catch (error) {
  process.stderr.write(`failed to parse terraform output: ${error.message}\n`);
  process.exit(1);
}

const envOutput = outputs.dashboard_backend_env?.value;
if (!envOutput || typeof envOutput !== "object") {
  process.stderr.write(
    `missing dashboard_backend_env Terraform output in workspace "${targetWorkspace}". ` +
      `Run terraform apply in that workspace so the new output is written to state.\n`,
  );
  process.exit(1);
}

const lines = [
  "# Generated from forecasting-core Terraform outputs.",
  `# Terraform workspace: ${targetWorkspace || currentWorkspace || "unknown"}`,
  "# Do not edit by hand. Re-run forecasting-core/ops/export-dashboard-env.js after terraform apply.",
  "",
];

for (const key of Object.keys(envOutput).sort()) {
  const rawValue = envOutput[key];
  const value = rawValue == null ? "" : String(rawValue);
  lines.push(`${key}=${JSON.stringify(value)}`);
}

fs.writeFileSync(outFile, `${lines.join("\n")}\n`);
process.stdout.write(`Wrote ${outFile}\n`);
