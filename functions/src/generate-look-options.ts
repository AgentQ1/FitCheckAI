import * as admin from "firebase-admin";
import { onRequest } from "firebase-functions/v2/https";
import { requireAuth, sendError, AuthError } from "./shared/auth";
import { getOpenAI } from "./shared/openai";
import * as https from "https";

export const generateLookOptions = onRequest({ timeoutSeconds: 300, invoker: "public" }, async (req, res) => {
  if (req.method === "OPTIONS") { res.set("Access-Control-Allow-Origin", "*").set("Access-Control-Allow-Headers", "authorization, content-type").status(204).send(""); return; }
  res.set("Access-Control-Allow-Origin", "*");

  try {
    const user = await requireAuth(req);
    const { analysis_id } = req.body;

    if (!analysis_id) {
      return void sendError(res, 400, "invalid_input", "analysis_id is required");
    }

    const db = admin.firestore();
    const userRef = db.collection("users").doc(user.uid);
    const userData = (await userRef.get()).data();

    if (!userData || userData.subscriptionTier === "free") {
      return void sendError(res, 403, "premium_required", "AI outfit generation requires Premium");
    }

    // Fetch the fit check (analysis_id == fit_check_id)
    const fitCheckRef = db.collection("users").doc(user.uid).collection("fit_checks").doc(analysis_id);
    const fitCheckSnap = await fitCheckRef.get();

    if (!fitCheckSnap.exists) {
      return void sendError(res, 404, "analysis_not_found", "Analysis not found");
    }

    const fitCheckData = fitCheckSnap.data()!;
    const improvedLooks: Array<{
      title: string;
      expected_score: number;
      changes: unknown[];
      image_generation_prompt: string;
    }> = fitCheckData.improvedLooks ?? [];

    if (improvedLooks.length === 0) {
      return void sendError(res, 400, "no_looks", "No improved looks found in analysis. Run analysis first.");
    }

    // Create generation job
    const jobRef = db.collection("users").doc(user.uid).collection("generation_jobs").doc();
    const jobId = jobRef.id;

    await jobRef.set({
      fitCheckId: analysis_id,
      userId: user.uid,
      status: "generating",
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    // Respond immediately (202) then run DALL-E generation synchronously within timeout
    res.status(202).json({
      generation_job_id: jobId,
      status: "generating",
      estimated_seconds: 30,
    });

    // Generate images in parallel — each DALL-E call is independent of the
    // others. This drops wall-clock time roughly 3× vs the previous serial loop.
    const openai = getOpenAI();
    const bucket = admin.storage().bucket();

    async function generateOne(look: typeof improvedLooks[number])
      : Promise<{ title: string; image_url: string; expected_score: number; changes: unknown[] } | null> {
      const safePrompt = sanitizeGenerationPrompt(look.image_generation_prompt);
      try {
        const imgResp = await openai.images.generate({
          model: "dall-e-3",
          prompt: safePrompt,
          size: "1024x1792",
          quality: "standard",
          n: 1,
        });

        const imageUrl = imgResp.data?.[0]?.url;
        if (!imageUrl) return null;

        const imgBuffer = await fetchImageBuffer(imageUrl);
        const imageId = `${jobId}_${look.title.replace(/\s+/g, "_").toLowerCase()}`;
        const storagePath = `users/${user.uid}/fit-checks/${analysis_id}/generated/${imageId}.png`;

        await bucket.file(storagePath).save(imgBuffer, { contentType: "image/png" });

        // Use a signed URL with a 7-day expiry instead of makePublic(). That keeps
        // generated outfit photos private to the signed link.
        let viewUrl = "";
        try {
          const [signed] = await bucket.file(storagePath).getSignedUrl({
            action: "read",
            expires: Date.now() + 7 * 24 * 60 * 60 * 1000,
          });
          viewUrl = signed;
        } catch (signErr) {
          console.warn(`[generateLookOptions] getSignedUrl failed for ${storagePath}:`, (signErr as Error)?.message);
          // Fall back to the legacy public URL pattern so the UI still renders.
          viewUrl = `https://storage.googleapis.com/${bucket.name}/${storagePath}`;
        }

        const lookRef = fitCheckRef.collection("generated_looks").doc();
        await lookRef.set({
          fitCheckId: analysis_id,
          userId: user.uid,
          lookType: look.title.toLowerCase().replace(/\s+/g, "_"),
          title: look.title,
          expectedScore: look.expected_score,
          changes: look.changes,
          storagePath,
          imageUrl: viewUrl,
          generationModel: "dall-e-3",
          generationStatus: "done",
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });

        return {
          title: look.title,
          image_url: viewUrl,
          expected_score: look.expected_score,
          changes: look.changes,
        };
      } catch (genErr) {
        console.error(`Generation failed for ${look.title}:`, genErr);
        return null;
      }
    }

    const settled = await Promise.all(improvedLooks.map(generateOne));
    const results = settled.filter((r): r is NonNullable<typeof r> => r !== null);

    await jobRef.update({
      status: results.length > 0 ? "done" : "failed",
      resultsJson: results,
      completedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

  } catch (err) {
    if (err instanceof AuthError) return void sendError(res, err.status, err.code, err.message);
    console.error("generateLookOptions error:", err);
    sendError(res, 500, "server_error", "Internal server error");
  }
});

function sanitizeGenerationPrompt(prompt: string): string {
  const prefix = "Fashion photography, full-body outfit photo, editorial style, realistic, professional lighting. ";
  const suffix = " No face visible. Fashion-focused composition only. No nudity. Photo-realistic style only. " +
    "Hands empty or naturally relaxed at the sides — do not include a phone, smartphone, camera, selfie stick, " +
    "handheld device, black rectangle, or any other prop or accessory in the hands or anywhere in frame.";
  const cleaned = prompt
    .replace(/nude|naked|explicit|sexual|violent/gi, "")
    .substring(0, 900);
  return prefix + cleaned + suffix;
}

function fetchImageBuffer(url: string): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    https.get(url, (response) => {
      const chunks: Buffer[] = [];
      response.on("data", (chunk: Buffer) => chunks.push(chunk));
      response.on("end", () => resolve(Buffer.concat(chunks)));
      response.on("error", reject);
    }).on("error", reject);
  });
}
