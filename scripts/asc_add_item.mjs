#!/usr/bin/env node
/**
 * Create ONE reviewSubmissionItem in a given reviewSubmission.
 * Usage: node scripts/asc_add_item.mjs <reviewSubmissionId> <relKey> <relType> <relId>
 * Example: ... 38502c14-... appStoreVersion appStoreVersions e1e50f24-...
 * Prints status + body so we can learn from Apple's errors. Creates nothing on 4xx.
 */
import { asc } from "./asc.mjs";

const [, , submissionId, relKey, relType, relId] = process.argv;
if (!submissionId || !relKey || !relType || !relId) {
  console.error("Usage: asc_add_item.mjs <submissionId> <relKey> <relType> <relId>");
  process.exit(2);
}

const body = {
  data: {
    type: "reviewSubmissionItems",
    relationships: {
      reviewSubmission: { data: { type: "reviewSubmissions", id: submissionId } },
      [relKey]: { data: { type: relType, id: relId } },
    },
  },
};

const r = await asc("POST", "/v1/reviewSubmissionItems", body);
console.log(JSON.stringify({ status: r.status, ok: r.ok, body: r.body }, null, 2));
process.exit(r.ok ? 0 : 1);
