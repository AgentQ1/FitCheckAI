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

let verifierCache: SignedDataVerifier | null = null;

/// Build (and cache) the verifier. Throws if Apple root CAs are missing so the
/// caller fails closed — we never grant Premium on an unverifiable transaction.
export function getVerifier(): SignedDataVerifier {
  if (verifierCache) return verifierCache;
  const certsDir = path.join(__dirname, "..", "..", "certs");
  let appleRootCAs: Buffer[] = [];
  try {
    appleRootCAs = fs
      .readdirSync(certsDir)
      .filter((f) => f.endsWith(".cer") || f.endsWith(".der") || f.endsWith(".pem"))
      .map((f) => fs.readFileSync(path.join(certsDir, f)));
  } catch {
    throw new Error(`Apple root CA certs not found in ${certsDir}. Add them before deploying.`);
  }
  if (appleRootCAs.length === 0) {
    throw new Error(`No Apple root CA certs in ${certsDir}. Add "Apple Root CA - G3".`);
  }
  verifierCache = new SignedDataVerifier(appleRootCAs, true, APPLE_ENV, BUNDLE_ID, APP_APPLE_ID);
  return verifierCache;
}

export function planNameFor(productId: string): string {
  return productId.endsWith(".yearly") ? "Premium Annual" : "Premium";
}

export function tierFor(productId: string): string {
  return productId.endsWith(".yearly") ? "yearly" : "monthly";
}

/// The Firestore `users/{uid}` patch that mirrors an Apple entitlement. Mirrors the
/// fields the Stripe webhook writes so the rest of the app stays consistent.
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
