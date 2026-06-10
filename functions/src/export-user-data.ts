import { onRequest } from "firebase-functions/v2/https";
import * as admin from "firebase-admin";
import { requireAuth, sendError } from "./shared/auth";

const db = admin.firestore();

export const exportUserData = onRequest(
  { timeoutSeconds: 60, cors: true, invoker: "public" },
  async (req, res) => {
    if (req.method === "OPTIONS") { res.status(204).send(""); return; }
    if (req.method !== "GET" && req.method !== "POST") {
      res.status(405).json({ error: "method_not_allowed" });
      return;
    }

    let uid: string;
    try {
      const auth = await requireAuth(req);
      uid = auth.uid;
    } catch (err) {
      sendError(res, 401, "unauthorized", "Invalid or expired token");
      return;
    }

    try {
      // Fetch user profile
      const userSnap = await db.collection("users").doc(uid).get();
      const profile = userSnap.exists ? userSnap.data() : {};

      // Fetch fit checks (excluding deleted)
      const fitSnap = await db.collection(`users/${uid}/fit_checks`)
        .where("isDeleted", "==", false)
        .get();
      const fitChecks = fitSnap.docs.map((doc) => ({
        id: doc.id,
        ...doc.data(),
      }));

      // Fetch saved looks
      const savedSnap = await db.collection(`users/${uid}/saved_looks`).get();
      const savedLooks = savedSnap.docs.map((doc) => ({
        id: doc.id,
        ...doc.data(),
      }));

      const exportPayload = {
        exportedAt: new Date().toISOString(),
        profile,
        fitChecks,
        savedLooks,
        meta: {
          totalFitChecks: fitChecks.length,
          totalSavedLooks: savedLooks.length,
        },
      };

      res.status(200).json(exportPayload);
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : "Export failed";
      sendError(res, 500, "export_failed", msg);
    }
  }
);
