import * as admin from "firebase-admin";
import { onRequest } from "firebase-functions/v2/https";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { requireAuth, sendError, AuthError } from "./shared/auth";
import { getOpenAI } from "./shared/openai";
import { currentWeekId, dayIdForDate } from "./analyze-outfit";
import { randomUUID } from "crypto";

/**
 * Arena — Top 3 finalist voting.
 *
 * Arena is no longer a "rate 5 to unlock" swipe queue. It surfaces only the
 * current Top 3 AI-ranked fits for Today and the Top 3 for the Week, and those
 * finalists are the only posts open to public voting.
 *
 *   1. user analyzes a fit (existing flow) — every fit has an AI overallScore
 *   2. if the fit scores >= 6.5 the user may post it to the Arena (`enterArena`)
 *   3. a recompute marks the top 3 posted fits (by AI score) as finalists for
 *      the day / week; everyone else drops out automatically
 *   4. the public votes "Hot Fit 🔥" and comments on the finalists
 *      (`voteHotFit`, `postArenaComment`); display order within the Top 3 is by
 *      Hot Fit count, AI score tie-break, then createdAt
 *
 * Safety: opt-in, one vote per user per fit, owner can't vote on their own fit,
 * outfit-focused comments only, one report hides for the reporter, global
 * removal needs a threshold.
 */

// ── Tunable constants ───────────────────────────────────────────────────────
const ARENA_MIN_SCORE = 6.5;        // a fit must score at least this to enter the Arena
const ARENA_FINALISTS = 3;          // Top N finalists shown per period
const REPORT_THRESHOLD = 3;         // distinct reporters before a fit flips to under_review
const FREE_DAILY_ARENA_POSTS = 1;   // anti-spam: free users may post 1 fit/day
const COMMENT_MAX_LEN = 120;        // outfit-focused comment cap
const COMMENT_FETCH_LIMIT = 50;     // comments returned per fetch

// Outfit-focused quick chips. Free-text is also allowed (validated), but tags
// are restricted to this set so the comment surface stays about the clothes.
const ALLOWED_COMMENT_TAGS = new Set([
  "Clean fit",
  "Good colors",
  "Would wear this",
  "Needs better shoes",
  "Too basic",
  "Fit issue",
]);

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function todayUTC(): string {
  return dayIdForDate(new Date());
}

/** Builds a tokenized Firebase Storage download URL (no signBlob permission needed). */
function tokenUrl(bucketName: string, path: string, token: string): string {
  return (
    `https://firebasestorage.googleapis.com/v0/b/${bucketName}/o/` +
    `${encodeURIComponent(path)}?alt=media&token=${token}`
  );
}

/** Magic-byte sniff; defaults to jpeg (the upload format). */
function detectMime(buf: Buffer): { mime: string; ext: string } {
  if (buf.length >= 4 && buf[0] === 0x89 && buf[1] === 0x50) return { mime: "image/png", ext: "png" };
  if (buf.length >= 12 && buf[8] === 0x57 && buf[9] === 0x45) return { mime: "image/webp", ext: "webp" };
  return { mime: "image/jpeg", ext: "jpg" };
}

