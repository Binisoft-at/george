// Imports cloudkit/schema.ckdb into the Development environment of the app's own container with
// Apple's CKTool JS (Linux, no Mac minutes), then exports Development and Production so the report
// says whether Production still needs "Deploy Schema Changes…" (a button in the CloudKit Console –
// Apple has no API for that step).
//
// Env: CLOUDKIT_MANAGEMENT_TOKEN, APPLE_TEAM_ID, CONTAINER_ID (from Config/Base.xcconfig),
//      SCHEMA_FILE (default cloudkit/schema.ckdb), OUT_DIR (default ci-logs/cloudkit), DRY_RUN=1 (validate only)
// Needs: npm install @apple/cktool.database @apple/cktool.target.nodejs (the workflow does it).
// Synced from the Binisoft handbook.
import fs from "node:fs";
import path from "node:path";
import database from "@apple/cktool.database";
import target from "@apple/cktool.target.nodejs";

const { PromisesApi, CKEnvironment } = database;
const { createConfiguration } = target;

const token = process.env.CLOUDKIT_MANAGEMENT_TOKEN;
const teamId = process.env.APPLE_TEAM_ID;
const containerId = process.env.CONTAINER_ID;
const schemaPath = process.env.SCHEMA_FILE || "cloudkit/schema.ckdb";
const outDir = process.env.OUT_DIR || "ci-logs/cloudkit";
fs.mkdirSync(outDir, { recursive: true });

const report = [];
const log = (line) => { console.log(line); report.push(line); };
const finish = (code) => {
  fs.writeFileSync(path.join(outDir, "report.txt"), report.join("\n") + "\n");
  process.exit(code);
};

if (!token || !teamId || !containerId) {
  log("Missing CLOUDKIT_MANAGEMENT_TOKEN, APPLE_TEAM_ID or CONTAINER_ID.");
  finish(1);
}

const api = new PromisesApi({ configuration: createConfiguration(), security: { ManagementTokenAuth: token } });
const text = fs.readFileSync(schemaPath, "utf8");
const schemaFile = () => new File([text], "schema.ckdb", { type: "text/plain" });
const scope = (environment) => ({ teamId, containerId, environment });

function describe(error) {
  if (!error) return "unknown error";
  const parts = [error.name, error.message];
  for (const key of ["statusCode", "status", "response", "result", "body", "data", "errors"]) {
    if (error[key] !== undefined) parts.push(`${key}: ${JSON.stringify(error[key], null, 2)}`);
  }
  return parts.filter(Boolean).join("\n");
}

async function exportSchema(environment, file) {
  const exported = await api.exportSchema(scope(environment));
  let body = exported?.result ?? exported;
  if (body && typeof body.text === "function") body = await body.text();
  else if (body && typeof body === "object") body = JSON.stringify(body, null, 2);
  fs.writeFileSync(path.join(outDir, file), String(body ?? ""));
  return String(body ?? "");
}

// Record types and fields only, so formatting differences don't count.
function shape(schema) {
  return schema.split("\n")
    .map((line) => line.trim().replace(/,$/, ""))
    .filter((line) => /^RECORD TYPE|^"?[A-Za-z_][A-Za-z0-9_.]*"?\s+(STRING|INT64|DOUBLE|TIMESTAMP|REFERENCE|BYTES|ENCRYPTED|ASSET|LOCATION|LIST)/.test(line))
    .map((line) => line.replace(/\s+/g, " ").replace(/ (QUERYABLE|SORTABLE|SEARCHABLE)/g, ""))
    .sort();
}

try {
  log(`Validating ${schemaPath} against ${containerId} (Development)…`);
  const validation = await api.validateSchema({ ...scope(CKEnvironment.DEVELOPMENT), file: schemaFile() });
  log(`Validation: ${JSON.stringify(validation?.result ?? validation ?? "ok", null, 2)}`);
  if (process.env.DRY_RUN === "1") finish(0);

  log("Importing into Development…");
  const imported = await api.importSchema({ ...scope(CKEnvironment.DEVELOPMENT), file: schemaFile() });
  log(`Import: ${JSON.stringify(imported?.result ?? imported ?? "ok", null, 2)}`);

  const development = await exportSchema(CKEnvironment.DEVELOPMENT, "development.ckdb");
  let production = "";
  try {
    production = await exportSchema(CKEnvironment.PRODUCTION, "production.ckdb");
  } catch (error) {
    log(`Production schema not readable yet: ${error.message}`);
  }
  const same = production && JSON.stringify(shape(development)) === JSON.stringify(shape(production));
  log(same
    ? "Production already matches Development – nothing to deploy."
    : `NEXT: CloudKit Console → ${containerId} → Development → Deploy Schema Changes… → Deploy (before the next TestFlight build).`);
  fs.writeFileSync(path.join(outDir, "needs-deploy.txt"), same ? "no\n" : "yes\n");
  finish(0);
} catch (error) {
  log(`FAILED:\n${describe(error)}`);
  finish(1);
}
