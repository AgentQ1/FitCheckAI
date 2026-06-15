import * as admin from "firebase-admin";
import { onRequest } from "firebase-functions/v2/https";
import { requireAuth, sendError, AuthError } from "./shared/auth";

/**
 * Generates ONE Gemini outfit-upgrade image for the carousel. The Gemini API key
 * now lives ONLY here (process.env.GEMINI_API_KEY) — it no longer ships in the app
 * binary. The client sends the fit-check id + the (client-built) edit prompt; we
 * download the user's original photo from Storage (the same source the OpenAI
 * preview uses), run Gemini's image edit, and return the result as base64 so the
 * client's existing in-memory carousel + history persistence keep working unchanged.
 *
 * Two carousel slides differ purely by their prompt (subtle vs. full restyle +
 * styling bias) — the previous "two API keys" trick wasn't what made them differ.
 */

const GEMINI_MODEL = process.env.GEMINI_MODEL || "gemini-2.5-flash-image";
const MAX_PROMPT_LEN = 4000;

export const generateGeminiUpgrade = onRequest({ timeoutSeconds: 120, invoker: "public" }, async (req, res) => {
  if (req.method === "OPTIONS") {
    res.set("Access-Control-Allow-Origin", "*")
      .set("Access-Control-Allow-Headers", "authorization, content-type")
      .status(204).send("");
    return;
  }
  res.set("Access-Control-Allow-Origin", "*");

  const tag = "[generateGeminiUpgrade]";
  try {
    const user = await requireAuth(req);
    const fitCheckId = (req.body?.fit_check_id ?? "").toString().trim();
    const rawPrompt = (req.body?.prompt ?? "").toString();

    if (!fitCheckId) {
      return void sendError(res, 400, "invalid_input", "fit_check_id is required");
    }
    if (!rawPrompt.trim()) {
      return void sendError(res, 400, "invalid_input", "prompt is required");
    }
    if (!process.env.GEMINI_API_KEY) {
      console.error(`${tag} ❌ GEMINI_API_KEY not configured`);
      return void sendError(res, 503, "not_configured", "Image service is not configured.");
    }

    // Defensive sanitize (the client also sanitizes) + cap length.
    const prompt = rawPrompt.replace(/nude|naked|explicit|sexual|violent/gi, "").slice(0, MAX_PROMPT_LEN);

    // Source image is the user's original uploaded photo in private Storage.
    const db = admin.firestore();
    const fitCheckSnap = await db
      .collection("users").doc(user.uid)
      .collection("fit_checks").doc(fitCheckId)
      .get();

    if (!fitCheckSnap.exists || fitCheckSnap.data()?.isDeleted) {
      return void sendError(res, 404, "fit_check_not_found", "Fit check not found");
    }
    const storagePath: string | undefined = fitCheckSnap.data()?.storagePath;
    if (!storagePath) {
      return void sendError(res, 422, "no_source_image", "Original photo missing. Re-upload to generate an upgrade.");
    }

    let originalBuffer: Buffer;
    try {
      const [buf] = await admin.storage().bucket().file(storagePath).download();
      originalBuffer = buf;
    } catch (dlErr) {
      console.error(`${tag} ❌ failed to download ${storagePath}:`, (dlErr as Error)?.message);
      return void sendError(res, 422, "no_source_image", "Original photo could not be loaded. Try again.");
    }

    const mime = detectImageMime(originalBuffer);
    console.log(`${tag} ▶️ uid=${user.uid} fit=${fitCheckId} model=${GEMINI_MODEL} sourceBytes=${originalBuffer.length} mime=${mime} promptLen=${prompt.length}`);

    // Gemini generateContent: [text instruction] + [inline source image] → edited image.
    const body = {
      contents: [{
        parts: [
          { text: prompt },
          { inlineData: { mimeType: mime, data: originalBuffer.toString("base64") } },
        ],
      }],
      generationConfig: { responseModalities: ["IMAGE"] },
    };

    const url = `https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent`;
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 90_000);
    let resp: Response;
    try {
      resp = await fetch(url, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "x-goog-api-key": process.env.GEMINI_API_KEY,
        },
        body: JSON.stringify(body),
        signal: controller.signal,
      });
    } catch (err) {
      console.error(`${tag} ❌ network error calling Gemini:`, (err as Error)?.message);
      return void sendError(res, 503, "generation_failed", "Couldn't generate the upgrade. Try again.");
    } finally {
      clearTimeout(timer);
    }

    const json = await resp.json().catch(() => null) as GeminiResponse | null;
    if (!resp.ok) {
      console.error(`${tag} ❌ Gemini HTTP ${resp.status}:`, JSON.stringify(json?.error ?? {}).slice(0, 300));
      return void sendError(res, 502, "generation_failed", "Image service error. Try again.");
    }

    const imageBase64 = firstInlineImage(json);
    if (!imageBase64) {
      const text = firstText(json) ?? "";
      console.error(`${tag} ❌ no image in response. modelText=${text.slice(0, 160)}`);
      return void sendError(res, 503, "generation_failed", "The image service returned no image. Try again.");
    }

    console.log(`${tag} ✅ done — fit=${fitCheckId} imageB64Len=${imageBase64.length}`);
    res.status(200).json({ image_base64: imageBase64 });
  } catch (err) {
    if (err instanceof AuthError) {
      return void sendError(res, err.status, err.code, err.message);
    }
    console.error(`${tag} ❌ unexpected error:`, (err as Error)?.message);
    sendError(res, 500, "server_error", "Internal server error");
  }
});

// ── Gemini response shapes (proto-JSON, camelCase) ───────────────────────────
interface GeminiResponse {
  candidates?: Array<{ content?: { parts?: Array<{ text?: string; inlineData?: { data?: string } }> } }>;
  error?: { code?: number; message?: string; status?: string };
}

function firstInlineImage(json: GeminiResponse | null): string | undefined {
  for (const c of json?.candidates ?? []) {
    for (const p of c.content?.parts ?? []) {
      if (p.inlineData?.data) return p.inlineData.data;
    }
  }
  return undefined;
}

function firstText(json: GeminiResponse | null): string | undefined {
  for (const c of json?.candidates ?? []) {
    for (const p of c.content?.parts ?? []) {
      if (p.text) return p.text;
    }
  }
  return undefined;
}

/** Detects image format from magic bytes; defaults to jpeg (the upload format). */
function detectImageMime(buf: Buffer): string {
  if (buf.length >= 4 && buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4e && buf[3] === 0x47) return "image/png";
  if (buf.length >= 12 && buf[8] === 0x57 && buf[9] === 0x45 && buf[10] === 0x42 && buf[11] === 0x50) return "image/webp";
  return "image/jpeg";
}
