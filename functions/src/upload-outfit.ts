import * as admin from "firebase-admin";
import { onRequest } from "firebase-functions/v2/https";
import { requireAuth, sendError, AuthError } from "./shared/auth";

const VALID_MIME_TYPES = ["image/jpeg", "image/png", "image/heic", "image/heif"];
const VALID_GOALS = ["campus", "professional", "date_night", "luxury", "streetwear", "gym", "gen_z", "interview"];
const MAX_FILE_SIZE = 20 * 1024 * 1024;

export const uploadOutfit = onRequest({ timeoutSeconds: 30 }, async (req, res) => {
  if (req.method === "OPTIONS") { res.set("Access-Control-Allow-Origin", "*").set("Access-Control-Allow-Headers", "authorization, content-type").status(204).send(""); return; }
  res.set("Access-Control-Allow-Origin", "*");

  try {
    const user = await requireAuth(req);
    const { file_name, file_size_bytes, mime_type, style_goal } = req.body;

    if (!file_name || typeof file_name !== "string") {
      return void sendError(res, 400, "invalid_input", "file_name is required");
    }
    if (!VALID_MIME_TYPES.includes(mime_type)) {
      return void sendError(res, 400, "invalid_mime_type", "Only JPEG, PNG, and HEIC images are supported");
    }
    if (file_size_bytes > MAX_FILE_SIZE) {
      return void sendError(res, 413, "file_too_large", "Max file size is 20MB");
    }
    if (!VALID_GOALS.includes(style_goal)) {
      return void sendError(res, 400, "invalid_style_goal", "Invalid style goal");
    }

    const db = admin.firestore();
    const userRef = db.collection("users").doc(user.uid);
    const userData = (await userRef.get()).data();

    // Rate limit check
    const checksUsed: number = userData?.dailyChecksUsed ?? 0;
    const freeLimit = 3;
    const tier: string = userData?.subscriptionTier ?? "free";
    const isPremium = tier !== "free";

    if (!isPremium && checksUsed >= freeLimit) {
      return void sendError(res, 429, "rate_limit_exceeded", "Daily check limit reached. Upgrade for unlimited checks.");
    }

    // Create Firestore fit check record
    const fitCheckRef = db.collection("users").doc(user.uid).collection("fit_checks").doc();
    const fitCheckId = fitCheckRef.id;
    const storagePath = `users/${user.uid}/fit-checks/${fitCheckId}/original`;

    await fitCheckRef.set({
      userId: user.uid,
      styleGoal: style_goal,
      storagePath,
      status: "pending",
      isDeleted: false,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      deleteScheduledAt: new Date(Date.now() + 7 * 24 * 60 * 60 * 1000),
    });

    const remaining = isPremium ? 999 : Math.max(0, freeLimit - checksUsed);

    res.status(200).json({
      fit_check_id: fitCheckId,
      storage_path: storagePath,
      checks_remaining: remaining,
    });

  } catch (err) {
    if (err instanceof AuthError) return void sendError(res, err.status, err.code, err.message);
    console.error("uploadOutfit error:", err);
    sendError(res, 500, "server_error", "Internal server error");
  }
});