class ArenaError extends Error {
  constructor(public readonly status: number, public readonly code: string, message: string) {
    super(message);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// enterArena — post a fit (score >= 6.5) into the public Arena
// ─────────────────────────────────────────────────────────────────────────────
export const enterArena = onRequest({ timeoutSeconds: 60, invoker: "public" }, async (req, res) => {
  if (req.method === "OPTIONS") { res.set(CORS).status(204).send(""); return; }
  res.set(CORS);
  const tag = "[enterArena]";

  try {
    if (req.method !== "POST") return void sendError(res, 405, "method_not_allowed", "POST only");
    const user = await requireAuth(req);
    const { fit_check_id } = req.body ?? {};
    if (!fit_check_id || typeof fit_check_id !== "string") {
      return void sendError(res, 400, "invalid_input", "fit_check_id is required");
    }

    const db = admin.firestore();
    const fitRef = db.collection("users").doc(user.uid).collection("fit_checks").doc(fit_check_id);
    const arenaRef = db.collection("rateArena").doc(fit_check_id);

    const [fitSnap, arenaSnap, userSnap] = await Promise.all([
      fitRef.get(),
      arenaRef.get(),
      db.collection("users").doc(user.uid).get(),
    ]);

    if (!fitSnap.exists || fitSnap.data()?.isDeleted) {
      return void sendError(res, 404, "fit_check_not_found", "Fit check not found");
    }
    const fit = fitSnap.data()!;
    if (fit.status !== "analyzed" || typeof fit.overallScore !== "number") {
      return void sendError(res, 409, "not_analyzed", "Analyze this fit before posting it to the Arena.");
    }
    // Eligibility gate: only fits scoring >= 6.5 may enter the Arena.
    if (fit.overallScore < ARENA_MIN_SCORE) {
      return void sendError(res, 422, "not_eligible", "Score 6.5+ to enter Arena. Improve your fit and try again.");
    }

    // Idempotent: already in the Arena → just report current state.
    if (arenaSnap.exists) {
      console.log(`${tag} already posted — fit=${fit_check_id}`);
      return void res.status(200).json({ fit_id: fit_check_id, status: arenaSnap.data()?.status ?? "live", already_posted: true });
    }

    // Anti-spam daily cap (free tier).
    const userData = userSnap.data() ?? {};
    const isPremium = (userData.subscriptionTier ?? "free") !== "free";
    if (!isPremium) {
      const today = todayUTC();
      const postsToday = userData.lastArenaPostDate === today ? (userData.arenaPostsToday ?? 0) : 0;
      if (postsToday >= FREE_DAILY_ARENA_POSTS) {
        return void sendError(res, 429, "arena_daily_cap", "You can post 1 fit to the Arena per day on the free plan. Upgrade for more.");
      }
    }

    const storagePath: string | undefined = fit.storagePath;
    if (!storagePath) {
      return void sendError(res, 422, "no_source_image", "Original photo missing — can't post to the Arena.");
    }

    // Download the original photo for moderation + the public copy.
    const bucket = admin.storage().bucket();
    let buf: Buffer;
    try {
      [buf] = await bucket.file(storagePath).download();
    } catch (e) {
      console.error(`${tag} download failed ${storagePath}:`, (e as Error)?.message);
      return void sendError(res, 422, "no_source_image", "Original photo could not be loaded.");
    }
    const { mime, ext } = detectMime(buf);

    // Moderation gate. Flagged → reject. On API error we fail OPEN (the fit already
    // passed analyze-outfit's "is this an outfit" check), but log it loudly.
    try {
      const dataUrl = `data:${mime};base64,${buf.toString("base64")}`;
      const mod = await (getOpenAI() as any).moderations.create({
        model: "omni-moderation-latest",
        input: [{ type: "image_url", image_url: { url: dataUrl } }],
      });
      if (mod?.results?.[0]?.flagged) {
        console.warn(`${tag} moderation flagged fit=${fit_check_id} cats=${JSON.stringify(mod.results[0].categories)}`);
        return void sendError(res, 422, "moderation_failed", "This photo can't be posted to the Arena.");
      }
    } catch (e) {
      console.error(`${tag} moderation call failed (failing open):`, (e as Error)?.message);
    }

    // Public copy with a download token.
    const publicPath = `arena/${fit_check_id}/image.${ext}`;
    const token = randomUUID();
    await bucket.file(publicPath).save(buf, {
      contentType: mime,
      metadata: { metadata: { firebaseStorageDownloadTokens: token } },
    });
    const imageURL = tokenUrl(bucket.name, publicPath, token);

    // Denormalize the owner's public identity so finalist cards render the user
    // NAME (not a style label) without a second per-fit read.
    const ownerDisplayName: string | null = userData.displayName ?? null;
    const ownerPhotoURL: string | null = userData.photoURL ?? userData.avatarURL ?? null;

    const dayId = todayUTC();
    const weekId = currentWeekId();
    const today = todayUTC();
    const sameDay = userData.lastArenaPostDate === today;

    const batch = db.batch();
    batch.set(arenaRef, {
      ownerUid: user.uid,
      fitCheckId: fit_check_id,
      imageURL,
      ownerDisplayName,
      ownerPhotoURL,
      styleGoal: fit.styleGoal ?? null,
      aiScore: fit.overallScore,
      hotFitCount: 0,
      voteCount: 0,
      commentCount: 0,
      reportCount: 0,
      dayId,
      weekId,
      isTodayFinalist: false,
      isWeekFinalist: false,
      todayRank: null,
      weekRank: null,
      status: "live",
      moderation: "approved",
      isDeleted: false,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    batch.update(fitRef, { arenaPosted: true, arenaPostedAt: admin.firestore.FieldValue.serverTimestamp() });
    batch.set(
      db.collection("users").doc(user.uid),
      { arenaPostsToday: sameDay ? admin.firestore.FieldValue.increment(1) : 1, lastArenaPostDate: today },
      { merge: true }
    );
    await batch.commit();

    // A new post can enter the Top 3 → recompute both boards. Never throws.
    await recomputeTodayArenaFinalists(db, dayId).catch((e) =>
      console.error(`${tag} recomputeToday failed:`, (e as Error)?.message));
    await recomputeWeekArenaFinalists(db, weekId).catch((e) =>
      console.error(`${tag} recomputeWeek failed:`, (e as Error)?.message));

    console.log(`${tag} ✅ posted fit=${fit_check_id} uid=${user.uid} score=${fit.overallScore}`);
    res.status(201).json({ fit_id: fit_check_id, status: "live", image_url: imageURL });
  } catch (err) {
    if (err instanceof AuthError) return void sendError(res, err.status, err.code, err.message);
    console.error(`${tag} error:`, (err as Error)?.message, err);
    sendError(res, 500, "server_error", "Couldn't post to the Arena. Try again.");
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// getArenaFinalists — the public Top 3 for Today or Week
// ─────────────────────────────────────────────────────────────────────────────
export const getArenaFinalists = onRequest({ timeoutSeconds: 30, invoker: "public" }, async (req, res) => {
  if (req.method === "OPTIONS") { res.set(CORS).status(204).send(""); return; }
  res.set(CORS);
  const tag = "[getArenaFinalists]";

  try {
    const user = await requireAuth(req);
    const tab = (req.body?.tab === "week" ? "week" : "today") as "today" | "week";
    const db = admin.firestore();

    const periodField = tab === "week" ? "weekId" : "dayId";
    const periodValue = tab === "week" ? currentWeekId() : todayUTC();
    const finalistField = tab === "week" ? "isWeekFinalist" : "isTodayFinalist";

    // Single-field query on the period id; filter finalist flag in memory (a
    // period holds at most a few dozen posts) so no composite index is needed.
    const snap = await db.collection("rateArena").where(periodField, "==", periodValue).get();
    let finalists = snap.docs.filter((d) => {
      const x = d.data();
      return x[finalistField] === true && x.status === "live" && x.isDeleted !== true;
    });

    // Display order within the Top 3: Hot Fit count desc → AI score desc → oldest first.
    finalists.sort((a, b) => {
      const da = a.data(), dbb = b.data();
      const ha = da.hotFitCount ?? 0, hb = dbb.hotFitCount ?? 0;
      if (hb !== ha) return hb - ha;
      const sa = da.aiScore ?? 0, sb = dbb.aiScore ?? 0;
      if (sb !== sa) return sb - sa;
      const ca = (da.createdAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? 0;
      const cb = (dbb.createdAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? 0;
      return ca - cb;
    });
    finalists = finalists.slice(0, ARENA_FINALISTS);

    // Which of these has the caller already Hot-Fit'd? One getAll on votes/{me}.
    let votedIds = new Set<string>();
    if (finalists.length > 0) {
      const voteRefs = finalists.map((d) => d.ref.collection("votes").doc(user.uid));
      const voteSnaps = await db.getAll(...voteRefs);
      votedIds = new Set(voteSnaps.filter((s) => s.exists).map((s) => s.ref.parent.parent!.id));
    }

    const items = finalists.map((d, i) => {
      const x = d.data();
      return {
        fit_id: d.id,
        image_url: x.imageURL,
        owner_uid: x.ownerUid,
        owner_display_name: x.ownerDisplayName ?? null,
        owner_photo_url: x.ownerPhotoURL ?? null,
        ai_score: x.aiScore ?? null,
        hot_fit_count: x.hotFitCount ?? 0,
        comment_count: x.commentCount ?? 0,
        rank: i + 1,
        style_goal: x.styleGoal ?? null,
        has_voted: votedIds.has(d.id),
        is_owner: x.ownerUid === user.uid,
      };
    });

    res.status(200).json({ tab, count: items.length, items });
  } catch (err) {
    if (err instanceof AuthError) return void sendError(res, err.status, err.code, err.message);
    console.error(`${tag} error:`, (err as Error)?.message, err);
    sendError(res, 500, "server_error", "Couldn't load the Arena. Try again.");
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// voteHotFit — one "Hot Fit 🔥" vote per user per fit, idempotent
// ─────────────────────────────────────────────────────────────────────────────
export const voteHotFit = onRequest({ timeoutSeconds: 30, invoker: "public" }, async (req, res) => {
  if (req.method === "OPTIONS") { res.set(CORS).status(204).send(""); return; }
  res.set(CORS);
  const tag = "[voteHotFit]";

  try {
    const user = await requireAuth(req);
    const { fit_id } = req.body ?? {};
    if (!fit_id || typeof fit_id !== "string") return void sendError(res, 400, "invalid_input", "fit_id is required");

    const db = admin.firestore();
    const arenaRef = db.collection("rateArena").doc(fit_id);
    const voteRef = arenaRef.collection("votes").doc(user.uid);

    // The vote doc is the ONLY source of truth for "did this count". The counter
    // bumps iff the vote doc is newly created → idempotent on retry / double-tap.
    const result = await db.runTransaction(async (tx) => {
      const arenaSnap = await tx.get(arenaRef);
      if (!arenaSnap.exists) throw new ArenaError(404, "not_found", "This fit is no longer in the Arena.");
      const arena = arenaSnap.data()!;
      if (arena.status !== "live" || arena.isDeleted === true) throw new ArenaError(409, "not_live", "This fit is no longer available.");
      if (arena.ownerUid === user.uid) throw new ArenaError(403, "cannot_rate_own", "You can't Hot Fit your own post.");

      const voteSnap = await tx.get(voteRef);
      if (voteSnap.exists) {
        return { counted: false, hotFitCount: arena.hotFitCount ?? 0 };
      }
      tx.create(voteRef, { liked: true, createdAt: admin.firestore.FieldValue.serverTimestamp() });
      tx.update(arenaRef, {
        hotFitCount: admin.firestore.FieldValue.increment(1),
        voteCount: admin.firestore.FieldValue.increment(1),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      return { counted: true, hotFitCount: (arena.hotFitCount ?? 0) + 1 };
    });

    console.log(`${tag} uid=${user.uid} fit=${fit_id} counted=${result.counted}`);
    res.status(200).json({
      ok: true,
      counted: result.counted,
      hot_fit_count: result.hotFitCount,
      reason: result.counted ? null : "already_voted",
    });
  } catch (err) {
    if (err instanceof ArenaError) return void sendError(res, err.status, err.code, err.message);
    if (err instanceof AuthError) return void sendError(res, err.status, err.code, err.message);
    console.error(`${tag} error:`, (err as Error)?.message, err);
    sendError(res, 500, "server_error", "Couldn't submit your vote. Try again.");
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// postArenaComment — outfit-focused comment (quick chips + optional ≤120 chars)
// ─────────────────────────────────────────────────────────────────────────────
export const postArenaComment = onRequest({ timeoutSeconds: 30, invoker: "public" }, async (req, res) => {
  if (req.method === "OPTIONS") { res.set(CORS).status(204).send(""); return; }
  res.set(CORS);
  const tag = "[postArenaComment]";

  try {
    const user = await requireAuth(req);
    const { fit_id, text, tags } = req.body ?? {};
    if (!fit_id || typeof fit_id !== "string") return void sendError(res, 400, "invalid_input", "fit_id is required");

    const cleanText = typeof text === "string" ? text.trim().slice(0, COMMENT_MAX_LEN) : "";
    const cleanTags: string[] = Array.isArray(tags)
      ? tags.filter((t) => typeof t === "string" && ALLOWED_COMMENT_TAGS.has(t)).slice(0, 6)
      : [];
    if (!cleanText && cleanTags.length === 0) {
      return void sendError(res, 400, "invalid_input", "Add a quick tag or a short note about the fit.");
    }

    const db = admin.firestore();
    const arenaRef = db.collection("rateArena").doc(fit_id);
    const arenaSnap = await arenaRef.get();
    if (!arenaSnap.exists || arenaSnap.data()?.isDeleted === true || arenaSnap.data()?.status !== "live") {
      return void sendError(res, 404, "not_found", "This fit is no longer in the Arena.");
    }

    const userSnap = await db.collection("users").doc(user.uid).get();
    const userData = userSnap.data() ?? {};
    const commenterName: string = userData.displayName ?? "Someone";

    const commentRef = arenaRef.collection("comments").doc();
    await db.runTransaction(async (tx) => {
      tx.create(commentRef, {
        commenterUid: user.uid,
        commenterName,
        text: cleanText,
        tags: cleanTags,
        status: "live",
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      tx.update(arenaRef, {
        commentCount: admin.firestore.FieldValue.increment(1),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    });

    console.log(`${tag} uid=${user.uid} fit=${fit_id} tags=${cleanTags.length} text=${cleanText.length}`);
    res.status(201).json({
      ok: true,
      comment: {
        id: commentRef.id,
        commenter_name: commenterName,
        text: cleanText,
        tags: cleanTags,
      },
    });
  } catch (err) {
    if (err instanceof AuthError) return void sendError(res, err.status, err.code, err.message);
    console.error(`${tag} error:`, (err as Error)?.message, err);
    sendError(res, 500, "server_error", "Couldn't post your comment. Try again.");
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// getArenaComments — live comments for one finalist (newest first)
// ─────────────────────────────────────────────────────────────────────────────
export const getArenaComments = onRequest({ timeoutSeconds: 30, invoker: "public" }, async (req, res) => {
  if (req.method === "OPTIONS") { res.set(CORS).status(204).send(""); return; }
  res.set(CORS);
  const tag = "[getArenaComments]";

  try {
    await requireAuth(req);
    const { fit_id } = req.body ?? {};
    if (!fit_id || typeof fit_id !== "string") return void sendError(res, 400, "invalid_input", "fit_id is required");

    const db = admin.firestore();
    const snap = await db.collection("rateArena").doc(fit_id).collection("comments")
      .orderBy("createdAt", "desc")
      .limit(COMMENT_FETCH_LIMIT)
      .get();

    const items = snap.docs
      .filter((d) => d.data().status === "live")
      .map((d) => {
        const x = d.data();
        return {
          id: d.id,
          commenter_name: x.commenterName ?? "Someone",
          text: x.text ?? "",
          tags: Array.isArray(x.tags) ? x.tags : [],
          created_at: (x.createdAt as admin.firestore.Timestamp | undefined)?.toDate().toISOString() ?? null,
        };
      });

    res.status(200).json({ count: items.length, items });
  } catch (err) {
    if (err instanceof AuthError) return void sendError(res, err.status, err.code, err.message);
    console.error(`${tag} error:`, (err as Error)?.message, err);
    sendError(res, 500, "server_error", "Couldn't load comments. Try again.");
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// reportFit — one report per user; only hides for reporter until threshold/moderation
// ─────────────────────────────────────────────────────────────────────────────
export const reportFit = onRequest({ timeoutSeconds: 30, invoker: "public" }, async (req, res) => {
  if (req.method === "OPTIONS") { res.set(CORS).status(204).send(""); return; }
  res.set(CORS);
  const tag = "[reportFit]";

  try {
    const user = await requireAuth(req);
    const { fit_id, reason } = req.body ?? {};
    if (!fit_id || typeof fit_id !== "string") return void sendError(res, 400, "invalid_input", "fit_id is required");

    const db = admin.firestore();
    const arenaRef = db.collection("rateArena").doc(fit_id);
    const reportRef = arenaRef.collection("reports").doc(user.uid);

    let flippedUnderReview = false;
    let dayId: string | null = null;
    let weekId: string | null = null;

    await db.runTransaction(async (tx) => {
      const arenaSnap = await tx.get(arenaRef);
      if (!arenaSnap.exists) throw new ArenaError(404, "not_found", "This fit isn't in the Arena.");
      const reportSnap = await tx.get(reportRef);
      if (reportSnap.exists) return; // idempotent — already reported

      const data = arenaSnap.data()!;
      const newCount = (data.reportCount ?? 0) + 1;
      tx.create(reportRef, {
        reason: typeof reason === "string" ? reason.slice(0, 200) : null,
        reportedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      const update: Record<string, unknown> = { reportCount: admin.firestore.FieldValue.increment(1) };
      // One report never removes globally — only flag for review past the threshold,
      // and never override an already-removed fit.
      if (newCount >= REPORT_THRESHOLD && data.status === "live") {
        update.status = "under_review";
        flippedUnderReview = true;
        dayId = data.dayId ?? null;
        weekId = data.weekId ?? null;
      }
      tx.update(arenaRef, update);
    });

    // A fit pulled under review must drop out of the finalists immediately.
    if (flippedUnderReview) {
      if (dayId) await recomputeTodayArenaFinalists(db, dayId).catch(() => undefined);
      if (weekId) await recomputeWeekArenaFinalists(db, weekId).catch(() => undefined);
    }

    res.status(200).json({ reported: true, hidden: true });
  } catch (err) {
    if (err instanceof ArenaError) return void sendError(res, err.status, err.code, err.message);
    if (err instanceof AuthError) return void sendError(res, err.status, err.code, err.message);
    console.error(`${tag} error:`, (err as Error)?.message, err);
    sendError(res, 500, "server_error", "Couldn't submit your report. Try again.");
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// Finalist recompute — AI score decides Top 3 membership for a day / week
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Recomputes Today's Top 3 finalists for `dayId`. Eligible = live, not deleted,
 * numeric aiScore >= 6.5. Sort by aiScore desc (oldest first as tie-break), mark
 * the top 3 `isTodayFinalist:true` with `todayRank` 1..3, and clear the flag on
 * everyone else. Only docs whose membership actually changed are written.
 *
 * Single-field `dayId` query keeps this to one period's posts (no composite index).
 * Exported so enterArena / deleteOutfit / the scheduler can reuse it.
 */
export async function recomputeTodayArenaFinalists(
  db: admin.firestore.Firestore,
  dayId = todayUTC()
): Promise<void> {
  await recomputeFinalists(db, "dayId", dayId, "isTodayFinalist", "todayRank");
}

/** Recomputes the Week's Top 3 finalists for `weekId`. See {@link recomputeTodayArenaFinalists}. */
export async function recomputeWeekArenaFinalists(
  db: admin.firestore.Firestore,
  weekId = currentWeekId()
): Promise<void> {
  await recomputeFinalists(db, "weekId", weekId, "isWeekFinalist", "weekRank");
}

async function recomputeFinalists(
  db: admin.firestore.Firestore,
  periodField: "dayId" | "weekId",
  periodValue: string,
  finalistField: "isTodayFinalist" | "isWeekFinalist",
  rankField: "todayRank" | "weekRank"
): Promise<void> {
  const snap = await db.collection("rateArena").where(periodField, "==", periodValue).get();

  const eligible = snap.docs.filter((d) => {
    const x = d.data();
    return x.status === "live" && x.isDeleted !== true && typeof x.aiScore === "number" && x.aiScore >= ARENA_MIN_SCORE;
  });

  // Membership is by AI score (oldest first breaks ties).
  eligible.sort((a, b) => {
    const sa = a.data().aiScore ?? 0, sb = b.data().aiScore ?? 0;
    if (sb !== sa) return sb - sa;
    const ca = (a.data().createdAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? 0;
    const cb = (b.data().createdAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? 0;
    return ca - cb;
  });

  const rankById = new Map<string, number>();
  eligible.slice(0, ARENA_FINALISTS).forEach((d, i) => rankById.set(d.id, i + 1));

  const batch = db.batch();
  let writes = 0;
  for (const d of snap.docs) {
    const cur = d.data();
    const desiredRank = rankById.get(d.id) ?? null;
    const desiredFinalist = desiredRank !== null;
    if ((cur[finalistField] ?? false) !== desiredFinalist || (cur[rankField] ?? null) !== desiredRank) {
      batch.update(d.ref, {
        [finalistField]: desiredFinalist,
        [rankField]: desiredRank,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      writes += 1;
    }
  }
  if (writes > 0) await batch.commit();
  console.log(`[recomputeFinalists] ${periodField}=${periodValue} eligible=${eligible.length} top=${rankById.size} writes=${writes}`);
}

/**
 * When an Arena fit's source check is deleted, tombstone its rateArena doc and
 * recompute the boards it belonged to so it drops out of the Top 3 at once.
 * Exported for delete-outfit. Never throws.
 */
export async function onFitCheckDeleted(
  db: admin.firestore.Firestore,
  fitCheckId: string
): Promise<void> {
  try {
    const arenaRef = db.collection("rateArena").doc(fitCheckId);
    const snap = await arenaRef.get();
    if (!snap.exists) return;
    const data = snap.data()!;
    await arenaRef.update({
      isDeleted: true,
      status: "removed",
      isTodayFinalist: false,
      isWeekFinalist: false,
      todayRank: null,
      weekRank: null,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    if (data.dayId) await recomputeTodayArenaFinalists(db, data.dayId);
    if (data.weekId) await recomputeWeekArenaFinalists(db, data.weekId);
  } catch (e) {
    console.error("[onFitCheckDeleted] failed:", (e as Error)?.message);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// recomputeArenaFinalists — manual/admin recompute of both boards
// ─────────────────────────────────────────────────────────────────────────────
export const recomputeArenaFinalists = onRequest({ timeoutSeconds: 60, invoker: "public" }, async (req, res) => {
  if (req.method === "OPTIONS") { res.set(CORS).status(204).send(""); return; }
  res.set(CORS);
  try {
    await requireAuth(req);
    const db = admin.firestore();
    await recomputeTodayArenaFinalists(db);
    await recomputeWeekArenaFinalists(db);
    res.status(200).json({ ok: true, dayId: todayUTC(), weekId: currentWeekId() });
  } catch (err) {
    if (err instanceof AuthError) return void sendError(res, err.status, err.code, err.message);
    console.error("[recomputeArenaFinalists] error:", (err as Error)?.message, err);
    sendError(res, 500, "server_error", "Recompute failed.");
  }
});

// Scheduled safety-net recompute (hourly): keeps the boards correct across the
// UTC day/week rollover even with no posts, and self-heals any drift.
export const scheduledArenaRecompute = onSchedule("every 60 minutes", async () => {
  const db = admin.firestore();
  await recomputeTodayArenaFinalists(db).catch((e) => console.error("[scheduledArenaRecompute] today:", (e as Error)?.message));
  await recomputeWeekArenaFinalists(db).catch((e) => console.error("[scheduledArenaRecompute] week:", (e as Error)?.message));
});
