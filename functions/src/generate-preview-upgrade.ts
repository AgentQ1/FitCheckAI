import * as admin from "firebase-admin";
import { onRequest } from "firebase-functions/v2/https";
import { toFile } from "openai";
import { requireAuth, sendError, AuthError } from "./shared/auth";
import { getOpenAI } from "./shared/openai";
import { randomUUID } from "crypto";

/**
 * Generates a SINGLE AI-upgraded outfit image (the first improved look) and
 * caches it on the fit-check document. Unlike `generateLookOptions` this is
 * available to free users too — it powers the "AI Outfit Upgrade Preview" card
 * on the result screen, which must show a genuinely transformed outfit rather
 * than the user's original photo.
 *
 * This is a TRUE OUTFIT EDIT, not a fresh text-to-image render. We download the
 * user's original uploaded photo and pass it to `images.edit` (gpt-image-1) as the
 * strong source image, so the result keeps the same person, pose, mirror-selfie
 * framing, background, body proportions, camera angle, and full-body composition —
 * only the outfit elements flagged by the analysis are upgraded. `size: "auto"`
 * preserves the original photo's aspect ratio so shoes/head aren't cropped.
 *
 * The improvement direction comes from the analysis advice: GPT-4o's per-look
 * `image_generation_prompt` (detected outfit + concrete improvements) plus the
 * single highest-impact `bestOneChange`, wrapped in an edit prompt that explicitly
 * instructs the model to preserve the original composition.
 *
 * Idempotent: if a preview was already generated for this fit check, the cached
 * URL is returned immediately so we never pay for generation twice on re-view.
 *
 * Logging: every stage is logged with the `[generatePreviewUpgrade]` prefix so the
 * exact failure point is visible in `firebase functions:log`.
 */

// Bump when the generation pipeline changes meaningfully so cached previews made by
// an older pipeline are invalidated and regenerated on next view.
// v2-edit: image-to-image edit (was text-to-image studio render).
const PREVIEW_VERSION = "v2-edit";

