import * as admin from "firebase-admin";
import { onRequest } from "firebase-functions/v2/https";
import sharp from "sharp";
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

// Longest-edge cap for the source image we hand to Gemini. The original upload is
// stored at full phone resolution (upload-outfit.ts does no resize), which makes
// Gemini's input larger than it needs to be — more input tiles to process (slower
// generation) and a bigger returned image. A 1280px JPEG keeps every bit of outfit
// detail a mirror selfie needs while cutting the payload on both legs of the trip.
const MAX_SOURCE_EDGE = 1280;
const SOURCE_JPEG_QUALITY = 85;

// Per-instance cold-start flag: true only for the very first request a freshly
// spun-up instance serves. Lets the logs attribute a slow call to cold start vs.
// the Gemini generation itself.
let warmInstance = false;

export const generateGeminiUpgrade = onRequest({ timeoutSeconds: 120, invoker: "public" }, async (req, res) => {
  if (req.method === "OPTIONS") {
    res.set("Access-Control-Allow-Origin", "*")
      .set("Access-Control-Allow-Headers", "authorization, content-type")
      .status(204).send("");
    return;
  }
  res.set("Access-Control-Allow-Origin", "*");

  const tag = "[generateGeminiUpgrade]";
  const t0 = Date.now();
  const coldStart = !warmInstance;
  warmInstance = true;
  try {
    const user = await requireAuth(req);
    const fitCheckId = (req.body?.fit_check_id ?? "").toString().trim();
    const rawPrompt = (req.body?.prompt ?? "").toString();
    const slot = (req.body?.slot ?? "").toString().trim();

    if (!fitCheckId) {
      return void sendError(res, 400, "invalid_input", "fit_check_id is required");
    }
    if (!rawPrompt.trim()) {
      return void sendError(res, 400, "invalid_input", "prompt is required");
    }
    // Each carousel slot generates through its OWN Gemini key (so the two parallel
    // images don't share one key's quota/rate limit). Slot B uses GEMINI_API_KEY_2
    // when set; everything else (and any missing fallback) uses GEMINI_API_KEY.
    const apiKey = (slot === "StyleB" && process.env.GEMINI_API_KEY_2)
      ? process.env.GEMINI_API_KEY_2
      : process.env.GEMINI_API_KEY;
    if (!apiKey) {
      console.error(`${tag} ❌ GEMINI_API_KEY not configured`);
      return void sendError(res, 503, "not_configured", "Image service is not configured.");
    }

    // Defensive sanitize (the client also sanitizes) + cap length.
    const prompt = rawPrompt.replace(/nude|naked|explicit|sexual|violent/gi, "").slice(0, MAX_PROMPT_LEN);

    // Source image is the user's original uploaded photo in private Storage.
    const db = admin.firestore();
    const tFsStart = Date.now();
    const fitCheckSnap = await db
      .collection("users").doc(user.uid)
      .collection("fit_checks").doc(fitCheckId)
      .get();
    const firestoreMs = Date.now() - tFsStart;

    if (!fitCheckSnap.exists || fitCheckSnap.data()?.isDeleted) {
      return void sendError(res, 404, "fit_check_not_found", "Fit check not found");
    }
    const storagePath: string | undefined = fitCheckSnap.data()?.storagePath;
    if (!storagePath) {
      return void sendError(res, 422, "no_source_image", "Original photo missing. Re-upload to generate an upgrade.");
    }

    let originalBuffer: Buffer;
    const tDlStart = Date.now();
    try {
      const [buf] = await admin.storage().bucket().file(storagePath).download();
      originalBuffer = buf;
    } catch (dlErr) {
      console.error(`${tag} ❌ failed to download ${storagePath}:`, (dlErr as Error)?.message);
      return void sendError(res, 422, "no_source_image", "Original photo could not be loaded. Try again.");
    }
    const downloadMs = Date.now() - tDlStart;
    const inputBytes = originalBuffer.length;

    // Downscale the full-res original before handing it to Gemini. Falls back to the
    // raw bytes if sharp throws, so a decode quirk never blocks a generation.
    let sourceBuffer = originalBuffer;
    let sourceMime = detectImageMime(originalBuffer);
    let resizeMs = 0;
    try {
      const tRz = Date.now();
      sourceBuffer = await sharp(originalBuffer, { failOn: "none" })
        .rotate() // bake in EXIF orientation before metadata is stripped
        .resize({ width: MAX_SOURCE_EDGE, height: MAX_SOURCE_EDGE, fit: "inside", withoutEnlargement: true })
        .jpeg({ quality: SOURCE_JPEG_QUALITY })
        .toBuffer();
      sourceMime = "image/jpeg";
      resizeMs = Date.now() - tRz;
    } catch (rzErr) {
      console.warn(`${tag} ⚠️ sharp resize failed, sending original bytes:`, (rzErr as Error)?.message);
    }

    const keySlot = (slot === "StyleB" && process.env.GEMINI_API_KEY_2) ? "key2" : "key1";
    console.log(`${tag} ▶️ uid=${user.uid} fit=${fitCheckId} slot=${slot || "?"} key=${keySlot} model=${GEMINI_MODEL} ` +
      `coldStart=${coldStart} inputBytes=${inputBytes} resizedBytes=${sourceBuffer.length} mime=${sourceMime} ` +
      `promptLen=${prompt.length} firestoreMs=${firestoreMs} downloadMs=${downloadMs} resizeMs=${resizeMs}`);

    // Gemini generateContent: [text instruction] + [inline source image] → edited image.
    const body = {
      contents: [{
        parts: [
          { text: prompt },
          { inlineData: { mimeType: sourceMime, data: sourceBuffer.toString("base64") } },
        ],
      }],
      generationConfig: { responseModalities: ["IMAGE"] },
    };

    const url = `https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent`;
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 90_000);
    const tGemini = Date.now();
    let resp: Response;
    try {
      resp = await fetch(url, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "x-goog-api-key": apiKey,
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
    const geminiMs = Date.now() - tGemini;
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

    const outputBytes = Math.floor(imageBase64.length * 0.75); // base64 → raw bytes
    const totalMs = Date.now() - t0;
    console.log(`${tag} ✅ done — fit=${fitCheckId} coldStart=${coldStart} model=${GEMINI_MODEL} ` +
      `inputBytes=${inputBytes} resizedBytes=${sourceBuffer.length} outputBytes=${outputBytes} promptLen=${prompt.length} | ` +
      `firestoreMs=${firestoreMs} downloadMs=${downloadMs} resizeMs=${resizeMs} geminiMs=${geminiMs} totalMs=${totalMs}`);
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
