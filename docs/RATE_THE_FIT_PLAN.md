# "Rate the Fit" — Build Plan

> The Hot-or-Not / BeReal-style peer-rating arena for FitCheck AI.
> Converts the app from single-player ("AI tells me a number") into a social
> dopamine loop ("real people are reacting to me right now").

**Status:** Phase 1 BUILT on branch `rate-the-fit-phase1` (backend + rules + SwiftUI,
build verified). Backend + rules **DEPLOYED to fitcheck-d3091 on 2026-06-10** (5
functions live; no-auth→401 and OPTIONS→204 smoke-tested). Branch NOT merged to main;
behavioral acceptance tests (daily cap, dual gate, idempotency) still need real
multi-user runtime testing in the app.
**Decisions locked:**
- Voting = **👍 / 👎 binary** (fastest swipe, highest vote volume; human result is a "hot %")
- Push notifications = **deferred to Phase 2** (FCM/APNs is its own task)
- Date: 2026-06-10

---

## 1. Why this feature (first principles)

The current core loop is `upload → AI scores you → AI upgrades → (dead leaderboards)`.
It is **100% single-player**. The only dopamine source is the AI's opinion, which
flattens after ~10 uses because a robot's number has no stakes and no surprise.

`rate-outfit.ts` and `like-look.ts` today only let you rate your *own* fit checks.
There is **zero human-to-human interaction** anywhere in the app, and no daily-return
trigger.

The four dopamine engines in fashion/social apps, ranked:
1. **Social validation** (others judging *you*) — strongest. Currently absent.
2. **Variable reward** (hidden score → reveal) — present but underused.
3. **Comparison / status** (ranks, percentiles) — skeleton exists, no data.
4. **Progress / identity** (streaks) — absent.

"Rate the Fit" turns on #1 and #3, and amplifies #2.

**Why a swipe-rating game, not an infinite feed:** a feed has a brutal cold-start,
feels like work, and concentrates cruelty in comments. A reciprocal swipe game
(rate N to unlock your own score) forces engagement, seeds the vote pool, and gives
two dopamine hits per session (judging others + being judged).

---

## 2. Architectural constraint

All fit checks today live at `users/{uid}/fit_checks/{id}` and are **private** —
only the owner can read them (`firestore.rules`). There is **no shared pool** to rate.

**Solution:** copy the existing `publicProfiles/{uid}` pattern — a world-readable
(to any signed-in user) mirror, owner-writable for the safe fields, backend-only for
the sensitive aggregate. Nothing becomes public without an explicit opt-in tap.

Storage today: `users/{uid}/fit-checks/{fitCheckId}/original`. Public copies get a
download-token URL (same approach already used for upgrade previews — no signBlob).

---

## 3. Data model (new collections)

### `rateArena/{fitId}` — the public pool
World-readable to any signed-in user. **Never exposes individual votes.**
```
ownerUid:     string
imageURL:     string        // public download-token URL
styleGoal:    string        // campus | professional | date_night | ...
aiScore:      number        // the existing AI 1–10 score, for the AI-vs-human reveal
upvotes:      number        // 👍 count   (backend-only writes)
voteCount:    number        // total votes (backend-only writes)
status:       "live" | "under_review" | "removed"
reportCount:  number        // distinct reporters; drives auto under_review (backend-only)
moderation:   "approved"
voteBucket:   number        // random 0–999, for cheap fair random serving
createdAt:    timestamp
```
`approvalScore = upvotes / voteCount` (computed, never stored as truth).
Surfaced in UI as **"Human Fit Score" / "Style Approval"** — never "Hot or Not".

### `rateArena/{fitId}/votes/{voterUid}` — one doc per voter
Doc ID = voter uid ⇒ **one vote per person enforced for free** (no double voting).
Owner cannot read these; backend aggregates them.
```
liked:   boolean   // 👍 = true, 👎 = false
votedAt: timestamp
```

### `rateArena/{fitId}/reports/{reporterUid}` — one report per reporter
Doc ID = reporter uid ⇒ one report per person. A single report **only hides the fit
for that reporter** (client-side). Backend bumps `reportCount`; status flips to
`under_review` only after multiple distinct reports (threshold, e.g. 3) or backend
moderation. **One report never removes a fit globally.**
```
reason:     string   // optional category
reportedAt: timestamp
```