export const generatePreviewUpgrade = onRequest({ timeoutSeconds: 120, invoker: "public" }, async (req, res) => {
  if (req.method === "OPTIONS") { res.set("Access-Control-Allow-Origin", "*").set("Access-Control-Allow-Headers", "authorization, content-type").status(204).send(""); return; }
  res.set("Access-Control-Allow-Origin", "*");

  const tag = "[generatePreviewUpgrade]";

  try {
    const user = await requireAuth(req);
    const { fit_check_id } = req.body ?? {};

    console.log(`${tag} ▶️ start — uid=${user.uid} fit_check_id=${fit_check_id ?? "MISSING"}`);

    if (!fit_check_id) {
      console.error(`${tag} ❌ missing required field: fit_check_id`);
      return void sendError(res, 400, "invalid_input", "fit_check_id is required");
    }

    const db = admin.firestore();
    const fitCheckRef = db.collection("users").doc(user.uid).collection("fit_checks").doc(fit_check_id);
    const fitCheckSnap = await fitCheckRef.get();

    if (!fitCheckSnap.exists || fitCheckSnap.data()?.isDeleted) {
      console.error(`${tag} ❌ fit check not found or deleted — uid=${user.uid} fit_check_id=${fit_check_id}`);
      return void sendError(res, 404, "fit_check_not_found", "Fit check not found");
    }

    const fitCheckData = fitCheckSnap.data()!;

    // Reuse a previously generated preview — keeps the card stable on re-view and
    // avoids duplicate generation cost.
    // Only reuse a cached preview if it was made by the CURRENT generation pipeline.
    // Bumping PREVIEW_VERSION invalidates previews from the old text-to-image path so
    // re-viewing an old fit check regenerates with the new image-to-image edit.
    if (fitCheckData.previewUpgradeUrl && fitCheckData.previewUpgradeVersion === PREVIEW_VERSION) {
      console.log(`${tag} ♻️ returning cached preview (version=${PREVIEW_VERSION}) for fit_check_id=${fit_check_id}`);
      return void res.status(200).json({
        image_url: fitCheckData.previewUpgradeUrl,
        title: fitCheckData.previewUpgradeTitle ?? "Upgraded look",
        status: "done",
      });
    }
    if (fitCheckData.previewUpgradeUrl) {
      console.log(`${tag} 🔄 stale cached preview (version=${fitCheckData.previewUpgradeVersion ?? "none"} ≠ ${PREVIEW_VERSION}) — regenerating with image edit`);
    }

    // Log the fields the upgrade depends on so a missing one is obvious in logs.
    const storagePath: string | undefined = fitCheckData.storagePath;
    const improvedLooks: Array<{
      title: string;
      theme?: string;
      changes?: Array<{ item?: string; change?: string; reason?: string }>;
      image_generation_prompt?: string;
    }> = fitCheckData.improvedLooks ?? [];
    const firstLook = improvedLooks[0];

    console.log(`${tag} fields — originalStoragePath=${storagePath ?? "MISSING"} analysisId=${fit_check_id} ` +
      `improvedLooks=${improvedLooks.length} bestOneChange="${(fitCheckData.bestOneChange ?? "").toString().slice(0, 80)}" ` +
      `changeCount=${firstLook?.changes?.length ?? 0}`);

    if (!firstLook) {
      console.error(`${tag} ❌ no improved_looks in analysis — run analysis first`);
      return void sendError(res, 400, "no_looks", "No improved looks found in analysis. Run analysis first.");
    }

    // The original photo lives in private Storage. We require it: this feature is an
    // EDIT of the real photo, so without the source image there is nothing to upgrade.
    const bucket = admin.storage().bucket();
    if (!storagePath) {
      console.error(`${tag} ❌ no storagePath on fit check — cannot edit a photo that doesn't exist`);
      return void sendError(res, 422, "no_source_image", "Original photo missing. Re-upload to generate an upgrade preview.");
    }

    // Download the user's real uploaded photo — this is the strong source image that
    // anchors identity, pose, framing, background, and full-body composition.
    let originalBuffer: Buffer;
    try {
      const [buf] = await bucket.file(storagePath).download();
      originalBuffer = buf;
    } catch (dlErr) {
      console.error(`${tag} ❌ failed to download original photo at ${storagePath}:`, (dlErr as Error)?.message);
      return void sendError(res, 422, "no_source_image", "Original photo could not be loaded. Try again.");
    }

    const originalMime = detectImageMime(originalBuffer);
    const originalDims = readImageDimensions(originalBuffer);
    console.log(`${tag} 📸 original photo loaded — path=${storagePath} bytes=${originalBuffer.length} ` +
      `mime=${originalMime} dims=${originalDims ? `${originalDims.width}x${originalDims.height} (ar=${(originalDims.width / originalDims.height).toFixed(3)})` : "unknown"}`);

    // Build the EDIT prompt from the analysis's STRUCTURED changes (item/change), NOT
    // the look's `image_generation_prompt`. That field is a scene-painting text-to-image
    // prompt ("full-body studio fashion photo of…") which, even in edit mode, pushes the
    // model to repaint a brand-new catalog photo. The concise change list keeps the edit
    // targeted to the outfit. bestOneChange grounds the single highest-impact tweak.
    const bestOneChange: string = (fitCheckData.bestOneChange ?? "").toString().trim();
    const changeLines = (firstLook.changes ?? [])
      .map((c) => {
        const item = (c?.item ?? "").toString().trim();
        const change = (c?.change ?? "").toString().trim();
        if (!change) return null;
        return item ? `- ${item}: ${change}` : `- ${change}`;
      })
      .filter((l): l is string => !!l);

    const editPrompt = buildEditPrompt(changeLines, bestOneChange);

    console.log(`${tag} 🎨 OpenAI images.edit started — mode=image-to-image-edit model=gpt-image-1 ` +
      `size=auto quality=medium input_fidelity=high sourceBytes=${originalBuffer.length} ` +
      `changeLines=${changeLines.length} promptLen=${editPrompt.length} ` +
      `includesPreserveDirective=${editPrompt.includes("preserve the original composition")}`);
    console.log(`${tag} 📝 exact edit prompt: ${editPrompt}`);

    // gpt-image-1 image-to-image edit: keeps the source photo as the base and applies
    // the prompted outfit changes. `input_fidelity:"high"` strongly preserves the input
    // (same person, face, pose, room, framing) — the key lever against repainting a new
    // photo. size:"auto" matches the input aspect ratio so the full body (head→shoes)
    // stays visible and uncropped. Returns base64 PNG.
    //
    // NOTE: input_fidelity is a valid gpt-image-1 edit field but isn't in this SDK
    // version's TS types yet, so the params object is cast to pass it through (the SDK
    // serializes every body key into the multipart form).
    let imgBase64: string | undefined;
    try {
      const openai = getOpenAI();
      const sourceFile = await toFile(originalBuffer, `original.${mimeExtension(originalMime)}`, { type: originalMime });
      const editParams = {
        model: "gpt-image-1",
        image: sourceFile,
        prompt: editPrompt,
        size: "auto",
        quality: "medium",
        input_fidelity: "high",
        n: 1,
      } as unknown as Parameters<typeof openai.images.edit>[0];
      const imgResp = await openai.images.edit(editParams);
      imgBase64 = imgResp.data?.[0]?.b64_json;
      console.log(`${tag} ✅ OpenAI edit response received — hasImage=${!!imgBase64} bytesB64=${imgBase64?.length ?? 0}`);
    } catch (genErr) {
      console.error(`${tag} ❌ gpt-image-1 edit failed:`, (genErr as Error)?.message, genErr);
      return void sendError(res, 503, "generation_failed", "Couldn't generate the upgrade preview. Try again.");
    }

    if (!imgBase64) {
      console.error(`${tag} ❌ OpenAI returned no image data`);
      return void sendError(res, 503, "generation_failed", "Couldn't generate the upgrade preview. Try again.");
    }

    // Persist the generated image to our own Storage bucket. We attach a Firebase
    // download token in the object metadata and build a tokenized download URL —
    // this works WITHOUT the `iam.serviceAccounts.signBlob` permission that
    // getSignedUrl() requires (which the function's service account is missing).
    const imgBuffer = Buffer.from(imgBase64, "base64");

    // Compare the result's aspect ratio against the original so we can spot a crop or
    // an unexpected full-frame replacement in the logs. A large aspect-ratio drift
    // means the model reframed the shot (e.g. cropped legs/shoes) rather than editing
    // in place — exactly the regression this feature is meant to avoid.
    const resultDims = readImageDimensions(imgBuffer);
    if (resultDims && originalDims) {
      const origAR = originalDims.width / originalDims.height;
      const resAR = resultDims.width / resultDims.height;
      const arDrift = Math.abs(origAR - resAR);
      const likelyCropped = arDrift > 0.15;
      console.log(`${tag} 🔎 composition check — original=${originalDims.width}x${originalDims.height} (ar=${origAR.toFixed(3)}) ` +
        `result=${resultDims.width}x${resultDims.height} (ar=${resAR.toFixed(3)}) arDrift=${arDrift.toFixed(3)} ` +
        `${likelyCropped ? "⚠️ aspect ratio drifted — result may be cropped/reframed" : "aspect ratio preserved — full-body composition intact"}`);
    } else {
      console.log(`${tag} 🔎 composition check — result dims=${resultDims ? `${resultDims.width}x${resultDims.height}` : "unknown"} (original dims unknown, skipped crop comparison)`);
    }

    const genStoragePath = `users/${user.uid}/fit-checks/${fit_check_id}/preview/upgrade.png`;
    const downloadToken = randomUUID();
    await bucket.file(genStoragePath).save(imgBuffer, {
      contentType: "image/png",
      metadata: { metadata: { firebaseStorageDownloadTokens: downloadToken } },
    });
    console.log(`${tag} 💾 storage upload success — ${genStoragePath} (${imgBuffer.length} bytes)`);

    const viewUrl =
      `https://firebasestorage.googleapis.com/v0/b/${bucket.name}/o/` +
      `${encodeURIComponent(genStoragePath)}?alt=media&token=${downloadToken}`;

    // Cache on the fit check so subsequent views reuse it.
    await fitCheckRef.update({
      previewUpgradeUrl: viewUrl,
      previewUpgradeTitle: firstLook.title ?? "Upgraded look",
      previewUpgradeStoragePath: genStoragePath,
      previewUpgradeStatus: "done",
      previewUpgradeVersion: PREVIEW_VERSION,
      previewUpgradeGeneratedAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    console.log(`${tag} 🗂️ Firestore update success — previewUpgradeUrl saved for fit_check_id=${fit_check_id}`);

    res.status(200).json({
      image_url: viewUrl,
      title: firstLook.title ?? "Upgraded look",
      status: "done",
    });
    console.log(`${tag} 🏁 done — fit_check_id=${fit_check_id}`);

  } catch (err) {
    if (err instanceof AuthError) {
      console.error(`${tag} ❌ auth error: ${err.code} ${err.message}`);
      return void sendError(res, err.status, err.code, err.message);
    }
    console.error(`${tag} ❌ unexpected error:`, (err as Error)?.message, err);
    sendError(res, 500, "server_error", "Internal server error");
  }
});

/**
 * Builds the image-EDIT prompt from the analysis's structured change list. The whole
 * point is that gpt-image-1 edits the supplied source photo IN PLACE, so the prompt
 * leads with strong preservation directives, lists only the targeted outfit changes,
 * and ends with explicit negative constraints. It deliberately avoids any
 * "fashion photography / editorial / studio" wording that pushes a brand-new render.
 */
function buildEditPrompt(changeLines: string[], bestOneChange: string): string {
  const sanitize = (s: string) => s.replace(/nude|naked|explicit|sexual|violent/gi, "");

  const changesBlock = (changeLines.length
    ? changeLines.map(sanitize).join("\n")
    : "- Subtly upgrade the top layer, the vest, and the footwear so the outfit looks more styled."
  ).substring(0, 1200);

  const keyChange = bestOneChange ? `\nHighest-impact change: ${sanitize(bestOneChange).substring(0, 200)}` : "";

  return [
    "Realistically edit THIS photo to upgrade only the outfit. This is a photo retouch of the supplied image, not a new image.",
    "",
    "You MUST preserve the original composition exactly: keep the same real person, the same face and identity, the same body shape and proportions, the same pose, the same mirror-selfie framing, the same mirror and its frame, the same room and background, the same lighting, and the same camera angle. Keep the full body visible from head to shoes — do not crop the head, top, legs, or shoes, and do not zoom in or reframe.",
    "",
    "Hands rule: keep hands exactly as they are in the original photo. If a hand is already holding a specific object (e.g. a phone) in the original, keep that exact same object unchanged — do not swap it, duplicate it, or add a new one. If hands are empty or naturally relaxed/clasped in the original, keep them empty or naturally clasped. Never introduce a new object into the hands that wasn't already there.",
    "",
    "Only modify the outfit elements listed below, blending them naturally into the existing lighting, shadows, and photo grain so it still looks like a real casual mirror selfie:",
    changesBlock + keyChange,
    "",
    "Do NOT do any of the following: do not generate a new or different person; do not create a studio, showroom, or plain background; do not produce a catalog-, e-commerce-, or model-style photo; do not change the background, room, floor, wall, or mirror; do not change the pose or framing; do not add a phone, smartphone, camera, selfie stick, handheld device, black rectangle, or any other object into the hands unless that exact object is already clearly visible in the original photo; do not add props or extra accessories anywhere in the frame that weren't in the original photo; do not over-style or restyle the whole outfit; do not change the pants unless explicitly listed; do not invent a totally different outfit concept; do not edit the face or body. The result must look like the same real uploaded mirror selfie, same room and person, just with the outfit improved.",
  ].join("\n");
}

/** Detects image format from magic bytes; defaults to jpeg (the upload format). */
function detectImageMime(buf: Buffer): string {
  if (buf.length >= 8 && buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4e && buf[3] === 0x47) return "image/png";
  if (buf.length >= 12 && buf[8] === 0x57 && buf[9] === 0x45 && buf[10] === 0x42 && buf[11] === 0x50) return "image/webp";
  return "image/jpeg";
}

function mimeExtension(mime: string): string {
  if (mime === "image/png") return "png";
  if (mime === "image/webp") return "webp";
  return "jpg";
}

/**
 * Reads pixel dimensions straight from the file header (PNG / JPEG / WebP) without
 * decoding the whole image — used only for logging the aspect ratio so we can tell
 * from the logs whether the edit preserved the original framing or cropped it.
 */
function readImageDimensions(buf: Buffer): { width: number; height: number } | null {
  try {
    // PNG: IHDR width/height are big-endian uint32 at offsets 16 and 20.
    if (buf.length >= 24 && buf[0] === 0x89 && buf[1] === 0x50) {
      return { width: buf.readUInt32BE(16), height: buf.readUInt32BE(20) };
    }
    // JPEG: scan the start-of-frame (SOFn) markers for the dimensions.
    if (buf.length >= 4 && buf[0] === 0xff && buf[1] === 0xd8) {
      let offset = 2;
      while (offset + 9 < buf.length) {
        if (buf[offset] !== 0xff) { offset++; continue; }
        const marker = buf[offset + 1];
        // SOF0..SOF15, excluding DHT(C4), JPG(C8), DAC(CC) which aren't frame headers.
        if (marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc) {
          return { height: buf.readUInt16BE(offset + 5), width: buf.readUInt16BE(offset + 7) };
        }
        const segLen = buf.readUInt16BE(offset + 2);
        offset += 2 + segLen;
      }
    }
    // WebP (VP8X): canvas size at offset 24, little-endian 24-bit, minus 1.
    if (buf.length >= 30 && buf[12] === 0x56 && buf[13] === 0x50 && buf[14] === 0x38 && buf[15] === 0x58) {
      const width = 1 + (buf[24] | (buf[25] << 8) | (buf[26] << 16));
      const height = 1 + (buf[27] | (buf[28] << 8) | (buf[29] << 16));
      return { width, height };
    }
  } catch {
    // Fall through to null on any malformed header.
  }
  return null;
}
