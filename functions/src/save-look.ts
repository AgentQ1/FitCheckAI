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

    // Upsert saved look
    const savedLookRef = db
      .collection("users").doc(user.uid)
      .collection("saved_looks").doc(fit_check_id);

    await savedLookRef.set({
      fitCheckId: fit_check_id,
      userId: user.uid,
      generatedLookId: generated_look_id ?? null,
      tags: tags ?? [],
      savedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });

    // Increment savedLooksCount in user doc
    await userRef.update({
      savedLooksCount: admin.firestore.FieldValue.increment(1),
    });

    res.status(200).json({ saved: true, saved_look_id: fit_check_id });

  } catch (err) {
    if (err instanceof AuthError) return void sendError(res, err.status, err.code, err.message);
    console.error("saveLook error:", err);
    sendError(res, 500, "server_error", "Internal server error");
  }
});
