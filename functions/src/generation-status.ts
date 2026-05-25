import * as admin from "firebase-admin";
import { onRequest } from "firebase-functions/v2/https";
import { requireAuth, sendError, AuthError } from "./shared/auth";

export const generationStatus = onRequest({ timeoutSeconds: 30 }, async (req, res) => {
  if (req.method === "OPTIONS") { res.set("Access-Control-Allow-Origin", "*").set("Access-Control-Allow-Headers", "authorization, content-type").status(204).send(""); return; }
  res.set("Access-Control-Allow-Origin", "*");

  try {
    const user = await requireAuth(req);

    // Job ID comes from URL path: /generationStatus/{jobId}
    const pathParts = req.path.split("/").filter(Boolean);
    const jobId = pathParts[pathParts.length - 1];

    if (!jobId) {
      return void sendError(res, 400, "invalid_input", "jobId is required in URL path");
    }

    const db = admin.firestore();
    const jobSnap = await db
      .collection("users").doc(user.uid)
      .collection("generation_jobs").doc(jobId)
      .get();

    if (!jobSnap.exists) {
      return void sendError(res, 404, "job_not_found", "Generation job not found");
    }

    const job = jobSnap.data()!;

    if (job.status !== "done") {
      res.status(200).json({ status: job.status, generated_looks: null });
      return;
    }

    res.status(200).json({
      status: job.status,
      generated_looks: job.resultsJson ?? [],
    });

  } catch (err) {
    if (err instanceof AuthError) return void sendError(res, err.status, err.code, err.message);
    console.error("generationStatus error:", err);
    sendError(res, 500, "server_error", "Internal server error");
  }
});
