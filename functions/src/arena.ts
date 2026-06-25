import * as admin from "firebase-admin";
import { onRequest } from "firebase-functions/v2/https";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { requireAuth, sendError, AuthError } from "./shared/auth";
import { currentWeekId, dayIdForDate } from "./analyze-outfit";

/**
 * Arena — a public-vote battle of at most 3 cards, driven by the Trend board.
 *
 * The Trend leaderboard (dailyTrends / weeklyTrends) ranks PEOPLE by AI score.
 * The Arena turns the top of that board into a votable battle:
 *
 *   1. user analyzes a fit (existing flow) — every fit gets an AI overallScore,
 *      and every public fit is pooled into rateArena (vote storage + "My Arena
 *      Fits"). No score gate.
 *   2. `getArenaFinalists` builds the board for the ACTIVE period (Today vs Week):
 *      it takes the top users on that period's Trend board and represents each by
 *      their BEST fit of the period — so the current #1 Trend user is always a
 *      challenger card. Each user appears once; max 3 cards.
 *   3. the public votes "Hot Fit 🔥" and comments (`voteHotFit`, `postArenaComment`);
 *      display order is votes first, then AI score, then oldest — voting decides rank.
 *
 * Safety: opt-in public profiles only (isPublic === true), one vote per user per fit,
 * owner can't vote on their own fit, outfit-focused comments only, one report
 * hides for the reporter, global removal needs a threshold.
 */

// ── Tunable constants ───────────────────────────────────────────────────────
const ARENA_MIN_SCORE = 6.5;        // legacy AI gate — no longer used to enter the Arena (kept for recompute/back-compat)
const ARENA_CARDS = 3;              // Arena is a public-vote battle of at most this many cards
const ARENA_FINALISTS = 3;          // (legacy) Top N flagged as "finalists" by the cosmetic recompute
const REPORT_THRESHOLD = 3;         // distinct reporters before a fit flips to under_review
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

