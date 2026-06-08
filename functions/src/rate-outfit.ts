import { onRequest } from "firebase-functions/v2/https";
import * as admin from "firebase-admin";
import { requireAuth, sendError } from "./shared/auth";

const db = admin.firestore();

export const rateOutfit = onRequest(
  { timeoutSeconds: 30, cors: true, invoker: "public" },
  async (req, res) => {
    if (req.method === "OPTIONS") { res.status(204).send(""); return; }
    if (req.method !== "POST") { res.status(405).json({ error: "method_not_allowed" }); return; }

    let uid: string;
    try {
      const auth = await requireAuth(req);
      uid = auth.uid;
    } catch (err) {
      sendError(res, 401, "unauthorized", "Invalid or expired token");
      return;
    }

    const { fit_check_id, thumbs, stars, feedback } = req.body as {
      fit_check_id?: string;
      thumbs?: string;
      stars?: number;
      feedback?: string;
    };

    if (!fit_check_id) {
      sendError(res, 400, "missing_field", "fit_check_id is required");
      return;
    }

    // Validate stars range
    const validatedStars = typeof stars === "number" ? Math.min(5, Math.max(0, Math.round(stars))) : 0;
    // Validate thumbs
    const validatedThumbs = thumbs === "up" || thumbs === "down" ? thumbs : null;

    const fitCheckRef = db.collection(`users/${uid}/fit_checks`).doc(fit_check_id);
    const snap = await fitCheckRef.get();

    if (!snap.exists) {
      sendError(res, 404, "not_found", "Fit check not found");
      return;
    }

    const updateData: Record<string, unknown> = {
      ratedAt: admin.firestore.FieldValue.serverTimestamp(),
    };
    if (validatedThumbs) updateData["userRatingThumb"] = validatedThumbs;
    if (validatedStars > 0) updateData["userRatingStars"] = validatedStars;
    if (feedback && feedback.trim().length > 0) {
      updateData["userRatingFeedback"] = feedback.trim().slice(0, 500);
    }

    await fitCheckRef.update(updateData);

    res.status(200).json({ rated: true });
  }
);
