#!/usr/bin/env node
/**
 * Verify the FitCheck Premium subscriptions are configured and SUBMITTABLE in
 * App Store Connect — the exact thing Apple's Guideline 2.1(b) rejection is about.
 *
 * It does NOT submit anything. Read-only. It reports, per subscription:
 *   - productId            (must match the app: com.fitcheckai.premium.monthly / .yearly)
 *   - state                (e.g. MISSING_METADATA, READY_TO_SUBMIT, WAITING_FOR_REVIEW,
 *                           APPROVED) — Apple rejects 2.1(b) when these aren't submitted
 *                           WITH the app version, so anything not READY_TO_SUBMIT /
 *                           WAITING_FOR_REVIEW / APPROVED needs fixing in ASC.
 *   - whether a review screenshot is attached (required for first submission)
 *
 * Usage:  node scripts/asc_verify_iap.mjs
 * Env:    ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH  (same as scripts/asc.mjs)
 */
import { asc } from "./asc.mjs";

const BUNDLE_ID = "ai.fitcheck.app";
const EXPECTED = ["com.fitcheckai.premium.monthly", "com.fitcheckai.premium.yearly"];
const SUBMITTABLE = new Set(["READY_TO_SUBMIT", "WAITING_FOR_REVIEW", "IN_REVIEW", "APPROVED", "DEVELOPER_ACTION_NEEDED"]);

async function main() {
  // 1) Resolve the app id from the bundle id.
  const appResp = await asc("GET", `/v1/apps?filter[bundleId]=${BUNDLE_ID}`);
  const app = appResp.body?.data?.[0];
  if (!app) {
    console.error(`✗ Could not find app for bundleId ${BUNDLE_ID}. status=${appResp.status}`);
    process.exit(1);
  }
  const appId = app.id;
  console.log(`App: ${app.attributes?.name} (${BUNDLE_ID}) id=${appId}\n`);

  // 2) Subscription groups → subscriptions.
  const groupsResp = await asc("GET", `/v1/apps/${appId}/subscriptionGroups?include=subscriptions&limit=200`);
  const subs = (groupsResp.body?.included ?? []).filter((x) => x.type === "subscriptions");

  if (subs.length === 0) {
    console.error("✗ No auto-renewable subscriptions found on this app. Create them in ASC first.");
    process.exit(1);
  }

  const found = new Map();
  for (const s of subs) found.set(s.attributes?.productId, s);

  let allGood = true;
  for (const productId of EXPECTED) {
    const s = found.get(productId);
    if (!s) {
      console.log(`✗ ${productId}: NOT FOUND in App Store Connect`);
      allGood = false;
      continue;
    }
    const state = s.attributes?.state ?? "UNKNOWN";

    // Does it have a review screenshot? (required for first submission)
    let hasShot = "unknown";
    try {
      const shotResp = await asc("GET", `/v1/subscriptions/${s.id}/appStoreReviewScreenshot`);
      hasShot = shotResp.ok && shotResp.body?.data ? "yes" : "NO (upload one)";
    } catch { hasShot = "unknown"; }

    const ok = SUBMITTABLE.has(state);
    if (!ok) allGood = false;
    console.log(`${ok ? "✓" : "✗"} ${productId}`);
    console.log(`     state=${state}  reviewScreenshot=${hasShot}`);
  }

  console.log("");
  if (allGood) {
    console.log("✓ Both subscriptions exist and are in a submittable state.");
    console.log("  → In ASC, on the REJECTED version page, confirm both subscriptions are");
    console.log("    selected under \"In-App Purchases and Subscriptions\", then resubmit.");
  } else {
    console.log("✗ Fix the items marked ✗ above in App Store Connect, then re-run this script.");
    process.exit(2);
  }
}

main().catch((e) => { console.error("ERROR:", e.message); process.exit(1); });