class ArenaError extends Error {
  constructor(public readonly status: number, public readonly code: string, message: string) {
    super(message);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// autoEnterArena — called by analyzeOutfit to auto-pool an eligible fit
// ─────────────────────────────────────────────────────────────────────────────
/**
 * Auto-enters a freshly analyzed fit into the Arena pool. Connected to the same
 * fit flow the trend leaderboards use: any fit scoring >= 6.5 from a public
 * profile competes for the Top 3 with no manual posting. Upserts the rateArena
 * doc (preserving votes/comments/finalist flags on re-analysis) then recomputes
 * both boards. Never throws — an Arena hiccup must not fail the analysis.
 *
 * @param imageURL a long-lived (signed) URL to the outfit photo for public display.
 */
export async function autoEnterArena(
  db: admin.firestore.Firestore,
  uid: string,
  fitCheckId: string,
  data: {
    overallScore: number;
    styleGoal: string | null;
    imageURL: string;
    ownerDisplayName: string | null;
    ownerPhotoURL: string | null;
  }
): Promise<void> {
  try {
    // No score gate — every public fit is pooled (for "My Arena Fits" + vote
    // storage). The public Arena board itself is Trend-driven (see getArenaFinalists),
    // so pool size never affects what's shown.
    if (typeof data.overallScore !== "number") return;
    if (!data.imageURL) return;

    const arenaRef = db.collection("rateArena").doc(fitCheckId);
    const snap = await arenaRef.get();
    const dayId = todayUTC();
    const weekId = currentWeekId();

    if (!snap.exists) {
      await arenaRef.set({
        ownerUid: uid,
        fitCheckId,
        imageURL: data.imageURL,
        ownerDisplayName: data.ownerDisplayName ?? null,
        ownerPhotoURL: data.ownerPhotoURL ?? null,
        styleGoal: data.styleGoal ?? null,
        aiScore: data.overallScore,
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
        moderation: "auto",
        moderationStatus: "approved",
        isDeleted: false,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    } else {
      // Re-analysis: never resurrect a removed fit; otherwise refresh the
      // score/image/identity but keep votes, comments, and finalist flags.
      if (snap.data()?.status === "removed") return;
      await arenaRef.update({
        aiScore: data.overallScore,
        imageURL: data.imageURL,
        ownerDisplayName: data.ownerDisplayName ?? null,
        ownerPhotoURL: data.ownerPhotoURL ?? null,
        styleGoal: data.styleGoal ?? null,
        dayId,
        weekId,
        isDeleted: false,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }

    // Also flag the source fit so the app can show "you're in the Arena race".
    await db.collection("users").doc(uid).collection("fit_checks").doc(fitCheckId)
      .update({ arenaPosted: true, arenaPostedAt: admin.firestore.FieldValue.serverTimestamp() })
      .catch(() => undefined);

    await recomputeTodayArenaFinalists(db, dayId);
    await recomputeWeekArenaFinalists(db, weekId);
    console.log(`[autoEnterArena] ✅ pooled fit=${fitCheckId} uid=${uid} score=${data.overallScore}`);
  } catch (e) {
    console.error(`[autoEnterArena] failed fit=${fitCheckId}:`, (e as Error)?.message);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ensureArenaEntry — idempotent backfill / self-heal for one of the user's fits
// ─────────────────────────────────────────────────────────────────────────────
/**
 * Guarantees the caller's fit is in the Arena pool if it qualifies, and reports
 * its true state. Called by the Result/Analysis CTA so the card never lies:
 *   - fit already pooled & live → just report state (no re-sign / recompute)
 *   - eligible (>=6.5) + public + missing → sign the image, auto-enter, recompute
 *     (this backfills fits analyzed before auto-entry shipped, and self-heals any
 *      analysis where the auto-enter step failed)
 *   - score < 6.5 → eligible:false   |   private profile → is_public:false
 */
export const ensureArenaEntry = onRequest({ timeoutSeconds: 30, invoker: "public" }, async (req, res) => {
  if (req.method === "OPTIONS") { res.set(CORS).status(204).send(""); return; }
  res.set(CORS);
  const tag = "[ensureArenaEntry]";

  try {
    const user = await requireAuth(req);
    const { fit_check_id } = req.body ?? {};
    if (!fit_check_id || typeof fit_check_id !== "string") {
      return void sendError(res, 400, "invalid_input", "fit_check_id is required");
    }

    const db = admin.firestore();
    const fitRef = db.collection("users").doc(user.uid).collection("fit_checks").doc(fit_check_id);
    const arenaRef = db.collection("rateArena").doc(fit_check_id);
    const [fitSnap, arenaSnap, userSnap] = await Promise.all([
      fitRef.get(), arenaRef.get(), db.collection("users").doc(user.uid).get(),
    ]);

    if (!fitSnap.exists || fitSnap.data()?.isDeleted) {
      return void res.status(200).json({ in_arena: false, eligible: false, is_public: true });
    }
    const fit = fitSnap.data()!;
    const score = fit.overallScore;
    // FAIL-CLOSED (Guideline 1.2): a fit reaches the public Arena ONLY once it has been
    // positively approved by moderation. Anything pending (moderation errored/undetermined)
    // or rejected is held back — never "not rejected" as a default-allow.
    const eligible = typeof score === "number" && score >= ARENA_MIN_SCORE && fit.moderationStatus === "approved";
    const userData = userSnap.data() ?? {};
    // Public participation is OPT-IN: only an explicit isPublic === true publishes.
    const isPublic = userData.isPublic === true;

    // Already pooled (and not removed) → report state without re-doing the work.
    if (arenaSnap.exists && arenaSnap.data()?.status !== "removed") {
      const a = arenaSnap.data()!;
      return void res.status(200).json({
        in_arena: a.status === "live",
        eligible,
        is_public: isPublic,
        is_finalist: a.isTodayFinalist === true || a.isWeekFinalist === true,
        today_rank: a.todayRank ?? null,
      });
    }

    if (!eligible || !isPublic) {
      return void res.status(200).json({ in_arena: false, eligible, is_public: isPublic });
    }

    // Backfill: sign a long-lived image URL, then auto-enter + recompute.
    let imageURL: string | null = (typeof fit.thumbnailURL === "string" ? fit.thumbnailURL : null);
    const storagePath: string | undefined = fit.storagePath;
    if (storagePath) {
      try {
        const [url] = await admin.storage().bucket().file(storagePath).getSignedUrl({
          action: "read",
          expires: Date.now() + 14 * 24 * 60 * 60 * 1000,
        });
        imageURL = url;
      } catch (e) {
        console.warn(`${tag} sign failed:`, (e as Error)?.message);
      }
    }
    if (!imageURL) {
      return void res.status(200).json({ in_arena: false, eligible, is_public: isPublic, reason: "no_image" });
    }

    await autoEnterArena(db, user.uid, fit_check_id, {
      overallScore: score,
      styleGoal: fit.styleGoal ?? null,
      imageURL,
      ownerDisplayName: userData.displayName ?? null,
      ownerPhotoURL: userData.photoURL ?? userData.avatarURL ?? null,
    });

    const after = await arenaRef.get();
    res.status(200).json({
      in_arena: after.exists && after.data()?.status === "live",
      eligible: true,
      is_public: true,
      is_finalist: after.data()?.isTodayFinalist === true || after.data()?.isWeekFinalist === true,
      today_rank: after.data()?.todayRank ?? null,
    });
  } catch (err) {
    if (err instanceof AuthError) return void sendError(res, err.status, err.code, err.message);
    console.error(`${tag} error:`, (err as Error)?.message, err);
    sendError(res, 500, "server_error", "Couldn't check your Arena status.");
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// Arena membership helpers — Trend-driven, period-aware
// ─────────────────────────────────────────────────────────────────────────────

/** Start of the active period in UTC millis, for bounding "best fit of the period". */
function periodStartMillis(tab: "today" | "week", now = new Date()): number {
  const y = now.getUTCFullYear(), m = now.getUTCMonth(), d = now.getUTCDate();
  if (tab === "today") return Date.UTC(y, m, d);          // today 00:00 UTC
  const isoDay = now.getUTCDay() === 0 ? 7 : now.getUTCDay();  // Mon=1 … Sun=7
  return Date.UTC(y, m, d - (isoDay - 1));                // Monday 00:00 UTC of this ISO week
}

type BestFit = { fitId: string; score: number; styleGoal: string | null; storagePath?: string; thumbnailURL?: string };

/**
 * The user's highest-scoring, non-deleted fit analyzed within the period. Reads
 * the user's fit_checks (bounded) and picks the best in memory, so no composite
 * index is required. Ties broken by the more recent analysis.
 */
async function bestFitForUser(db: admin.firestore.Firestore, uid: string, sinceMillis: number): Promise<BestFit | null> {
  const snap = await db.collection("users").doc(uid).collection("fit_checks").get();
  let best: (BestFit & { at: number }) | null = null;
  for (const doc of snap.docs) {
    const x = doc.data();
    if (x.isDeleted === true || typeof x.overallScore !== "number") continue;
    // FAIL-CLOSED (Guideline 1.2): only positively-approved fits may surface on a public
    // board. Skip anything rejected OR pending (moderation errored/undetermined) OR
    // legacy fits analyzed before moderation existed (no moderationStatus field).
    if (x.moderationStatus !== "approved") continue;
    const at = (x.analyzedAt as admin.firestore.Timestamp | undefined)?.toMillis()
            ?? (x.createdAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? 0;
    if (at < sinceMillis) continue;
    if (!best || x.overallScore > best.score || (x.overallScore === best.score && at > best.at)) {
      best = { fitId: doc.id, score: x.overallScore, styleGoal: x.styleGoal ?? null,
               storagePath: x.storagePath, thumbnailURL: x.thumbnailURL, at };
    }
  }
  return best ? { fitId: best.fitId, score: best.score, styleGoal: best.styleGoal,
                  storagePath: best.storagePath, thumbnailURL: best.thumbnailURL } : null;
}

// ─────────────────────────────────────────────────────────────────────────────
// getArenaFinalists — Trend-driven public-vote battle (max 3 cards)
// ─────────────────────────────────────────────────────────────────────────────
/**
 * The Arena is a public-vote battle of at most ARENA_CARDS cards. Membership is
 * driven by the Trend leaderboard for the ACTIVE period (Today vs Week): the top
 * users on that board enter via their BEST fit of the period, so whoever is #1 on
 * the Trend is always an Arena challenger. There is NO score gate. Each user
 * appears at most once (their current best fit). Display order is public votes
 * first, then AI score, then oldest — voting (not AI score) decides Arena rank.
 *
 * Each card's rateArena doc is ensured idempotently here (≤3 writes) so Hot Fit
 * votes and comments persist against the fit; existing votes/comments are kept.
 */
export const getArenaFinalists = onRequest({ timeoutSeconds: 30, invoker: "public" }, async (req, res) => {
  if (req.method === "OPTIONS") { res.set(CORS).status(204).send(""); return; }
  res.set(CORS);
  const tag = "[getArenaFinalists]";

  try {
    const user = await requireAuth(req);
    const tab = (req.body?.tab === "week" ? "week" : "today") as "today" | "week";
    const db = admin.firestore();

    const dayId = todayUTC();
    const weekId = currentWeekId();
    const periodValue = tab === "week" ? weekId : dayId;
    const trendParent = tab === "week" ? `weeklyTrends/${weekId}` : `dailyTrends/${dayId}`;

    // 1) Top public users on the period's Trend board, ranked exactly like the app.
    const trendSnap = await db.collection(`${trendParent}/users`).get();
    type TU = {
      uid: string; displayName: string | null; photoURL: string | null;
      bestScore: number; outfitCount: number; averageToday: number; timeBest: number; totalWeekly: number;
    };
    const users: TU[] = trendSnap.docs
      .filter((doc) => doc.data().isPublic === true)
      .map((doc) => {
        const x = doc.data();
        return {
          uid: doc.id,
          displayName: x.displayName ?? null,
          photoURL: x.photoURL ?? null,
          bestScore: x.bestScore ?? 0,
          outfitCount: x.outfitCount ?? 0,
          averageToday: x.averageScoreToday ?? 0,
          timeBest: (x.timeReachedHighestScoreToday as admin.firestore.Timestamp | undefined)?.toMillis() ?? Number.MAX_SAFE_INTEGER,
          totalWeekly: x.totalWeeklyRating ?? 0,
        };
      });

    if (tab === "today") {
      // Mirrors iOS WeeklyLeaderboardEntry.ranksToday.
      users.sort((a, b) =>
        (b.bestScore - a.bestScore) || (b.outfitCount - a.outfitCount) ||
        (b.averageToday - a.averageToday) || (a.timeBest - b.timeBest));
    } else {
      // Mirrors iOS weeklyTrendScore = average × confidence(min(fits/5,1)).
      const trend = (u: TU) => (u.outfitCount > 0 ? u.totalWeekly / u.outfitCount : 0) * Math.min(u.outfitCount / 5, 1);
      users.sort((a, b) => (trend(b) - trend(a)) || (b.bestScore - a.bestScore));
    }
    const top = users.slice(0, ARENA_CARDS);

    // 2) Each top user → best fit of the period → ensure its rateArena doc.
    const sinceMillis = periodStartMillis(tab);
    type Card = {
      fitId: string; ownerUid: string; imageURL: string | null; displayName: string | null;
      photoURL: string | null; aiScore: number; hotFitCount: number; commentCount: number;
      styleGoal: string | null; createdAt: number;
    };
    const cards: Card[] = [];

    for (const u of top) {
      const best = await bestFitForUser(db, u.uid, sinceMillis);
      if (!best) continue;                                  // no qualifying fit yet → no card

      const arenaRef = db.collection("rateArena").doc(best.fitId);
      const arenaSnap = await arenaRef.get();
      const existing = arenaSnap.exists ? arenaSnap.data()! : null;
      // Skip any fit moderation/reporting already pulled from public view — `removed`
      // (admin/delete) OR `under_review` (crossed the report threshold). Never
      // resurrect it to "live" just because its owner is still a top Trend user.
      if (existing && existing.status !== "live") continue;

      // Image: keep the pooled URL, else the fit's signed thumbnail, else sign storage.
      let imageURL: string | null = (existing?.imageURL as string) ?? best.thumbnailURL ?? null;
      if (!imageURL && best.storagePath) {
        try {
          const [url] = await admin.storage().bucket().file(best.storagePath)
            .getSignedUrl({ action: "read", expires: Date.now() + 14 * 24 * 60 * 60 * 1000 });
          imageURL = url;
        } catch (e) { console.warn(`${tag} sign failed fit=${best.fitId}:`, (e as Error)?.message); }
      }

      const identity = {
        ownerUid: u.uid, fitCheckId: best.fitId, imageURL,
        ownerDisplayName: u.displayName, ownerPhotoURL: u.photoURL,
        styleGoal: best.styleGoal, aiScore: best.score,
        dayId, weekId, status: "live", isDeleted: false,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      };
      if (!existing) {
        await arenaRef.set({
          ...identity, hotFitCount: 0, voteCount: 0, commentCount: 0, reportCount: 0,
          moderation: "auto", createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      } else {
        await arenaRef.update(identity);                    // refresh; preserve votes/comments
      }

      cards.push({
        fitId: best.fitId, ownerUid: u.uid, imageURL,
        displayName: u.displayName, photoURL: u.photoURL, aiScore: best.score,
        hotFitCount: existing?.hotFitCount ?? 0,
        commentCount: existing?.commentCount ?? 0,
        styleGoal: best.styleGoal,
        createdAt: (existing?.createdAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? Date.now(),
      });
    }

    // 3) Display order: public votes first, then AI score, then oldest.
    cards.sort((a, b) => (b.hotFitCount - a.hotFitCount) || (b.aiScore - a.aiScore) || (a.createdAt - b.createdAt));

    // Which cards has the caller already Hot-Fit'd?
    let votedIds = new Set<string>();
    if (cards.length > 0) {
      const voteRefs = cards.map((c) => db.collection("rateArena").doc(c.fitId).collection("votes").doc(user.uid));
      const voteSnaps = await db.getAll(...voteRefs);
      votedIds = new Set(voteSnaps.filter((s) => s.exists).map((s) => s.ref.parent.parent!.id));
    }

    const items = cards.map((c, i) => ({
      fit_id: c.fitId,
      image_url: c.imageURL,
      owner_uid: c.ownerUid,
      owner_display_name: c.displayName,
      owner_photo_url: c.photoURL,
      ai_score: c.aiScore,
      hot_fit_count: c.hotFitCount,
      comment_count: c.commentCount,
      rank: i + 1,
      style_goal: c.styleGoal,
      has_voted: votedIds.has(c.fitId),
      is_owner: c.ownerUid === user.uid,
    }));

    console.log(`${tag} uid=${user.uid} tab=${tab} period=${periodValue} trendUsers=${users.length} top=${top.length} cards=${items.length}`);
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
          commenter_uid: x.commenterUid ?? "",
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
