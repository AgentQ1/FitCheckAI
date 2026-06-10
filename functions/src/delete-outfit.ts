import * as admin from "firebase-admin";
import { onRequest } from "firebase-functions/v2/https";
import { requireAuth, sendError, AuthError } from "./shared/auth";
import { recomputeDailyTrend, dayIdForDate } from "./analyze-outfit";

export const deleteOutfit = onRequest({ timeoutSeconds: 30, invoker: "public" }, async (req, res) => {
  if (req.method === "OPTIONS") { res.set("Access-Control-Allow-Origin", "*").set("Access-Control-Allow-Headers", "authorization, content-type").status(204).send(""); return; }
  res.set("Access-Control-Allow-Origin", "*");

  try {
    const user = await requireAuth(req);

    // Fit check ID from URL path: /deleteOutfit/{fitCheckId}
    const pathParts = req.path.split("/").filter(Boolean);
    const fitCheckId = pathParts[pathParts.length - 1];

    if (!fitCheckId) {
      return void sendError(res, 400, "invalid_input", "fitCheckId is required in URL path");
    }

    const db = admin.firestore();
    const fitCheckRef = db
      .collection("users").doc(user.uid)
      .collection("fit_checks").doc(fitCheckId);

    const snap = await fitCheckRef.get();
    if (!snap.exists) {
      return void sendError(res, 404, "not_found", "Fit check not found");
    }

    // Soft delete
    await fitCheckRef.update({
      isDeleted: true,
      deletedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    res.status(200).json({ deleted: true });

    // Recompute "Today's Best" for the day this check belonged to so the board
    // drops the now-deleted fit (recompute reads only active checks). Never
    // throws; runs after the response so deletion latency is unaffected.
    const createdAt = snap.data()?.createdAt as admin.firestore.Timestamp | undefined;
    const dayId = dayIdForDate(createdAt?.toDate() ?? new Date());
    await recomputeDailyTrend(db, user.uid, dayId);

  } catch (err) {
    if (err instanceof AuthError) return void sendError(res, err.status, err.code, err.message);
    console.error("deleteOutfit error:", err);
    sendError(res, 500, "server_error", "Internal server error");
  }
});
