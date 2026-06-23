const fs = require("fs");
const path = require("path");

const PACK_FILES = ["assistant-evals.json", "assistant-evals.staging.json"];

const ensureArray = (value, label) => {
  if (!Array.isArray(value)) {
    throw new Error(`${label} must be an array`);
  }
};

const ensureOptionalString = (value, label) => {
  if (value !== undefined && value !== null && typeof value !== "string") {
    throw new Error(`${label} must be a string when provided`);
  }
};

const validateFixture = (fixture, index, packId) => {
  const prefix = `${packId} fixture ${index + 1}`;
  if (!fixture || typeof fixture !== "object") throw new Error(`${prefix} must be an object`);
  if (!fixture.id) throw new Error(`${prefix} missing id`);
  if (!fixture.category) throw new Error(`${prefix} missing category`);
  if (!fixture.mode || !["offline", "staging"].includes(fixture.mode)) throw new Error(`${prefix} invalid mode`);
  if (!fixture.input || typeof fixture.input !== "object") throw new Error(`${prefix} missing input`);
  if (!fixture.input.command) throw new Error(`${prefix} missing input.command`);
  ensureOptionalString(fixture.input.pageId, `${prefix} input.pageId`);
  ensureOptionalString(fixture.input.route, `${prefix} input.route`);
  ensureOptionalString(fixture.input.contextMode, `${prefix} input.contextMode`);
  ensureOptionalString(fixture.input.selectedSku, `${prefix} input.selectedSku`);
  ensureOptionalString(fixture.input.selectedStore, `${prefix} input.selectedStore`);

  if (fixture.mode === "offline") {
    if (!fixture.resolvedData || typeof fixture.resolvedData !== "object") {
      throw new Error(`${prefix} offline fixture missing resolvedData`);
    }
  }

  if (fixture.mode === "staging") {
    if (!fixture.runtime || typeof fixture.runtime !== "object") {
      throw new Error(`${prefix} staging fixture missing runtime`);
    }
    if (!fixture.runtime.tenantIdEnv) throw new Error(`${prefix} staging runtime missing tenantIdEnv`);
  }

  if (!fixture.assertions || typeof fixture.assertions !== "object") {
    throw new Error(`${prefix} missing assertions`);
  }

  const assertions = fixture.assertions;
  [
    "expectedContains",
    "forbiddenContains",
    "expectedRoutes",
    "forbiddenRoutes",
  ].forEach((key) => {
    if (assertions[key] !== undefined) ensureArray(assertions[key], `${prefix} assertions.${key}`);
  });

  [
    "expectedIntent",
  ].forEach((key) => ensureOptionalString(assertions[key], `${prefix} assertions.${key}`));

  [
    "minEvidenceCount",
    "minWarningsCount",
    "minConfidence",
    "maxConfidence",
  ].forEach((key) => {
    const value = assertions[key];
    if (value !== undefined && value !== null && !Number.isFinite(Number(value))) {
      throw new Error(`${prefix} assertions.${key} must be numeric when provided`);
    }
  });
};

let totalFixtures = 0;

PACK_FILES.forEach((fileName) => {
  const packPath = path.join(__dirname, fileName);
  const raw = fs.readFileSync(packPath, "utf8");
  const pack = JSON.parse(raw);
  if (!pack || typeof pack !== "object") throw new Error(`${fileName} must contain an object`);
  if (!pack.packId) throw new Error(`${fileName} missing packId`);
  ensureArray(pack.fixtures, `${fileName} fixtures`);
  if (pack.fixtures.length === 0) throw new Error(`${fileName} fixtures must not be empty`);
  pack.fixtures.forEach((fixture, index) => validateFixture(fixture, index, pack.packId));
  totalFixtures += pack.fixtures.length;
});

console.log(`assistant-evals: ${PACK_FILES.length} packs, ${totalFixtures} fixtures validated`);
