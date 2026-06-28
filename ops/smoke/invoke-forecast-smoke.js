#!/usr/bin/env node
"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync } = require("child_process");

const args = process.argv.slice(2);

const readArg = (name) => {
  const index = args.indexOf(name);
  if (index === -1 || index === args.length - 1) {
    return null;
  }
  return args[index + 1];
};

const functionName = readArg("--function-name");
const payloadFile = readArg("--payload-file");

if (!functionName) {
  console.error("Missing required argument: --function-name");
  process.exit(1);
}

if (!payloadFile) {
  console.error("Missing required argument: --payload-file");
  process.exit(1);
}

const payloadPath = path.resolve(payloadFile);
if (!fs.existsSync(payloadPath)) {
  console.error(`Payload file not found: ${payloadPath}`);
  process.exit(1);
}

const payload = JSON.parse(fs.readFileSync(payloadPath, "utf8"));

const placeholderPaths = [];
const visit = (value, currentPath) => {
  if (typeof value === "string" && value.includes("replace-with-")) {
    placeholderPaths.push(currentPath);
    return;
  }
  if (Array.isArray(value)) {
    value.forEach((item, index) => visit(item, `${currentPath}[${index}]`));
    return;
  }
  if (value && typeof value === "object") {
    for (const [key, child] of Object.entries(value)) {
      visit(child, currentPath ? `${currentPath}.${key}` : key);
    }
  }
};

visit(payload, "");

if (placeholderPaths.length > 0) {
  console.error("Smoke payload still contains placeholder values:");
  for (const item of placeholderPaths) {
    console.error(`- ${item}`);
  }
  process.exit(1);
}

const outputFile = path.join(os.tmpdir(), `forecast-smoke-response-${Date.now()}.json`);

let invokeMetadata;
try {
  const stdout = execFileSync(
    "aws",
    [
      "lambda",
      "invoke",
      "--function-name",
      functionName,
      "--invocation-type",
      "RequestResponse",
      "--log-type",
      "Tail",
      "--cli-binary-format",
      "raw-in-base64-out",
      "--payload",
      JSON.stringify(payload),
      outputFile,
    ],
    { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }
  );
  invokeMetadata = JSON.parse(stdout);
} catch (error) {
  console.error("AWS Lambda smoke invoke failed.");
  if (error.stdout) process.stderr.write(error.stdout);
  if (error.stderr) process.stderr.write(error.stderr);
  process.exit(1);
}

const responseText = fs.readFileSync(outputFile, "utf8");
let responseBody = null;
try {
  responseBody = JSON.parse(responseText);
} catch (error) {
  console.error("Lambda smoke invoke returned non-JSON output:");
  console.error(responseText);
  process.exit(1);
}

if (invokeMetadata.FunctionError) {
  console.error(`Lambda reported FunctionError=${invokeMetadata.FunctionError}`);
  console.error(JSON.stringify(responseBody, null, 2));
  process.exit(1);
}

if (!responseBody || responseBody.status !== "success") {
  console.error("Lambda smoke invoke did not return success status.");
  console.error(JSON.stringify(responseBody, null, 2));
  process.exit(1);
}

if (invokeMetadata.LogResult) {
  const logTail = Buffer.from(invokeMetadata.LogResult, "base64").toString("utf8").trim();
  if (logTail) {
    console.log("Lambda log tail:");
    console.log(logTail);
  }
}

console.log("Forecast smoke invoke passed.");
console.log(JSON.stringify(responseBody, null, 2));
