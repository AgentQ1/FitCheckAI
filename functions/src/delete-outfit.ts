import * as admin from "firebase-admin";
import { onRequest } from "firebase-functions/v2/https";
import { requireAuth, sendError, AuthError } from "./shared/auth";
import { recomputeDailyTrend, dayIdForDate, recomputeUserStats } from "./analyze-outfit";
import { onFitCheckDeleted } from "./arena";

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

    // Recompute the user's aggregate stats (total/avg/best/streak) and "Today's
    // Best" BEFORE responding. Both read only active checks, so the deleted fit
    // drops out. Done before the response because HTTP functions throttle CPU once
    // the response is flushed — post-response awaits don't reliably run, which would
    // leave Profile stale after a delete. Both are wrapped so a hiccup can't fail
    // the delete itself.
    const createdAt = snap.data()?.createdAt as admin.firestore.Timestamp | undefined;
    const dayId = dayIdForDate(createdAt?.toDate() ?? new Date());
    await recomputeUserStats(db, user.uid)
      .catch((e) => console.error("[deleteOutfit] recomputeUserStats failed:", (e as Error)?.message));
    await recomputeDailyTrend(db, user.uid, dayId);
    // If this fit was posted to the Arena, tombstone it and drop it from the
    // Top 3 finalists. Never throws.
    await onFitCheckDeleted(db, fitCheckId);

    res.status(200).json({ deleted: true });

  } catch (err) {
    if (err instanceof AuthError) return void sendError(res, err.status, err.code, err.message);
    console.error("deleteOutfit error:", err);
    sendError(res, 500, "server_error", "Internal server error");
  }
});
