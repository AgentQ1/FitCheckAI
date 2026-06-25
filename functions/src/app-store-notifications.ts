import { onRequest } from "firebase-functions/v2/https";
import * as admin from "firebase-admin";
import { verifyNotification, verifyTransaction, premiumUpdate, PREMIUM_PRODUCT_IDS } from "./shared/apple";

const db = admin.firestore();

/// Apple App Store Server Notifications V2 endpoint. Set this URL in App Store
/// Connect → App Information → App Store Server Notifications (Version 2). Apple
/// POSTs a signed payload on every subscription lifecycle event (renew, cancel,
/// expire, refund, billing retry, …); we verify it and keep Firestore in sync even
/// when the app isn't open. Mapping from transaction → uid is written by
/// syncAppleSubscription into `appleTransactions/{originalTransactionId}`.
export const appStoreNotifications = onRequest(
  { cors: false, timeoutSeconds: 30 },
  async (req, res) => {
    if (req.method !== "POST") { res.status(405).send("method_not_allowed"); return; }

    const signedPayload = req.body?.signedPayload;
    if (typeof signedPayload !== "string" || signedPayload.length === 0) {
      res.status(400).send("bad_request");
      return;
    }

    let notification;
    try {
      notification = await verifyNotification(signedPayload);
    } catch (err) {
      console.error("[appStoreNotifications] notification verify failed:", (err as Error)?.message);
      res.status(400).send("invalid_signature");
      return;
    }

    try {
      const notificationType = String(notification.notificationType ?? "");
      const signedTx = notification.data?.signedTransactionInfo;
      if (!signedTx) {
        // Nothing actionable (e.g. a test or consumption-request notification).
        res.status(200).send("ok");
        return;
      }

      const tx = await verifyTransaction(signedTx);
      const originalTransactionId = tx.originalTransactionId ?? tx.transactionId ?? "";
      const productId = tx.productId ?? "";
      const expiresMs = tx.expiresDate ?? 0;

      // Resolve the Firebase user from the transaction → uid mapping.
      const mapSnap = await db.collection("appleTransactions").doc(originalTransactionId).get();
      let uid: string | undefined = mapSnap.exists ? (mapSnap.data()?.uid as string | undefined) : undefined;

      // Recovery #1: the mapping is normally written by syncAppleSubscription, but a
      // notification can race ahead of it (or its write failed). Fall back to the
      // users doc that already mirrors this original transaction id, and backfill the
      // mapping so future events resolve directly.
      if (!uid && originalTransactionId) {
        const byTx = await db.collection("users")
          .where("appleOriginalTransactionId", "==", originalTransactionId).limit(1).get();
        if (!byTx.empty) {
          uid = byTx.docs[0].id;
          await db.collection("appleTransactions").doc(originalTransactionId)
            .set({ uid, productId, recoveredAt: admin.firestore.FieldValue.serverTimestamp() }, { merge: true })
            .catch(() => undefined);
          console.log(`[appStoreNotifications] recovered uid=${uid} for origTx=${originalTransactionId} via users mirror`);
        }
      }

      if (!uid) {
        // Recovery #2: do NOT silently drop the event. Persist it to an unresolved
        // queue so it can be reconciled once the mapping exists (e.g. when the user
        // next syncs). We still ack 200 so Apple doesn't hot-retry something we can't
        // action yet; the queue is the durable record.
        await db.collection("unresolvedAppleNotifications").doc(originalTransactionId || `unmapped_${Date.now()}`).set({
          originalTransactionId,
          productId,
          notificationType,
          expiresMs,
          signedTransaction: signedTx,
          resolved: false,
          receivedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true }).catch((e) => console.error("[appStoreNotifications] queue write failed:", (e as Error)?.message));
        console.warn(`[appStoreNotifications] no uid mapping for origTx=${originalTransactionId} type=${notificationType} — queued for reconciliation`);
        res.status(200).send("ok");
        return;
      }

      const isRevoked =
        !!tx.revocationDate ||
        notificationType === "REFUND" ||
        notificationType === "REVOKE";
      const isExpired = notificationType === "EXPIRED" || (expiresMs > 0 && expiresMs <= Date.now());
      const isActive = PREMIUM_PRODUCT_IDS.has(productId) && !isRevoked && !isExpired;

      const update = premiumUpdate({ productId, expiresMs, isActive });
      if (notificationType === "REFUND" || notificationType === "REVOKE") {
        update.subscriptionStatus = "canceled";
      }
      update.appleOriginalTransactionId = originalTransactionId;
      await db.collection("users").doc(uid).set(update, { merge: true });

      console.log(`[appStoreNotifications] uid=${uid} type=${notificationType} active=${isActive} product=${productId}`);
      res.status(200).send("ok");
    } catch (err) {
      // Return 500 so Apple retries transient failures.
      console.error("[appStoreNotifications] handler error:", (err as Error)?.message);
      res.status(500).send("error");
    }
  }
);
