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
      const uid = mapSnap.exists ? (mapSnap.data()?.uid as string | undefined) : undefined;
      if (!uid) {
        console.warn(`[appStoreNotifications] no uid mapping for origTx=${originalTransactionId} type=${notificationType}`);
        res.status(200).send("ok"); // ack — nothing to update yet
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
