import * as admin from "firebase-admin";
import { onRequest } from "firebase-functions/v2/https";
import { requireAuth, sendError, AuthError } from "./shared/auth";
import { getOpenAI, SYSTEM_PROMPT, buildUserPrompt } from "./shared/openai";

export const analyzeOutfit = onRequest({ timeoutSeconds: 120 }, async (req, res) => {
  if (req.method === "OPTIONS") { res.set("Access-Control-Allow-Origin", "*").set("Access-Control-Allow-Headers", "authorization, content-type").status(204).send(""); return; }
  res.set("Access-Control-Allow-Origin", "*");

  const start = Date.now();

  try {
    const user = await requireAuth(req);
    const { fit_check_id, style_goal } = req.body;

    if (!fit_check_id || !style_goal) {
      return void sendError(res, 400, "invalid_input", "fit_check_id and style_goal are required");
    }

    const db = admin.firestore();
    const fitCheckRef = db.collection("users").doc(user.uid).collection("fit_checks").doc(fit_check_id);
    const fitCheckSnap = await fitCheckRef.get();

    if (!fitCheckSnap.exists || fitCheckSnap.data()?.isDeleted) {
      return void sendError(res, 404, "fit_check_not_found", "Fit check not found");
    }

    const storagePath: string = fitCheckSnap.data()!.storagePath;

    // Download image buffer and encode as base64 data URL — avoids IAM signBlob permission requirement
    const bucket = admin.storage().bucket();
    let imageDataUrl: string;
    try {
      const [buffer] = await bucket.file(storagePath).download();
      const base64 = buffer.toString("base64");
      imageDataUrl = `data:image/jpeg;base64,${base64}`;
    } catch (storageErr) {
      console.error("[analyzeOutfit] Storage download failed:", (storageErr as Error)?.message);
      return void sendError(res, 503, "storage_read_failed", "Could not read outfit photo from storage. Try uploading again.");
    }

    // Call GPT-4o Vision
    const openai = getOpenAI();
    let rawContent: string;

    try {
      const completion = await openai.chat.completions.create({
        model: "gpt-4o",
        max_tokens: 4096,
        messages: [
          { role: "system", content: SYSTEM_PROMPT },
          {
            role: "user",
            content: [
              { type: "image_url", image_url: { url: imageDataUrl, detail: "high" } },
              { type: "text", text: buildUserPrompt(style_goal) },
            ],
          },
        ],
      });
      rawContent = completion.choices[0].message.content ?? "";
    } catch (openaiErr) {
      console.error("OpenAI error:", openaiErr);
      return void sendError(res, 503, "ai_service_unavailable", "AI is temporarily busy. Your check wasn't used. Try again in a moment.");
    }

    // Parse response
    let analysis: Record<string, unknown>;
    try {
      const cleaned = rawContent.replace(/```json\n?/g, "").replace(/```\n?/g, "").trim();
      analysis = JSON.parse(cleaned);
    } catch {
      console.error("JSON parse error, raw:", rawContent.substring(0, 500));
      return void sendError(res, 500, "parse_error", "AI returned unparseable response. Try again.");
    }

    // Handle AI-detected errors
    if (analysis.error) {
      res.status(422).json(analysis);
      return;
    }

    // Save analysis into fit check doc
    await fitCheckRef.update({
      status: "analyzed",
      overallScore: analysis.overall_score,
      colorScore: analysis.color_score,
      fitScore: analysis.fit_score,
      trendScore: analysis.trend_score,
      occasionScore: analysis.occasion_score,
      shoesAccessoriesScore: analysis.shoes_accessories_score,
      photoQualityScore: analysis.photo_quality_score,
      genZScore: analysis.gen_z_score,
      professionalScore: analysis.professional_score,
      dateNightScore: analysis.date_night_score,
      luxuryScore: analysis.luxury_score,
      streetwearScore: analysis.streetwear_score,
      campusScore: analysis.campus_score,
      gymScore: analysis.gym_score,
      interviewScore: analysis.interview_score,
      verdict: analysis.verdict,
      stylePersonality: analysis.style_personality,
      confidenceLevel: analysis.confidence_level,
      whatWorks: analysis.what_works,
      whatToImprove: analysis.what_to_improve,
      bestOneChange: analysis.best_one_change,
      colorAnalysis: analysis.color_analysis,
      detectedItems: analysis.detected_items,
      improvedLooks: analysis.improved_looks,
      modelVersion: "gpt-4o",
      processingTimeMs: Date.now() - start,
      analyzedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    // Update user stats and streak
    await updateUserStats(db, user.uid, analysis.overall_score as number);

    const createdAt = new Date().toISOString();
    res.status(200).json({
      ...analysis,
      id: fit_check_id,
      outfit_id: fit_check_id,
      created_at: createdAt,
      processing_time_ms: Date.now() - start,
    });

  } catch (err) {
    if (err instanceof AuthError) return void sendError(res, err.status, err.code, err.message);
    console.error("[analyzeOutfit] Unexpected error:", (err as Error)?.message, err);
    sendError(res, 500, "server_error", "Analysis failed unexpectedly. Please try again.");
  }
});

async function updateUserStats(
  db: admin.firestore.Firestore,
  uid: string,
  newScore: number
): Promise<void> {
  const userRef = db.collection("users").doc(uid);

  await db.runTransaction(async (tx) => {
    const userSnap = await tx.get(userRef);
    const data = userSnap.data() ?? {};

    const prevTotal: number = data.totalFitChecks ?? 0;
    const prevAvg: number = data.averageScore ?? 0;
    const prevBest: number = data.bestScore ?? 0;
    const prevChecksUsed: number = data.dailyChecksUsed ?? 0;
    const lastCheckDate: string | null = data.lastCheckDate ?? null;
    const streakCount: number = data.streakCount ?? 0;

    const newTotal = prevTotal + 1;
    const newAvg = (prevAvg * prevTotal + newScore) / newTotal;
    const newBest = Math.max(prevBest, newScore);

    const today = new Date().toISOString().split("T")[0];
    const yesterday = new Date(Date.now() - 86400000).toISOString().split("T")[0];
    let newStreak = streakCount;
    if (lastCheckDate === today) {
      // Already checked today — no streak change
    } else if (lastCheckDate === yesterday) {
      newStreak = streakCount + 1;
    } else {
      newStreak = 1;
    }

    tx.update(userRef, {
      totalFitChecks: newTotal,
      averageScore: Math.round(newAvg * 10) / 10,
      bestScore: Math.round(newBest * 10) / 10,
      dailyChecksUsed: prevChecksUsed + 1,
      streakCount: newStreak,
      lastCheckDate: today,
    });
  });
}
