import * as admin from "firebase-admin";
import { onRequest } from "firebase-functions/v2/https";
import { requireAuth, sendError, AuthError } from "./shared/auth";
import { getOpenAI } from "./shared/openai";
import { randomUUID } from "crypto";

/**
 * Rate the Fit / Arena — Phase 1.
 *
 * Turns the app from single-player AI scoring into a peer-rating loop:
 *   1. user analyzes a fit (existing flow)
 *   2. user opts that fit into the public Arena (`enterArena`)
 *   3. user rates other people's fits 👍/👎 (`getArenaQueue` + `submitPeerRating`)
 *   4. once they've rated 5 others for that fit AND that fit has ≥5 votes, the
 *      Human Fit Score reveals (`getMyArenaResults`)
 *
 * Safety: anonymous aggregate only (never "who voted"), opt-in, binary votes,
 * one report only hides for the reporter, global removal needs a threshold.
 */

// ── Tunable constants ───────────────────────────────────────────────────────
const RATINGS_REQUIRED_TO_UNLOCK = 5; // rate this many OTHER fits to unlock one of yours
const MIN_VOTES_FOR_REVEAL = 5;       // your fit needs this many votes before reveal (Phase 1 = 5, not 10)
const REPORT_THRESHOLD = 3;           // distinct reporters before a fit flips to under_review
const FREE_DAILY_ARENA_POSTS = 1;     // anti-spam: free users may post 1 fit/day
const QUEUE_TARGET = 10;              // fits returned per queue fetch
const QUEUE_SCAN = 60;               // live fits scanned in memory to build the queue

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function todayUTC(): string {
  return new Date().toISOString().split("T")[0];
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

// ─────────────────────────────────────────────────────────────────────────────
// enterArena — opt a fit check into the public Arena
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
      return void sendError(res, 409, "not_analyzed", "Analyze this fit before sharing it to the Arena.");
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
        return void sendError(res, 429, "arena_daily_cap", "You can share 1 fit to the Arena per day on the free plan. Upgrade for more.");
      }
    }

    const storagePath: string | undefined = fit.storagePath;
    if (!storagePath) {
      return void sendError(res, 422, "no_source_image", "Original photo missing — can't share to the Arena.");
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
        return void sendError(res, 422, "moderation_failed", "This photo can't be shared to the Arena.");
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

    // Atomically: create arena doc + unlock tracker, mark the fit, bump the daily counter.
    const today = todayUTC();
    const sameDay = userData.lastArenaPostDate === today;
    const batch = db.batch();
    batch.set(arenaRef, {
      ownerUid: user.uid,
      fitCheckId: fit_check_id,
      imageURL,
      styleGoal: fit.styleGoal ?? "campus",
      aiScore: fit.overallScore,
      upvotes: 0,
      voteCount: 0,
      reportCount: 0,
      status: "live",
      moderation: "approved",
      voteBucket: Math.floor(Math.random() * 1000),
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    batch.set(db.collection("users").doc(user.uid).collection("arenaUnlocks").doc(fit_check_id), {
      ratingsGivenForThisFit: 0,
      isUnlocked: false,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      unlockedAt: null,
    });
    batch.update(fitRef, { arenaPosted: true, arenaPostedAt: admin.firestore.FieldValue.serverTimestamp() });
    batch.set(
      db.collection("users").doc(user.uid),
      { arenaPostsToday: sameDay ? admin.firestore.FieldValue.increment(1) : 1, lastArenaPostDate: today },
      { merge: true }
    );
    await batch.commit();

    console.log(`${tag} ✅ posted fit=${fit_check_id} uid=${user.uid}`);
    res.status(201).json({ fit_id: fit_check_id, status: "live", image_url: imageURL });
  } catch (err) {
    if (err instanceof AuthError) return void sendError(res, err.status, err.code, err.message);
    console.error(`${tag} error:`, (err as Error)?.message, err);
    sendError(res, 500, "server_error", "Couldn't share to the Arena. Try again.");
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// getArenaQueue — serve a batch of other people's live fits to rate
// ─────────────────────────────────────────────────────────────────────────────
export const getArenaQueue = onRequest({ timeoutSeconds: 30, invoker: "public" }, async (req, res) => {
  if (req.method === "OPTIONS") { res.set(CORS).status(204).send(""); return; }
  res.set(CORS);
  const tag = "[getArenaQueue]";

  try {
    const user = await requireAuth(req);
    const blocked: string[] = Array.isArray(req.body?.blocked_uids) ? req.body.blocked_uids : [];
    const db = admin.firestore();

    // Single-field index on `status` only (no composite needed). We over-fetch live
    // fits and rank in memory: low voteCount first (so new fits get seen fast),
    // randomized within. Excludes own/blocked here, already-voted below.
    const snap = await db.collection("rateArena").where("status", "==", "live").limit(QUEUE_SCAN).get();

    let candidates = snap.docs.filter((d) => {
      const data = d.data();
      return data.ownerUid !== user.uid && !blocked.includes(data.ownerUid);
    });

    // Drop fits this user already voted on — one parallel getAll on votes/{me}.
    if (candidates.length > 0) {
      const voteRefs = candidates.map((d) => d.ref.collection("votes").doc(user.uid));
      const voteSnaps = await db.getAll(...voteRefs);
      const votedIds = new Set(voteSnaps.filter((s) => s.exists).map((s) => s.ref.parent.parent!.id));
      candidates = candidates.filter((d) => !votedIds.has(d.id));
    }

    // Low-vote-count bias + random tiebreak so the same fit isn't always first.
    candidates.sort((a, b) => {
      const va = a.data().voteCount ?? 0;
      const vb = b.data().voteCount ?? 0;
      return va !== vb ? va - vb : Math.random() - 0.5;
    });

    const items = candidates.slice(0, QUEUE_TARGET).map((d) => {
      const data = d.data();
      return { fit_id: d.id, image_url: data.imageURL, style_goal: data.styleGoal, ai_score: data.aiScore };
    });

    res.status(200).json({ items, count: items.length });
  } catch (err) {
    if (err instanceof AuthError) return void sendError(res, err.status, err.code, err.message);
    console.error(`${tag} error:`, (err as Error)?.message, err);
    sendError(res, 500, "server_error", "Couldn't load the Arena. Try again.");
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// submitPeerRating — one binary vote, idempotent, credits the rater's unlocks
// ─────────────────────────────────────────────────────────────────────────────
export const submitPeerRating = onRequest({ timeoutSeconds: 30, invoker: "public" }, async (req, res) => {
  if (req.method === "OPTIONS") { res.set(CORS).status(204).send(""); return; }
  res.set(CORS);
  const tag = "[submitPeerRating]";

  try {
    const user = await requireAuth(req);
    const { fit_id, liked } = req.body ?? {};
    if (!fit_id || typeof fit_id !== "string") return void sendError(res, 400, "invalid_input", "fit_id is required");
    if (typeof liked !== "boolean") return void sendError(res, 400, "invalid_input", "liked (boolean) is required");

    const db = admin.firestore();
    const arenaRef = db.collection("rateArena").doc(fit_id);
    const voteRef = arenaRef.collection("votes").doc(user.uid);

    // The vote write is the ONLY source of truth for "did this count". All
    // increments happen iff the vote doc is newly created → idempotent on retry.
    const result = await db.runTransaction(async (tx) => {
      const arenaSnap = await tx.get(arenaRef);
      if (!arenaSnap.exists) throw new ArenaError(404, "not_found", "This fit is no longer in the Arena.");
      const arena = arenaSnap.data()!;
      if (arena.status !== "live") throw new ArenaError(409, "not_live", "This fit is no longer available to rate.");
      if (arena.ownerUid === user.uid) throw new ArenaError(403, "cannot_rate_own", "You can't rate your own fit.");

      const voteSnap = await tx.get(voteRef);
      if (voteSnap.exists) return { counted: false, ownerUid: arena.ownerUid as string };

      tx.create(voteRef, { liked, votedAt: admin.firestore.FieldValue.serverTimestamp() });
      tx.update(arenaRef, {
        voteCount: admin.firestore.FieldValue.increment(1),
        upvotes: admin.firestore.FieldValue.increment(liked ? 1 : 0),
      });
      tx.set(db.collection("users").doc(user.uid), { peerRatingsGiven: admin.firestore.FieldValue.increment(1) }, { merge: true });
      tx.set(db.collection("users").doc(arena.ownerUid), { peerRatingsReceived: admin.firestore.FieldValue.increment(1) }, { merge: true });
      return { counted: true, ownerUid: arena.ownerUid as string };
    });

    // Per-fit unlock credit: a single rating advances ALL of the rater's still-locked
    // posted fits. Done after the vote commits; the vote doc guarantees this can't
    // double-count on retry (re-rating the same fit returns counted:false above).
    let unlockedAny = false;
    if (result.counted) {
      const locked = await db
        .collection("users").doc(user.uid).collection("arenaUnlocks")
        .where("isUnlocked", "==", false).get();
      if (!locked.empty) {
        const batch = db.batch();
        locked.docs.forEach((d) => {
          const given = (d.data().ratingsGivenForThisFit ?? 0) + 1;
          const nowUnlocked = given >= RATINGS_REQUIRED_TO_UNLOCK;
          if (nowUnlocked) unlockedAny = true;
          batch.update(d.ref, {
            ratingsGivenForThisFit: admin.firestore.FieldValue.increment(1),
            ...(nowUnlocked ? { isUnlocked: true, unlockedAt: admin.firestore.FieldValue.serverTimestamp() } : {}),
          });
        });
        await batch.commit();
      }
    }

    res.status(200).json({ ok: true, counted: result.counted, unlocked_any: unlockedAny });
  } catch (err) {
    if (err instanceof ArenaError) return void sendError(res, err.status, err.code, err.message);
    if (err instanceof AuthError) return void sendError(res, err.status, err.code, err.message);
    console.error(`${tag} error:`, (err as Error)?.message, err);
    sendError(res, 500, "server_error", "Couldn't submit your rating. Try again.");
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// getMyArenaResults — the dual-gated Human Fit Score reveal (owner only)
// ─────────────────────────────────────────────────────────────────────────────
export const getMyArenaResults = onRequest({ timeoutSeconds: 30, invoker: "public" }, async (req, res) => {
  if (req.method === "OPTIONS") { res.set(CORS).status(204).send(""); return; }
  res.set(CORS);
  const tag = "[getMyArenaResults]";

  try {
    const user = await requireAuth(req);
    const { fit_id } = req.body ?? {};
    if (!fit_id || typeof fit_id !== "string") return void sendError(res, 400, "invalid_input", "fit_id is required");

    const db = admin.firestore();
    const arenaRef = db.collection("rateArena").doc(fit_id);
    const unlockRef = db.collection("users").doc(user.uid).collection("arenaUnlocks").doc(fit_id);
    const [arenaSnap, unlockSnap] = await Promise.all([arenaRef.get(), unlockRef.get()]);

    if (!arenaSnap.exists) return void sendError(res, 404, "not_found", "This fit isn't in the Arena.");
    const arena = arenaSnap.data()!;
    if (arena.ownerUid !== user.uid) return void sendError(res, 403, "not_owner", "You can only view results for your own fits.");

    const given = unlockSnap.data()?.ratingsGivenForThisFit ?? 0;
    const isUnlocked = unlockSnap.data()?.isUnlocked === true || given >= RATINGS_REQUIRED_TO_UNLOCK;
    const voteCount = arena.voteCount ?? 0;
    const upvotes = arena.upvotes ?? 0;

    // Gate 1: reciprocity.
    if (!isUnlocked) {
      return void res.status(200).json({
        state: "locked_reciprocity",
        ratings_given: given,
        ratings_required: RATINGS_REQUIRED_TO_UNLOCK,
        remaining: Math.max(0, RATINGS_REQUIRED_TO_UNLOCK - given),
      });
    }
    // Gate 2: enough votes received.
    if (voteCount < MIN_VOTES_FOR_REVEAL) {
      return void res.status(200).json({
        state: "locked_votes",
        vote_count: voteCount,
        votes_required: MIN_VOTES_FOR_REVEAL,
        remaining: Math.max(0, MIN_VOTES_FOR_REVEAL - voteCount),
      });
    }

    const approvalPercent = Math.round((upvotes / voteCount) * 100);

    // Percentile within the same style goal among fits with enough votes. Single-field
    // `styleGoal` query, voteCount filtered in memory (avoids a composite index).
    let percentile: number | null = null;
    try {
      const peers = await db.collection("rateArena").where("styleGoal", "==", arena.styleGoal).limit(300).get();
      const approvals = peers.docs
        .map((d) => d.data())
        .filter((d) => (d.voteCount ?? 0) >= MIN_VOTES_FOR_REVEAL)
        .map((d) => (d.upvotes ?? 0) / (d.voteCount ?? 1));
      if (approvals.length > 1) {
        const mine = upvotes / voteCount;
        const atOrBelow = approvals.filter((a) => a <= mine).length;
        percentile = Math.round((atOrBelow / approvals.length) * 100);
      }
    } catch (e) {
      console.warn(`${tag} percentile calc failed:`, (e as Error)?.message);
    }

    res.status(200).json({
      state: "revealed",
      approval_percent: approvalPercent,
      vote_count: voteCount,
      upvotes,
      ai_score: arena.aiScore ?? null,
      percentile,
    });
  } catch (err) {
    if (err instanceof AuthError) return void sendError(res, err.status, err.code, err.message);
    console.error(`${tag} error:`, (err as Error)?.message, err);
    sendError(res, 500, "server_error", "Couldn't load your results. Try again.");
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

    await db.runTransaction(async (tx) => {
      const arenaSnap = await tx.get(arenaRef);
      if (!arenaSnap.exists) throw new ArenaError(404, "not_found", "This fit isn't in the Arena.");
      const reportSnap = await tx.get(reportRef);
      if (reportSnap.exists) return; // idempotent — already reported

      const newCount = (arenaSnap.data()?.reportCount ?? 0) + 1;
      tx.create(reportRef, {
        reason: typeof reason === "string" ? reason.slice(0, 200) : null,
        reportedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      const update: Record<string, unknown> = { reportCount: admin.firestore.FieldValue.increment(1) };
      // One report never removes globally — only flag for review past the threshold,
      // and never override an already-removed fit.
      if (newCount >= REPORT_THRESHOLD && arenaSnap.data()?.status === "live") {
        update.status = "under_review";
      }
      tx.update(arenaRef, update);
    });

    // The client hides it locally regardless; `hidden:true` tells it to do so.
    res.status(200).json({ reported: true, hidden: true });
  } catch (err) {
    if (err instanceof ArenaError) return void sendError(res, err.status, err.code, err.message);
    if (err instanceof AuthError) return void sendError(res, err.status, err.code, err.message);
    console.error(`${tag} error:`, (err as Error)?.message, err);
    sendError(res, 500, "server_error", "Couldn't submit your report. Try again.");
  }
});

class ArenaError extends Error {
  constructor(public readonly status: number, public readonly code: string, message: string) {
    super(message);
  }
}