### `users/{uid}/arenaUnlocks/{fitId}` — PER-OUTFIT unlock tracking
The reciprocity gate is **per posted outfit, not global.** For each fit the user posts
to the arena, they must rate 5 *other* fits to unlock that specific fit's Human Score.
```
ratingsGivenForThisFit: number    // counted from the moment this fit was posted
isUnlocked:             boolean    // true once ratingsGivenForThisFit >= 5
createdAt:              timestamp  // when this fit entered the arena
unlockedAt:             timestamp  // when the gate was satisfied (nullable)
```

### `users/{uid}` — counters
```
peerRatingsGiven:    number   // global lifetime stat (NOT the gate anymore — gate is per-fit)
peerRatingsReceived: number   // total votes received across fits (Phase-2 push)
```

---

## 4. Cloud Functions

### `enterArena(fit_check_id)` — opt-in publish
- Owner-only auth.
- Loads the fit check, runs **moderation** (see §6). Reject → never enters pool.
- Copies image to a public storage path + download-token URL.
- **Anti-spam daily cap:** free users may post **1 fit/day** to the Arena (tracked via
  `arenaPostsToday` / `lastArenaPostDate` on the user doc, UTC). Over cap → `429
  arena_daily_cap` with a UI-safe message. Premium expansion deferred.
- Writes `rateArena/{fitId}` with `upvotes:0, voteCount:0, reportCount:0,
  status:"live", voteBucket:random(), aiScore:<existing>`.
- **Also creates `users/{uid}/arenaUnlocks/{fitId}`** with `ratingsGivenForThisFit:0,
  isUnlocked:false, createdAt:now`. This starts the per-fit reciprocity clock.
- In-app framing: *"Send to the Arena 👀 — get your Human Fit Score."*

### `getArenaQueue()` — serve outfits to rate
- Returns a batch (~10) of fits the user can rate.
- Query: `rateArena where status=="live"`, random-sample via `voteBucket >= random()`
  with wrap-around, **biased toward low `voteCount`** so freshly-posted fits get votes
  within minutes (a poster who gets zero reactions churns — new fits MUST feel seen).
- **Excludes:** my own fits (`ownerUid != me`), non-`live` fits (covers private /
  under_review / removed), deleted fits, fits I've already voted on, and fits from
  users I've blocked. Already-voted is enforced server-side (vote doc exists) AND
  filtered client-side; blocked-user filtering uses the client's block list.
- If the result set is empty → client shows *"You're all caught up — come back later"*
  (see §8), optionally offering to re-check one of the user's own fits' results.

### `submitPeerRating(fit_id, liked)` — the core vote (transaction)
1. Create `votes/{myUid}` — fails silently if it exists (idempotent, no double vote).
2. `voteCount += 1`; if `liked`, `upvotes += 1` on the arena doc.
3. `peerRatingsGiven += 1` on my user doc (global stat).
4. `peerRatingsReceived += 1` on owner's user doc.
5. **Per-fit unlock credit:** for each of MY still-locked `arenaUnlocks/{fitId}`
   (`isUnlocked == false`), `ratingsGivenForThisFit += 1`; when it reaches 5, set
   `isUnlocked:true, unlockedAt:now`. (Rating one fit advances all of my pending
   unlocks — fair and simple.)
6. (Phase 2) if owner's fit crossed the reveal threshold → enqueue push.

