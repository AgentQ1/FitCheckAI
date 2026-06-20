import * as admin from "firebase-admin";
import { onRequest } from "firebase-functions/v2/https";
import { requireAuth, sendError, AuthError } from "./shared/auth";
import { getOpenAI, SYSTEM_PROMPT, buildUserPrompt } from "./shared/openai";
import { autoEnterArena } from "./arena";

export const analyzeOutfit = onRequest({ timeoutSeconds: 120, invoker: "public" }, async (req, res) => {
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

    // Prefer passing OpenAI a short-lived signed URL instead of inlining a base64
    // copy of the image. This halves backend bandwidth and removes a
    // decode→re-encode round-trip. If signing fails (e.g. signBlob permission
    // missing), fall back to the older base64-inline path so the request
    // still succeeds.
    const bucket = admin.storage().bucket();
    let imageRef: { type: "image_url"; image_url: { url: string; detail: "auto" | "high" | "low" } };

    // Reserve "high" detail for premium users — for free users "auto" is
    // ~30–50% faster and still accurate enough for outfit feedback.
    // Read the user doc ONCE here and thread it through the leaderboard writers and
    // arena auto-enter below, so a single analysis no longer re-reads users/{uid}
    // multiple times for the same denormalized fields (displayName/photoURL/isPublic).
    const userSnap = await db.collection("users").doc(user.uid).get();
    const userData = userSnap.data() ?? {};
    const tier: string = userData.subscriptionTier ?? "free";
    const detail: "auto" | "high" = tier !== "free" ? "high" : "auto";

    try {
      const [signedUrl] = await bucket.file(storagePath).getSignedUrl({
        action: "read",
        expires: Date.now() + 10 * 60 * 1000, // 10 min — well within the analyze timeout
      });
      imageRef = { type: "image_url", image_url: { url: signedUrl, detail } };
    } catch (signErr) {
      console.warn("[analyzeOutfit] getSignedUrl failed, falling back to base64:", (signErr as Error)?.message);
      try {
        const [buffer] = await bucket.file(storagePath).download();
        const base64 = buffer.toString("base64");
        imageRef = { type: "image_url", image_url: { url: `data:image/jpeg;base64,${base64}`, detail } };
      } catch (storageErr) {
        console.error("[analyzeOutfit] Storage download failed:", (storageErr as Error)?.message);
        return void sendError(res, 503, "storage_read_failed", "Could not read outfit photo from storage. Try uploading again.");
      }
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
              imageRef,
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

    // Pre-compute a long-lived thumbnail URL so the iOS Home list doesn't
    // need to make an N+1 downloadURL round-trip per outfit.
    let thumbnailURL: string | null = null;
    try {
      const [tUrl] = await bucket.file(storagePath).getSignedUrl({
        action: "read",
        expires: Date.now() + 7 * 24 * 60 * 60 * 1000, // 7 days
      });
      thumbnailURL = tUrl;
    } catch (e) {
      console.warn("[analyzeOutfit] thumbnail signing failed:", (e as Error)?.message);
    }

    // A longer-lived public image URL for the Arena. Finalists rotate within a
    // day/week, but a 14-day expiry safely covers a fit that stays a weekly
    // finalist right up to the week boundary.
    let arenaImageURL: string | null = null;
    try {
      const [aUrl] = await bucket.file(storagePath).getSignedUrl({
        action: "read",
        expires: Date.now() + 14 * 24 * 60 * 60 * 1000, // 14 days
      });
      arenaImageURL = aUrl;
    } catch (e) {
      console.warn("[analyzeOutfit] arena image signing failed:", (e as Error)?.message);
    }

    // Save analysis into fit check doc
    await fitCheckRef.update({
      status: "analyzed",
      thumbnailURL,
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

    // Update this week's public leaderboard BEFORE responding. The iOS Home
    // screen refreshes its "This Week's Trend" the moment the result lands, so
    // the standing must already be written or the user sees the empty state
    // right after scoring. This is one small transaction and never throws (a
    // leaderboard hiccup must not fail the analysis), so awaiting it is safe.
    const weekId = currentWeekId();
    console.log(
      `[analyzeOutfit] analysis complete — fitId=${fit_check_id} uid=${user.uid} ` +
      `rating=${analysis.overall_score} weekId=${weekId} dayId=${currentDayId()} → updating leaderboards`
    );
    await updateWeeklyTrend(db, user.uid, analysis.overall_score as number, fit_check_id, userData);
    // "Today's Best" board — recomputed from today's active checks (so it carries
    // bestScore, average, count, and time-to-best for fair tie-breaking, and
    // self-heals when a fit is deleted). Same never-throws contract as the weekly
    // write so a hiccup can't fail analysis.
    await recomputeDailyTrend(db, user.uid, currentDayId(), userData);

    // AUTO-ENTER the Arena (connected to the same fit pool as the trends): any fit
    // scoring >= 6.5 from an opted-in public profile competes for the Top 3 — no
    // manual posting. Public participation is OPT-IN: only an explicit
    // isPublic === true publishes, so new users are never auto-exposed.
    // Never throws; gated/skipped inside autoEnterArena when ineligible.
    const arenaUserData = userData;
    const arenaIsPublic = arenaUserData.isPublic === true;
    if (arenaIsPublic && (arenaImageURL ?? thumbnailURL)) {
      await autoEnterArena(db, user.uid, fit_check_id, {
        overallScore: analysis.overall_score as number,
        styleGoal: (style_goal as string) ?? null,
        imageURL: (arenaImageURL ?? thumbnailURL) as string,
        ownerDisplayName: arenaUserData.displayName ?? null,
        ownerPhotoURL: arenaUserData.photoURL ?? arenaUserData.avatarURL ?? null,
      });
    }

    // Stats MUST persist BEFORE we flush the response. HTTP (Cloud Run) functions
    // throttle CPU the instant the response is sent, so the old "update stats after
    // res.json()" pattern was unreliable — work after the response often never ran,
    // which is exactly why Profile kept showing 0 checks / 0 streak. We accept the
    // small latency cost for correctness.
    //
    // (1) bump the daily rate-limit counter (a true counter — can't be derived from
    // history), then (2) recompute the aggregate stats straight from the fit_checks
    // collection so totalChecks / avg / best / streak always reflect the active set
    // and self-heal after a delete or re-login.
    await bumpDailyChecks(db, user.uid)
      .catch((e) => console.error("[analyzeOutfit] bumpDailyChecks failed:", (e as Error)?.message));
    await recomputeUserStats(db, user.uid)
      .catch((e) => console.error("[analyzeOutfit] recomputeUserStats failed:", (e as Error)?.message));

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

/**
 * Bumps ONLY the daily rate-limit counter (`dailyChecksUsed` / `dailyChecksResetAt`
 * / `lastCheckDate`). This is a genuine counter — it can't be recomputed from
 * history — so it stays incremental. If this is the first check of a new UTC day the
 * counter resets to 0 first (no scheduled reset job exists, so without this free
 * users get permanently locked at the daily limit).
 */
async function bumpDailyChecks(db: admin.firestore.Firestore, uid: string): Promise<void> {
  const userRef = db.collection("users").doc(uid);
  await db.runTransaction(async (tx) => {
    const data = (await tx.get(userRef)).data() ?? {};
    const today = new Date().toISOString().split("T")[0];
    const isNewDay = data.lastCheckDate !== today;
    const baseChecksUsed = isNewDay ? 0 : (data.dailyChecksUsed ?? 0);
    tx.set(userRef, {
      dailyChecksUsed: baseChecksUsed + 1,
      dailyChecksResetAt: isNewDay
        ? admin.firestore.FieldValue.serverTimestamp()
        : (data.dailyChecksResetAt ?? admin.firestore.FieldValue.serverTimestamp()),
      lastCheckDate: today,
    }, { merge: true });
  });
}

/**
 * Recomputes the user's aggregate stats — `totalFitChecks`, `averageScore`,
 * `bestScore`, `streakCount` — from scratch off the `fit_checks` collection,
 * counting ONLY active checks (`isDeleted !== true`) with a numeric `overallScore`.
 *
 * Recompute (not increment) is deliberate: it self-heals. Deleting a fit, or an old
 * incremental write that never landed, can never leave the counters wrong — every
 * call reconciles them with reality. Called before responding from analyze AND from
 * delete, so Profile is correct after scoring, after a delete, and after re-login
 * (the user doc is the single source of truth the app reads).
 *
 * Exported so delete-outfit can reuse it.
 */
export async function recomputeUserStats(
  db: admin.firestore.Firestore,
  uid: string
): Promise<void> {
  const userRef = db.collection("users").doc(uid);
  const snap = await userRef.collection("fit_checks").get();

  let total = 0;
  let sum = 0;
  let best = 0;
  const days = new Set<string>();

  for (const doc of snap.docs) {
    const d = doc.data();
    if (d.isDeleted === true) continue;
    const score = d.overallScore;
    if (typeof score !== "number") continue;
    total += 1;
    sum += score;
    if (score > best) best = score;
    const at =
      (d.createdAt as admin.firestore.Timestamp | undefined)?.toDate() ??
      (d.analyzedAt as admin.firestore.Timestamp | undefined)?.toDate();
    if (at) days.add(dayIdForDate(at));
  }

  await userRef.set({
    totalFitChecks: total,
    averageScore: total > 0 ? Math.round((sum / total) * 10) / 10 : 0,
    bestScore: Math.round(best * 10) / 10,
    streakCount: computeStreak(days),
  }, { merge: true });
}

/**
 * Consecutive-day streak ending today (or yesterday — a day-old streak is still
 * "alive" until it lapses). Days are the UTC "yyyy-MM-dd" ids of the user's active
 * checks. Returns 0 if the most recent check is older than yesterday.
 */
function computeStreak(days: Set<string>): number {
  if (days.size === 0) return 0;
  const today = dayIdForDate(new Date());
  const yesterday = dayIdForDate(new Date(Date.now() - 86400000));

  let cursor: Date;
  if (days.has(today)) cursor = new Date(`${today}T00:00:00Z`);
  else if (days.has(yesterday)) cursor = new Date(`${yesterday}T00:00:00Z`);
  else return 0;

  let streak = 0;
  while (days.has(dayIdForDate(cursor))) {
    streak += 1;
    cursor = new Date(cursor.getTime() - 86400000);
  }
  return streak;
}

/**
 * Upserts the user's standing on this week's public leaderboard at
 * `weeklyTrends/{weekId}/users/{uid}`. Totals accumulate atomically across every
 * fit the user checks this week.
 *
 * Two contracts the iOS app depends on — do not break them:
 *   1. `weekId` is the ISO-8601 "yyyy-Www" UTC id from {@link currentWeekId},
 *      byte-for-byte identical to Swift's `WeekIdentifier.current`, so the app
 *      reads the exact document this writes.
 *   2. The field names below mirror the `WeeklyLeaderboardEntry` Swift decoder
 *      (`displayName`, `photoURL`, `totalWeeklyRating`, `outfitCount`,
 *      `bestScore`, `isPublic`). Renaming any of them silently empties the
 *      leaderboard UI even though the document exists.
 *
 * Never throws — a leaderboard failure must not fail the user's analysis.
 */
async function updateWeeklyTrend(
  db: admin.firestore.Firestore,
  uid: string,
  rating: number,
  fitId: string,
  userData?: admin.firestore.DocumentData
): Promise<void> {
  const weekId = currentWeekId();
  const entryRef = db
    .collection("weeklyTrends").doc(weekId)
    .collection("users").doc(uid);

  try {
    // Denormalize the public profile fields onto the leaderboard entry so the
    // app can render rows without a second per-user read. Reuse the caller's
    // already-fetched user doc when provided (the analyze path passes it) so a
    // single analysis doesn't re-read users/{uid}; fall back to a fresh read for
    // any caller that doesn't pass it.
    const data = userData ?? (await db.collection("users").doc(uid).get()).data() ?? {};
    const displayName: string | null = data.displayName ?? null;
    const photoURL: string | null = data.photoURL ?? data.avatarURL ?? null;
    // Public participation is OPT-IN: a user appears on the public board only after
    // explicitly opting in (isPublic === true). A missing field counts as private,
    // so new users are never auto-published.
    const isPublic: boolean = data.isPublic === true;

    await db.runTransaction(async (tx) => {
      const snap = await tx.get(entryRef);
      const prev = snap.data() ?? {};
      const prevTotal: number = prev.totalWeeklyRating ?? 0;
      const prevCount: number = prev.outfitCount ?? 0;
      const prevBest: number = prev.bestScore ?? 0;

      // Round the running sum to 1 dp to avoid float drift (6.2 + 7.1 = 13.3,
      // not 13.299999999999999).
      const newTotal = Math.round((prevTotal + rating) * 10) / 10;
      const newCount = prevCount + 1;
      const newBest = Math.max(prevBest, rating);

      console.log(
        `[weeklyTrend] write path=${entryRef.path} oldTotal=${prevTotal} ` +
        `newTotal=${newTotal} outfitCount=${newCount} bestScore=${newBest} isPublic=${isPublic}`
      );

      tx.set(entryRef, {
        userId: uid,
        displayName,
        photoURL,
        totalWeeklyRating: newTotal,
        outfitCount: newCount,
        bestScore: newBest,
        isPublic,
        weekId,
        lastFitId: fitId,
        lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });
    });

    console.log(`[weeklyTrend] ✅ success uid=${uid} weekId=${weekId}`);
  } catch (err) {
    console.error(`[weeklyTrend] ❌ failed uid=${uid} weekId=${weekId}:`, (err as Error)?.message);
  }
}

/** UTC [start, end) bounds for a "yyyy-MM-dd" dayId. */
function dayBounds(dayId: string): { start: Date; end: Date } {
  const [y, m, d] = dayId.split("-").map(Number);
  const start = new Date(Date.UTC(y, m - 1, d, 0, 0, 0, 0));
  const end = new Date(Date.UTC(y, m - 1, d + 1, 0, 0, 0, 0));
  return { start, end };
}

/**
 * Recomputes the user's "Today's Best" standing at
 * `dailyTrends/{dayId}/users/{uid}` from scratch, using only that day's ACTIVE
 * fit checks (userId present, isDeleted !== true, a numeric overallScore). This
 * replaces the old incremental writer so the entry can carry the fields the
 * fair tie-break needs AND self-heal after a deletion (an incremental max/count
 * can never be "un-counted").
 *
 * Ranking on the client is: bestScore desc → outfitCount desc → averageScoreToday
 * desc → timeReachedHighestScoreToday asc. We persist every input that ranking
 * needs so the client never has to read other users' private fit_checks.
 *
 * Contracts the iOS app depends on — do not break them:
 *   1. `dayId` is the UTC "yyyy-MM-dd" id ({@link currentDayId}), byte-for-byte
 *      identical to Swift's `DayIdentifier.current`. UTC (not local tz) is
 *      intentional: a shared board needs one global day boundary or users in
 *      different timezones never compete on the same document.
 *   2. The field names mirror the Swift `DailyLeaderboardService` decoder
 *      (`displayName`, `photoURL`, `outfitCount`, `bestScore`,
 *      `averageScoreToday`, `timeReachedHighestScoreToday`, `isPublic`,
 *      `lastUploadAt`). Renaming any silently breaks the Today board.
 *
 * Never throws — a leaderboard failure must not fail analysis or deletion.
 */
export async function recomputeDailyTrend(
  db: admin.firestore.Firestore,
  uid: string,
  dayId: string,
  userData?: admin.firestore.DocumentData
): Promise<void> {
  const entryRef = db
    .collection("dailyTrends").doc(dayId)
    .collection("users").doc(uid);

  try {
    const { start, end } = dayBounds(dayId);
    const snap = await db
      .collection("users").doc(uid).collection("fit_checks")
      .where("createdAt", ">=", admin.firestore.Timestamp.fromDate(start))
      .where("createdAt", "<", admin.firestore.Timestamp.fromDate(end))
      .orderBy("createdAt", "asc")
      .get();

    let count = 0;
    let sum = 0;
    let best = -1;
    let bestAt: admin.firestore.Timestamp | null = null;
    let lastAt: admin.firestore.Timestamp | null = null;

    // Ordered by createdAt asc, so the first doc that reaches the running max is
    // the earliest time the user hit it — exactly the final tie-break key.
    for (const doc of snap.docs) {
      const d = doc.data();
      if (d.isDeleted === true) continue;
      const score = d.overallScore;
      if (typeof score !== "number") continue;
      const createdAt: admin.firestore.Timestamp | null = d.createdAt ?? null;
      count += 1;
      sum += score;
      if (createdAt) lastAt = createdAt;
      if (score > best) {
        best = score;
        bestAt = createdAt;
      }
    }

    if (count === 0) {
      // No active checks left for this day → the user shouldn't be on the board.
      await entryRef.delete().catch(() => undefined);
      console.log(`[dailyTrend] recompute uid=${uid} dayId=${dayId} → 0 active checks, removed`);
      return;
    }

    // Reuse the caller's already-fetched user doc when provided (analyze passes it);
    // fall back to a fresh read for callers like deleteOutfit that don't.
    const data = userData ?? (await db.collection("users").doc(uid).get()).data() ?? {};
    const displayName: string | null = data.displayName ?? null;
    const photoURL: string | null = data.photoURL ?? data.avatarURL ?? null;
    // Public participation is OPT-IN — published only on an explicit isPublic === true.
    const isPublic: boolean = data.isPublic === true;

    const bestScore = Math.round(best * 10) / 10;
    const averageScoreToday = Math.round((sum / count) * 10) / 10;
    const timeReachedHighestScoreToday =
      bestAt ?? lastAt ?? admin.firestore.Timestamp.now();

    console.log(
      `[dailyTrend] recompute path=${entryRef.path} best=${bestScore} avg=${averageScoreToday} ` +
      `fits=${count} isPublic=${isPublic}`
    );

    await entryRef.set({
      userId: uid,
      displayName,
      photoURL,
      outfitCount: count,
      bestScore,
      averageScoreToday,
      timeReachedHighestScoreToday,
      isPublic,
      dayId,
      lastUploadAt: lastAt ?? admin.firestore.Timestamp.now(),
    }, { merge: true });

    console.log(`[dailyTrend] ✅ recompute success uid=${uid} dayId=${dayId}`);
  } catch (err) {
    console.error(`[dailyTrend] ❌ recompute failed uid=${uid} dayId=${dayId}:`, (err as Error)?.message);
  }
}

/**
 * Current ISO-8601 week id ("yyyy-Www", UTC). MUST stay byte-for-byte identical
 * to iOS `WeekIdentifier.current` (Calendar(identifier: .iso8601), UTC) so the
 * app reads the same document the backend writes. e.g. 2026-06-08 → "2026-W24".
 */
export function currentWeekId(date = new Date()): string {
  // Normalize to UTC midnight so the time-of-day never shifts the week.
  const d = new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate()));
  // ISO weekday: Mon=1 … Sun=7.
  const isoDay = d.getUTCDay() === 0 ? 7 : d.getUTCDay();
  // Shift to the Thursday of this week — its calendar year is the ISO week-year.
  d.setUTCDate(d.getUTCDate() + 4 - isoDay);
  const isoYear = d.getUTCFullYear();
  const yearStart = Date.UTC(isoYear, 0, 1);
  // Whole weeks from Jan 1 of the week-year to that Thursday, 1-based.
  const week = Math.ceil(((d.getTime() - yearStart) / 86_400_000 + 1) / 7);
  return `${String(isoYear).padStart(4, "0")}-W${String(week).padStart(2, "0")}`;
}

/**
 * Current UTC calendar-day id ("yyyy-MM-dd"). MUST stay byte-for-byte identical
 * to iOS `DayIdentifier.current` (UTC) so the app reads the same document the
 * backend writes. e.g. 2026-06-08T23:30Z → "2026-06-08".
 */
export function dayIdForDate(date: Date): string {
  const y = date.getUTCFullYear();
  const m = date.getUTCMonth() + 1;
  const d = date.getUTCDate();
  return `${String(y).padStart(4, "0")}-${String(m).padStart(2, "0")}-${String(d).padStart(2, "0")}`;
}

function currentDayId(date = new Date()): string {
  return dayIdForDate(date);
}
