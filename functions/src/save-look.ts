import * as admin from "firebase-admin";
import { onRequest } from "firebase-functions/v2/https";
import { requireAuth, sendError, AuthError } from "./shared/auth";

export const saveLook = onRequest({ timeoutSeconds: 30, invoker: "public" }, async (req, res) => {
  if (req.method === "OPTIONS") { res.set("Access-Control-Allow-Origin", "*").set("Access-Control-Allow-Headers", "authorization, content-type").status(204).send(""); return; }
  res.set("Access-Control-Allow-Origin", "*");

  try {
    const user = await requireAuth(req);
    const { fit_check_id, generated_look_id, tags } = req.body;

    if (!fit_check_id) {
      return void sendError(res, 400, "invalid_input", "fit_check_id is required");
    }

    const db = admin.firestore();
    const userRef = db.collection("users").doc(user.uid);
    const userData = (await userRef.get()).data();

    // Check free tier save limit
    if (userData?.subscriptionTier === "free") {
      const savedSnap = await db
        .collection("users").doc(user.uid)
        .collection("saved_looks")
        .count().get();
      const count = savedSnap.data().count;
      if (count >= 10) {
        return void sendError(res, 403, "save_limit_reached",
          "Free plan allows up to 10 saved looks. Upgrade for unlimited.");
      }
    }

    // Upsert saved look. The doc ID is DETERMINISTIC (fit_check_id), so re-saving
    // the same outfit must be idempotent: bump savedLooksCount ONLY when the
    // saved-look doc is newly created, never on a repeat save (the old code
    // incremented every time, inflating the count while the doc count stayed at 1).
    // A transaction makes the read-then-increment atomic against concurrent saves.
    const savedLookRef = db
      .collection("users").doc(user.uid)
      .collection("saved_looks").doc(fit_check_id);

    const isNewSave = await db.runTransaction(async (tx) => {
      const existing = await tx.get(savedLookRef);
      tx.set(savedLookRef, {
        fitCheckId: fit_check_id,
        userId: user.uid,
        generatedLookId: generated_look_id ?? null,
        tags: tags ?? [],
        savedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });
      if (!existing.exists) {
        tx.update(userRef, { savedLooksCount: admin.firestore.FieldValue.increment(1) });
      }
      return !existing.exists;
    });

    res.status(200).json({ saved: true, saved_look_id: fit_check_id, already_saved: !isNewSave });

  } catch (err) {
    if (err instanceof AuthError) return void sendError(res, err.status, err.code, err.message);
    console.error("saveLook error:", err);
    sendError(res, 500, "server_error", "Internal server error");
  }
});