### `getMyArenaResults(fit_id)` — the payoff reveal
Owner-only. **Reveal requires BOTH conditions:**
1. `arenaUnlocks/{fit_id}.isUnlocked == true` (I rated ≥5 other fits since posting), AND
2. the fit `voteCount >= 5` (the **Phase-1 threshold — 5, not 10**, since the app
   won't have enough users early on).

Response states:
- **Both met →** return `approvalScore` (% 👍), `voteCount`, and a **percentile**
  within the same `styleGoal` ("ahead of 78% of campus fits").
- **Not enough ratings given →** `locked_reciprocity`, with how many more to rate:
  *"Rate 3 more fits to unlock your Human Fit Score."*
- **Rated enough but too few votes received →** `locked_votes`:
  *"Unlocked soon — waiting for 3 more ratings on your fit."*

### `reportFit(fit_id, reason?)` — community moderation (one per reporter)
- Creates `rateArena/{fitId}/reports/{reporterUid}` (idempotent).
- Bumps `reportCount` on the arena doc.
- **A single report does NOT remove the fit globally** — it only hides it for the
  reporter (client adds the id to a local/own hidden list).
- Only when `reportCount >= REPORT_THRESHOLD` (e.g. 3 distinct reporters) **or** a
  backend moderation pass flags it does `status` flip to `under_review` → then
  `removed`. This prevents a single bad actor from nuking someone's fit.

---

## 5. The dopamine logic (the point of the feature)

Five mechanics engineered into the loop:

1. **Per-fit reciprocity unlock — forced engagement + cold-start fix.**
   For EACH outfit you post, you must rate 5 other fits to unlock *that* fit's Human
   Fit Score (tracked in `arenaUnlocks/{fitId}`) — not a one-time global unlock.
   Every post re-engages you. Converts passive "wait for results" into an active
   session and seeds the vote pool. The single most important mechanic; it's why this
   beats a feed.

2. **Variable-ratio reveal — the slot machine.**
   Do NOT show a live running tally. Hide results until both gates clear, then drop
   them in a batch: *"14 people rated your fit — 86% Style Approval, top 22%."*
   Anticipation > info. A trickling counter kills the spike.

3. **AI-then-human two-act structure.**
   The existing AI score (8.2) is the *warm-up guess*; the human hot % is the
   *reveal*. The gap is the hook: "AI said 8.2 — 91% of humans are into it, you're
   underrated." Built-in narrative tension every time.

4. **Rating combo / flow on the giving side.**
   While swiping: haptic tick per swipe, a fast-rating "🔥 streak" counter, snappy
   card-spring animations. Make *judging* feel like a game, not a chore — keeps users
   past the required 5.

5. **The return trigger (Phase 2).**
   Push when your fit crosses the vote threshold: *"Your Friday fit got 10 new
   reactions 👀."* Pair with a fresh daily queue so opening the app always has new
   outfits to judge.

**Percentiles, not raw ranks** — everyone can be "top X% in *something*" (style goal,
day). Raw ranks make 99% feel like losers; percentiles let almost everyone win a slice.

---

## 6. Safety (non-negotiable before ship)

- **Moderation gate in `enterArena`:** OpenAI moderation + a vision check that the
  image is an outfit/person and not NSFW. Reject → never enters pool.
- **Anonymous aggregate only.** Owners see Style Approval % + count, never *who* voted
  or any individual vote. This is the line between fun and bullying.
- **Report hides for the reporter only.** One report never removes a fit globally;
  it adds the id to the reporter's hidden list and bumps `reportCount`. Global
  `under_review` / `removed` happens only after multiple distinct reports or backend
  moderation. **Block** a user → all their fits drop out of that user's queue.
- **Rate the style, not the person.** All copy frames it as judging the outfit/look
  ("Human Fit Score", "Style Approval") — never the body or the person, and never
  "Hot or Not". Important for both safety and App Store review.
- **No comments in MVP.** Only 👍 / 👎 and report. Comments are where cruelty lives;
  they come (if ever) much later.
- **Opt-in, opt-out by default.** Nothing goes public without the explicit
  `enterArena` tap.

---

## 7. firestore.rules additions

```
// Public rating arena: world-readable to signed-in users; aggregate written
// only by backend. Voters write one vote doc keyed by their own uid.
match /rateArena/{fitId} {
  allow read: if request.auth != null;
  allow write: if false;                       // backend (enterArena/submitPeerRating) only

  match /votes/{voterUid} {
    allow read: if false;                      // backend aggregates; nobody reads raw votes
    allow create: if request.auth != null && request.auth.uid == voterUid;
    allow update, delete: if false;            // votes are immutable (no double/un-vote)
  }

  match /reports/{reporterUid} {
    allow read: if false;                      // backend-only; reporters don't read others'
    allow create: if request.auth != null && request.auth.uid == reporterUid;
    allow update, delete: if false;
  }
}

// Per-fit unlock tracking lives under the user's own tree; backend (Admin SDK)
// does the increments, but owner may read to drive the gate UI.
match /users/{uid}/arenaUnlocks/{fitId} {
  allow read: if request.auth != null && request.auth.uid == uid;
  allow write: if false;                       // backend only (enterArena/submitPeerRating)
}
```
(`peerRatingsGiven` / `peerRatingsReceived` on `users/{uid}` and all `arenaUnlocks`
mutations are written by backend functions via Admin SDK, which bypasses rules.)

---

## 8. Client surface (SwiftUI)

### Home redesign (per approved mockup — Arena is the centerpiece)
Top-to-bottom layout, keeping the soft beige / olive design system:
1. **Greeting** — "Hey, there 👋" / "Ready to check today's fit?"
2. **Check Today's Fit CTA** — existing large olive card; "Check today's fit.",
   remaining checks or "∞ Unlimited ✦", white circular + button on the right.
3. **Arena main card** (new, large `fcSurface` rounded card):
   - ⚔️ icon + "Arena" title; "2/5 rated" pill top-right.
   - Subtitle: "Rate 5 fits to unlock your Human Fit Score."
   - 5-step dot progress indicator.
   - Primary olive button "Enter Arena ›".
   - Avatar trio + "Join others in rating real people's fits".
   - **Stacked Tinder-style preview** of another user's public fit on the right:
     overlay "Would you wear this? / Rate the fit", circular ✕ (pass) and ♥ (like)
     buttons, footer hint "Swipe right to like, left to pass".
   - Preview shows OTHER users' public fits, never the user's own Latest Look.
4. **Latest Look** — demoted, smaller card: "Latest Look" + "View History ›",
   thumbnail, category ("Professional"), "Yesterday • Work", score pill ("7.8"),
   chevron → opens detail; "View History" → HistoryView.
5. **Demoted leaderboard teaser** — small Week/Today segment + a "N ratings to go to
   hit your goal!" nudge below Latest Look (no longer the main engagement area).
6. **Bottom nav** — Home / **Arena** (⚔️) / center green **+** FAB / Profile.
   Arena tab opens full `ArenaRateView`.

### Components
- **Arena tab** → `ArenaRateView`:
  full-screen swipe cards (reuse `PortraitOutfitImage` for framing), 👍/👎 via swipe
  right/left, haptics + combo counter. A small "⋯ → Report" on each card (hides it for
  this user only). **No comments.**
- **Empty queue state** — when `getArenaQueue` returns nothing:
  *"You're all caught up — come back later"*, with an optional button to re-check the
  results on one of the user's own posted fits.
- **`enterArena` CTA** appended to `ResultView` after AI analysis:
  "Get your Human Fit Score 👀".
- **Reveal sheet** from History/Home when both gates clear — animated count-up,
  confetti above threshold, AI-vs-human comparison line ("AI 8.2 → 86% Style Approval").
- **Gate UI (two states):**
  - reciprocity not met → progress ring: "Rate 3 more fits to unlock this fit's score."
  - rated enough but too few votes → "Unlocked soon — waiting for 3 more ratings on your fit."
- **Wording everywhere:** "Human Fit Score" / "Style Approval". Never "Hot or Not";
  always frame as rating the outfit/style, not the person or body.

---

## 9. Build order

- **Phase 1 (MVP loop — complete dopamine loop on its own):**
  `enterArena` + moderation, `getArenaQueue`, `submitPeerRating`,
  `getMyArenaResults` (reciprocity gate), `ArenaRateView`, reveal sheet,
  firestore.rules. Deploy functions + rules.
- **Phase 2 (retention):** FCM push on reveal threshold + daily fresh-queue
  notification. (Requires APNs cert setup.)
- **Phase 3 (depth):** per-style-goal percentile leaderboards, rating-combo streaks,
  "rate to earn extra AI checks" (ties reciprocity to monetization).

---

## 10. Resolved decisions (from review)

- **Per-fit unlock**, not global: must rate 5 others per posted fit
  (`arenaUnlocks/{fitId}`).
- **Reveal needs BOTH** gates: rated ≥5 others AND fit received ≥5 votes.
- **Reveal threshold = 5 received votes** in Phase 1 (not 10 — too high before scale).
- **Report ≠ instant global removal.** Hides for reporter only; `under_review`/
  `removed` only after multiple distinct reports or backend moderation.
- **UI wording:** "Human Fit Score" / "Style Approval"; never "Hot or Not"; rate the
  outfit/style, not the person/body.
- **No comments in MVP** — only 👍/👎 and report.
- **Binary votes only** — `liked: true/false`; no 1–10 scoring in Phase 1.
- **Daily Arena-post cap** — free users 1 post/day (UTC); premium expansion later.
- **Queue excludes:** own, private (non-`live`), deleted, under_review, removed,
  already-voted, blocked-user fits.
- **Empty queue:** "You're all caught up — come back later" (+ optional self-recheck).
- **Home redesign:** Arena is the centerpiece card (above a demoted Latest Look);
  bottom nav = Home / Arena / + / Profile. See §8 + approved mockup.

## 11. Open / future questions

- `REPORT_THRESHOLD` exact value (start 3) and whether backend auto-moderation runs
  on a schedule over `under_review` fits.
- Whether `enterArena` should count toward a daily cap (anti-spam).
- Premium angle: unlimited Arena posts, or priority placement, for subscribers.
