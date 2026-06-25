import { onRequest } from "firebase-functions/v2/https";
import * as admin from "firebase-admin";
import { requireAuth, sendError } from "./shared/auth";
import { verifyTransaction, premiumUpdate, PREMIUM_PRODUCT_IDS } from "./shared/apple";

const db = admin.firestore();

/// Called by the app right after an Apple purchase / restore. The client posts the
/// signed StoreKit transaction (JWS); we verify it with Apple's signature, then
/// mirror the entitlement into Firestore so server-side rate limits (which read
/// `isPremium` / `fitCheckLimit`) match what StoreKit already unlocked on-device.
/// Fails closed — a transaction that can't be verified never grants Premium.
export const syncAppleSubscription = onRequest(
  { cors: true, timeoutSeconds: 30 },
  async (req, res) => {
    if (req.method === "OPTIONS") { res.status(204).send(""); return; }
    if (req.method !== "POST") { res.status(405).json({ error: "method_not_allowed" }); return; }

    let uid: string;
    try {
      uid = (await requireAuth(req)).uid;
    } catch {
      sendError(res, 401, "unauthorized", "Invalid or expired token.");
      return;
    }

    const signedTransaction = req.body?.signedTransaction;
    if (typeof signedTransaction !== "string" || signedTransaction.length === 0) {
      sendError(res, 400, "bad_request", "Missing signedTransaction.");
      return;
    }

    let payload;
    try {
      payload = await verifyTransaction(signedTransaction);
    } catch (err) {
      console.error("[syncAppleSubscription] verification failed:", (err as Error)?.message);
      sendError(res, 400, "invalid_transaction", "Could not verify the transaction.");
      return;
    }

    const productId = payload.productId ?? "";
    const expiresMs = payload.expiresDate ?? 0;
    const isRevoked = !!payload.revocationDate;
    const isActive = PREMIUM_PRODUCT_IDS.has(productId) && !isRevoked && expiresMs > Date.now();
    const originalTransactionId = payload.originalTransactionId ?? payload.transactionId ?? "";

    try {
      const update = premiumUpdate({ productId, expiresMs, isActive });
      update.appleOriginalTransactionId = originalTransactionId;
      await db.collection("users").doc(uid).set(update, { merge: true });

      // Reverse map so the App Store Server Notification (which only carries the
      // transaction, not our uid) can find this user on renew/cancel/refund.
      if (originalTransactionId) {
        await db.collection("appleTransactions").doc(originalTransactionId).set(
          {
            uid,
            productId,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
          { merge: true }
        );
        // Close the loop on any notification that arrived BEFORE this mapping existed
        // (appStoreNotifications queues those instead of dropping them). The write
        // above already reflects the CURRENT entitlement, so we don't replay the older
        // queued event — just mark it resolved so the queue stays bounded. `update`
        // no-ops (throws NOT_FOUND, caught) when there's nothing queued.
        await db.collection("unresolvedAppleNotifications").doc(originalTransactionId)
          .update({
            resolved: true,
            resolvedUid: uid,
            resolvedAt: admin.firestore.FieldValue.serverTimestamp(),
          })
          .catch(() => undefined);
      }

      console.log(`[syncAppleSubscription] uid=${uid} product=${productId} active=${isActive} origTx=${originalTransactionId}`);
      res.status(200).json({ isPremium: isActive, subscriptionStatus: update.subscriptionStatus });
    } catch (err) {
      console.error("[syncAppleSubscription] write failed:", (err as Error)?.message);
      sendError(res, 500, "write_failed", "Could not record your subscription. Please try again.");
    }
  }
);
