#!/usr/bin/env node
/**
 * App Store Connect API helper for FitCheck.
 *
 * Generates a short-lived ES256 JWT from the .p8 key and calls the ASC REST API.
 * No third-party dependencies — uses Node's built-in `crypto`.
 *
 * Required environment (see .env.example):
 *   ASC_KEY_ID     App Store Connect API Key ID
 *   ASC_ISSUER_ID  App Store Connect Issuer ID
 *   ASC_KEY_PATH   Path to the .p8 private key (default: private_keys/AuthKey_<KEY_ID>.p8)
 *
 * Usage:
 *   node scripts/asc.mjs GET  /v1/apps
 *   node scripts/asc.mjs GET  "/v1/apps?filter[bundleId]=ai.fitcheck.app"
 *   node scripts/asc.mjs PATCH /v1/appStoreVersionLocalizations/<id> '<json body>'
 *   node scripts/asc.mjs POST  /v1/... '<json body>'
 *
 * The script NEVER prints the private key. JWTs are short-lived (10 min).
 */
import { readFileSync } from "node:fs";
import { createSign } from "node:crypto";

const KEY_ID = process.env.ASC_KEY_ID;
const ISSUER_ID = process.env.ASC_ISSUER_ID;
const KEY_PATH =
  process.env.ASC_KEY_PATH ||
  (KEY_ID ? `private_keys/AuthKey_${KEY_ID}.p8` : null);

const BASE = "https://api.appstoreconnect.apple.com";

function b64url(input) {
  return Buffer.from(input)
    .toString("base64")
    .replace(/=/g, "")
    .replace(/\+/g, "-")
    .replace(/\//g, "_");
}

function makeJWT() {
  if (!KEY_ID || !ISSUER_ID || !KEY_PATH) {
    throw new Error(
      "Missing ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH environment variables"
    );
  }
  const privateKey = readFileSync(KEY_PATH, "utf8");
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "ES256", kid: KEY_ID, typ: "JWT" };
  const payload = {
    iss: ISSUER_ID,
    iat: now,
    exp: now + 10 * 60, // 10 minutes (ASC max is 20)
    aud: "appstoreconnect-v1",
  };
  const unsigned = `${b64url(JSON.stringify(header))}.${b64url(
    JSON.stringify(payload)
  )}`;
  const signer = createSign("SHA256");
  signer.update(unsigned);
  signer.end();
  // ASC requires the JWS-style fixed 64-byte (r||s) signature, not DER.
  const sig = signer.sign({ key: privateKey, dsaEncoding: "ieee-p1363" });
  return `${unsigned}.${b64url(sig)}`;
}

export async function asc(method, path, body) {
  const token = makeJWT();
  const url = path.startsWith("http") ? path : `${BASE}${path}`;
  const opts = {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
    },
  };
  if (body) opts.body = typeof body === "string" ? body : JSON.stringify(body);
  const res = await fetch(url, opts);
  const text = await res.text();
  let json;
  try {
    json = text ? JSON.parse(text) : {};
  } catch {
    json = { raw: text };
  }
  return { status: res.status, ok: res.ok, body: json };
}

// CLI mode
const isMain = import.meta.url === `file://${process.argv[1]}`;
if (isMain) {
  const [, , method = "GET", path, bodyArg] = process.argv;
  if (!path) {
    console.error("Usage: node scripts/asc.mjs <METHOD> <path> [jsonBody]");
    process.exit(2);
  }
  asc(method.toUpperCase(), path, bodyArg)
    .then(({ status, ok, body }) => {
      console.log(JSON.stringify({ status, ok, body }, null, 2));
      if (!ok) process.exit(1);
    })
    .catch((err) => {
      console.error("ERROR:", err.message);
      process.exit(1);
    });
}
