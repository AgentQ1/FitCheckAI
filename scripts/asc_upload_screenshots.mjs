#!/usr/bin/env node
/**
 * Upload App Store screenshots to a version localization via the ASC API.
 *
 * Flow per Apple's reservation/commit protocol:
 *   1. Create (or reuse) an appScreenshotSet for the display type.
 *   2. For each file: POST /v1/appScreenshots (reserve) → uploadOperations.
 *   3. PUT the bytes to each upload operation URL with its headers.
 *   4. PATCH /v1/appScreenshots/{id} { uploaded: true, sourceFileChecksum: md5 }.
 *   5. PATCH the set's appScreenshots relationship to fix display order.
 *
 * Env:  ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH  (same as asc.mjs)
 *       LOC           version localization id (default = FitCheck en-US)
 *       DISPLAY_TYPE  default APP_IPHONE_69 (6.9")
 * Args: ordered list of PNG paths.
 */
import { asc } from "./asc.mjs";
import { readFileSync } from "node:fs";
import { basename } from "node:path";
import { createHash } from "node:crypto";

const LOC = process.env.LOC || "f5d8877e-d26a-4826-892f-49d433234ede";
const DISPLAY_TYPE = process.env.DISPLAY_TYPE || "APP_IPHONE_69";
const files = process.argv.slice(2);

if (files.length === 0) {
  console.error("Usage: node scripts/asc_upload_screenshots.mjs <png> [png...]");
  process.exit(2);
}

async function findOrCreateSet() {
  // Reuse an existing set of this display type if present.
  const existing = await asc(
    "GET",
    `/v1/appStoreVersionLocalizations/${LOC}/appScreenshotSets?fields[appScreenshotSets]=screenshotDisplayType&limit=50`
  );
  if (existing.ok) {
    const hit = (existing.body.data || []).find(
      (s) => s.attributes?.screenshotDisplayType === DISPLAY_TYPE
    );
    if (hit) return hit.id;
  }
  const created = await asc("POST", "/v1/appScreenshotSets", {
    data: {
      type: "appScreenshotSets",
      attributes: { screenshotDisplayType: DISPLAY_TYPE },
      relationships: {
        appStoreVersionLocalization: {
          data: { type: "appStoreVersionLocalizations", id: LOC },
        },
      },
    },
  });
  if (!created.ok) {
    console.error("Create set failed:", JSON.stringify(created.body, null, 2));
    process.exit(1);
  }
  return created.body.data.id;
}

async function uploadOne(setId, file) {
  const buf = readFileSync(file);
  const fileName = basename(file);
  const reserve = await asc("POST", "/v1/appScreenshots", {
    data: {
      type: "appScreenshots",
      attributes: { fileName, fileSize: buf.length },
      relationships: {
        appScreenshotSet: { data: { type: "appScreenshotSets", id: setId } },
      },
    },
  });
  if (!reserve.ok) {
    console.error(`Reserve failed for ${fileName}:`, JSON.stringify(reserve.body, null, 2));
    process.exit(1);
  }
  const ss = reserve.body.data;
  const ops = ss.attributes.uploadOperations || [];
  for (const op of ops) {
    const headers = {};
    for (const h of op.requestHeaders || []) headers[h.name] = h.value;
    const chunk = buf.subarray(op.offset, op.offset + op.length);
    const res = await fetch(op.url, { method: op.method, headers, body: chunk });
    if (!res.ok) {
      console.error(`Upload op failed (${res.status}) for ${fileName}:`, await res.text());
      process.exit(1);
    }
  }
  const md5 = createHash("md5").update(buf).digest("hex");
  const commit = await asc("PATCH", `/v1/appScreenshots/${ss.id}`, {
    data: {
      type: "appScreenshots",
      id: ss.id,
      attributes: { uploaded: true, sourceFileChecksum: md5 },
    },
  });
  if (!commit.ok) {
    console.error(`Commit failed for ${fileName}:`, JSON.stringify(commit.body, null, 2));
    process.exit(1);
  }
  console.log(`  ✓ ${fileName}  (${buf.length} bytes)  id=${ss.id}`);
  return ss.id;
}

async function main() {
  console.log(`Display type: ${DISPLAY_TYPE}  Localization: ${LOC}`);
  const setId = await findOrCreateSet();
  console.log(`Screenshot set: ${setId}`);
  const ids = [];
  for (const f of files) ids.push(await uploadOne(setId, f));

  const order = await asc(
    "PATCH",
    `/v1/appScreenshotSets/${setId}/relationships/appScreenshots`,
    { data: ids.map((id) => ({ type: "appScreenshots", id })) }
  );
  console.log(`Order set: ${order.status} ok=${order.ok}`);
  console.log(`\nDone — ${ids.length} screenshots uploaded to set ${setId}.`);
}

main().catch((e) => {
  console.error("ERROR:", e.message);
  process.exit(1);
});
