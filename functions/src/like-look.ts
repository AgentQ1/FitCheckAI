import * as admin from "firebase-admin";
import { onRequest } from "firebase-functions/v2/https";
import { requireAuth, sendError, AuthError } from "./shared/auth";

export const likeLook = onRequest({ timeoutSeconds: 30 }, async (req, res) => {
  if (req.method === "OPTIONS") { res.set("Access-Control-Allow-Origin", "*").set("Access-Control-Allow-Headers", "authorization, content-type").status(204).send(""); return; }
  res.set("Access-Control-Allow-Origin", "*");

  try {
    const user = await requireAuth(req);
    const { fit_check_id, liked } = req.body;

    if (!fit_check_id || typeof liked !== "boolean") {
      return void sendError(res, 400, "invalid_input", "fit_check_id and liked (boolean) are required");
    }

    const db = admin.firestore();
    await db
      .collection("users").doc(user.uid)
      .collection("fit_checks").doc(fit_check_id)
      .update({ liked });

    res.status(200).json({ liked });

  } catch (err) {
    if (err instanceof AuthError) return void sendError(res, err.status, err.code, err.message);
    console.error("likeLook error:", err);
    sendError(res, 500, "server_error", "Internal server error");
  }
});
