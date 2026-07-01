import * as admin from "firebase-admin";
import { onRequest } from "firebase-functions/v2/https";
import { onFitCheckDeleted } from "./arena";

/**
 * Admin-only moderation actions (Apple Guideline 1.2: the developer must act on
 * reports within 24 hours — removing objectionable content and ejecting abusive
 * users). Gated by a shared secret (`ADMIN_MODERATION_KEY`), NEVER by a normal user
 * token, so only the operator can call it.
 *
 * The `reports` queue is the work list (written by the app on report/block). Triage:
 *   1. GET  ?action=queue                        → list open reports
 *   2. POST { action: "remove_content", fitId }  → tombstone the fit, drop it from
 *                                                   the Arena, mark it rejected
 *   3. POST { action: "suspend_user", uid }      → eject the user from public surfaces
 *   4. POST { action: "resolve_report", reportId, actionTaken } → close the report
 *
 * Set the secret once:  firebase functions:secrets:set ADMIN_MODERATION_KEY
 * Call with header:     x-admin-key: <the secret>
 */
export const adminModerate = onRequest(
  { timeoutSeconds: 60, invoker: "public", secrets: ["ADMIN_MODERATION_KEY"] },
  async (req, res) => {
    const expected = process.env.ADMIN_MODERATION_KEY;
    const provided = req.get("x-admin-key");
    if (!expected || provided !== expected) {
      res.status(403).json({ error: "forbidden" });
      return;
    }

    const db = admin.firestore();

    try {
      // List the open queue.
      if (req.method === "GET" || req.body?.action === "queue") {
        const snap = await db.collection("reports")
          .where("status", "==", "open")
          .orderBy("createdAt", "asc")
          .limit(100)
          .get();
        const items = snap.docs.map((d) => ({ id: d.id, ...d.data() }));
        res.status(200).json({ count: items.length, items });
        return;
      }

      const { action } = req.body ?? {};

      if (action === "remove_content") {
        const fitId: string = req.body.fitId;
        if (!fitId) { res.status(400).json({ error: "fitId required" }); return; }
        // Tombstone the public Arena doc + drop from the boards.
        await onFitCheckDeleted(db, fitId);
        // Flag the source fit (if we know the owner) so it can never re-enter.
        const ownerUid: string | undefined = req.body.ownerUid;
        if (ownerUid) {
          await db.collection("users").doc(ownerUid).collection("fit_checks").doc(fitId)
            .set({ moderationStatus: "rejected" }, { merge: true })
            .catch(() => undefined);
        }
        res.status(200).json({ ok: true, removed: fitId });
        return;
      }

      if (action === "suspend_user") {
        const uid: string = req.body.uid;
        if (!uid) { res.status(400).json({ error: "uid required" }); return; }
        // Eject from every public surface: suspended + not public.
        await db.collection("users").doc(uid).set(
          { suspended: true, isPublic: false, suspendedAt: admin.firestore.FieldValue.serverTimestamp() },
          { merge: true }
        );
        // Pull their public mirror so leaderboards stop showing them.
        await db.collection("publicProfiles").doc(uid).delete().catch(() => undefined);
        res.status(200).json({ ok: true, suspended: uid });
        return;
      }

      if (action === "resolve_report") {
        const reportId: string = req.body.reportId;
        if (!reportId) { res.status(400).json({ error: "reportId required" }); return; }
        await db.collection("reports").doc(reportId).set({
          status: req.body.status ?? "actioned",
          actionTaken: req.body.actionTaken ?? "none",
          reviewedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
        res.status(200).json({ ok: true, resolved: reportId });
        return;
      }

      res.status(400).json({ error: "unknown_action" });
    } catch (e) {
      console.error("[adminModerate] error:", (e as Error)?.message);
      res.status(500).json({ error: "server_error" });
    }
  }
);
