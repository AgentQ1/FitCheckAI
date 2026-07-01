#!/usr/bin/env node
/**
 * READ-ONLY inspection for the FitCheck 2.1(b) resubmission.
 * Gathers every ID we need and prints the current state. Submits nothing.
 *
 *   - appStoreVersion id for 1.0.0 (+ state)
 *   - the build attached to that version (+ version string + processingState)
 *   - subscription ids for the two premium products (+ state, screenshot)
 *   - any reviewSubmissions on the app (+ state + their items)
 */
import { asc } from "./asc.mjs";

const BUNDLE_ID = "ai.fitcheck.app";
const TARGET_VERSION = "1.0.0";
const PRODUCTS = ["com.fitcheckai.premium.monthly", "com.fitcheckai.premium.yearly"];

const out = {};

async function main() {
  const appResp = await asc("GET", `/v1/apps?filter[bundleId]=${BUNDLE_ID}`);
  const app = appResp.body?.data?.[0];
  if (!app) throw new Error(`app not found (status ${appResp.status})`);
  const appId = app.id;
  out.appId = appId;
  out.appName = app.attributes?.name;

  // --- versions ---
  const verResp = await asc(
    "GET",
    `/v1/apps/${appId}/appStoreVersions?filter[versionString]=${TARGET_VERSION}&include=build&limit=10`
  );
  const versions = verResp.body?.data ?? [];
  out.versions = versions.map((v) => ({
    id: v.id,
    versionString: v.attributes?.versionString,
    state: v.attributes?.appStoreState || v.attributes?.appVersionState,
    platform: v.attributes?.platform,
    buildRel: v.relationships?.build?.data?.id || null,
  }));

  // Build details from included
  const includedBuilds = (verResp.body?.included ?? []).filter((x) => x.type === "builds");
  out.attachedBuilds = includedBuilds.map((b) => ({
    id: b.id,
    version: b.attributes?.version,
    processingState: b.attributes?.processingState,
    uploadedDate: b.attributes?.uploadedDate,
  }));

  // --- subscriptions ---
  const groupsResp = await asc(
    "GET",
    `/v1/apps/${appId}/subscriptionGroups?include=subscriptions&limit=200`
  );
  const subs = (groupsResp.body?.included ?? []).filter((x) => x.type === "subscriptions");
  out.subscriptions = {};
  for (const p of PRODUCTS) {
    const s = subs.find((x) => x.attributes?.productId === p);
    out.subscriptions[p] = s
      ? { id: s.id, state: s.attributes?.state, name: s.attributes?.name }
      : null;
  }

  // --- review submissions ---
  const subsResp = await asc(
    "GET",
    `/v1/apps/${appId}/reviewSubmissions?include=items&limit=50`
  );
  const rs = subsResp.body?.data ?? [];
  const includedItems = subsResp.body?.included ?? [];
  out.reviewSubmissions = rs.map((r) => ({
    id: r.id,
    state: r.attributes?.state,
    platform: r.attributes?.platform,
    submitted: r.attributes?.submitted,
    itemIds: (r.relationships?.items?.data ?? []).map((i) => i.id),
  }));
  out.reviewSubmissionItems = includedItems
    .filter((x) => x.type === "reviewSubmissionItems")
    .map((i) => ({
      id: i.id,
      state: i.attributes?.state,
      rels: Object.fromEntries(
        Object.entries(i.relationships ?? {})
          .filter(([, v]) => v?.data)
          .map(([k, v]) => [k, v.data?.id])
      ),
    }));

  console.log(JSON.stringify(out, null, 2));
}

main().catch((e) => {
  console.error("ERROR:", e.message);
  process.exit(1);
});
