import * as admin from "firebase-admin";
import * as fs from "fs";
import * as path from "path";
import { Environment, SignedDataVerifier } from "@apple/app-store-server-library";

// ── Configuration (set via Functions env / params before deploy) ─────────────
//   APPLE_BUNDLE_ID        e.g. "com.fitcheckai.app"  (must match the app)
//   APPLE_APP_APPLE_ID     numeric App Store ID (required for PRODUCTION)
//   APPLE_ENVIRONMENT      "production" | "sandbox"   (default: sandbox)
// Apple Root CA certificates (.cer/.der) must live in functions/certs/.
// Download them from https://www.apple.com/certificateauthority/ —
// at minimum "Apple Root CA - G3".
const BUNDLE_ID = process.env.APPLE_BUNDLE_ID || "ai.fitcheck.app";
const APP_APPLE_ID = process.env.APPLE_APP_APPLE_ID ? Number(process.env.APPLE_APP_APPLE_ID) : undefined;
const APPLE_ENV: Environment =
  process.env.APPLE_ENVIRONMENT === "production" ? Environment.PRODUCTION : Environment.SANDBOX;

export const PREMIUM_PRODUCT_IDS = new Set<string>([
  "com.fitcheckai.premium.monthly",
  "com.fitcheckai.premium.yearly",
]);

const verifierCache = new Map<Environment, SignedDataVerifier>();
let appleRootCAsCache: Buffer[] | null = null;

function loadAppleRootCAs(): Buffer[] {
  if (appleRootCAsCache) return appleRootCAsCache;
  const certsDir = path.join(__dirname, "..", "..", "certs");
  let cas: Buffer[] = [];
  try {
    cas = fs
      .readdirSync(certsDir)
      .filter((f) => f.endsWith(".cer") || f.endsWith(".der") || f.endsWith(".pem"))
      .map((f) => fs.readFileSync(path.join(certsDir, f)));
  } catch {
    throw new Error(`Apple root CA certs not found in ${certsDir}. Add them before deploying.`);
  }
  if (cas.length === 0) {
    throw new Error(`No Apple root CA certs in ${certsDir}. Add "Apple Root CA - G3".`);
  }
  appleRootCAsCache = cas;
  return cas;
}

/// Build (and cache) a verifier for a specific Apple environment. Throws if the
/// Apple root CAs are missing so the caller fails closed — we never grant Premium
/// on an unverifiable transaction.
function verifierFor(env: Environment): SignedDataVerifier {
  const cached = verifierCache.get(env);
  if (cached) return cached;
  const verifier = new SignedDataVerifier(loadAppleRootCAs(), true, env, BUNDLE_ID, APP_APPLE_ID);
  verifierCache.set(env, verifier);
  return verifier;
}

// One deployed function must serve App Store (production) buyers AND Sandbox /
// TestFlight testers, but a SignedDataVerifier validates against a single
// environment. So we try the configured environment first, then fall back to the
// other — whichever one actually signed the transaction wins. Order is just an
// optimization; verification itself is still strict (signature + bundle id).
const ENV_ORDER: Environment[] = (() => {
  const order =
    APPLE_ENV === Environment.PRODUCTION
      ? [Environment.PRODUCTION, Environment.SANDBOX]
      : [Environment.SANDBOX, Environment.PRODUCTION];
  // The Apple library REQUIRES appAppleId to construct a PRODUCTION verifier, so
  // drop production from the fallback until APPLE_APP_APPLE_ID is configured
  // (i.e. while testing against sandbox / TestFlight before launch).
  return APP_APPLE_ID === undefined ? order.filter((e) => e !== Environment.PRODUCTION) : order;
})();

/// Verify a signed StoreKit transaction (JWS) from either environment.
export async function verifyTransaction(signedTransaction: string) {
  let lastErr: unknown;
  for (const env of ENV_ORDER) {
    try {
      const payload = await verifierFor(env).verifyAndDecodeTransaction(signedTransaction);
      console.log(`[apple] transaction verified env=${env}`);
      return payload;
    } catch (err) {
      lastErr = err;
    }
  }
  throw lastErr;
}

/// Verify a signed App Store Server Notification (V2) from either environment.
export async function verifyNotification(signedPayload: string) {
  let lastErr: unknown;
  for (const env of ENV_ORDER) {
    try {
      return await verifierFor(env).verifyAndDecodeNotification(signedPayload);
    } catch (err) {
      lastErr = err;
    }
  }
  throw lastErr;
}

export function planNameFor(productId: string): string {
  return productId.endsWith(".yearly") ? "Premium Annual" : "Premium";
}

export function tierFor(productId: string): string {
  return productId.endsWith(".yearly") ? "yearly" : "monthly";
}

/// The Firestore `users/{uid}` patch that mirrors an Apple entitlement — the single
/// source of truth for Premium across the app.
export function premiumUpdate(opts: {
  productId: string;
  expiresMs: number;
  isActive: boolean;
}): Record<string, unknown> {
  const { productId, expiresMs, isActive } = opts;
  const update: Record<string, unknown> = {
    isPremium: isActive,
    subscriptionStatus: isActive ? "active" : "expired",
    planName: isActive ? planNameFor(productId) : null,
    subscriptionTier: isActive ? tierFor(productId) : "free",
    fitCheckLimit: isActive ? 999 : 3,
    provider: "apple",
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  };
  if (expiresMs > 0) {
    update.currentPeriodEnd = admin.firestore.Timestamp.fromMillis(expiresMs);
  }
  return update;
}
