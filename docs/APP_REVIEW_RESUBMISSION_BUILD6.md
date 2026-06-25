# FitCheck 1.0.0 (6) — Resubmission for Apple rejection 9372427d

Fixes the June 24 2026 rejection (reviewed on iPad Air 11" M3):
- **2.1(b) App Completeness** — "Premium" referenced but IAPs not submitted with the version.
- **1.2 User-Generated Content** — required UGC safeguards missing/not demonstrated.

---

## 1. What changed in code (build 6)

### Premium / IAP (2.1b)
- Verified StoreKit product IDs match everywhere: `com.fitcheckai.premium.monthly`, `com.fitcheckai.premium.yearly` (`Constants.swift`, `FitCheck.storekit`). No placeholder/old IDs.
- Paywall (`PremiumView`) already shows: monthly $4.99 + 3-day trial, yearly $39.99 + 3-day trial (read live from StoreKit), **Restore Purchases**, **Terms + Privacy** links, auto-renew disclosure. **Manage Subscription** lives in `PremiumStatusView` (shown to active subscribers).
- Added App Review breadcrumbs via `AppLog.premium` (os_log, visible in Console/device log): products loaded + IDs, purchase tapped, purchase verified, restore tapped, restore completed/no-entitlement, manage-subscription opened.

### UGC safety (1.2)
- **EULA/Terms gate BEFORE login** (`AuthView`): a required "I agree to the Terms of Use and EULA…" checkbox now gates Apple Sign-In, Google Sign-In, AND Guest. Acceptance is stored locally immediately and mirrored to the user doc after login (`acceptedTermsVersion`, `acceptedTermsAt`, `acceptedTermsByUid`). Visible links to **Terms of Use**, **EULA**, **Privacy**.
- **EULA screen** (`EULAView`) + Terms section 5 now carry the explicit zero-tolerance statement and the 24-hour action commitment.
- **Report with reasons** (`ArenaPostDetailView`): the report action is now a reason picker — Nudity/Sexual, Hate/Harassment, Bullying/Threats, Violence, Spam/Scam, Other. Reporting instantly hides the fit for the reporter (`HiddenFits`), files a durable record to the top-level `reports` queue, and bumps the server report threshold. Confirmation: "Thanks. We'll review this within 24 hours." Comments also have Report + Block.
- **Block** now also files a developer notification to `reports` (type=block), in addition to the durable per-account `blockedUserIDs` block that hides the user's fits/comments everywhere and prevents interaction.
- **Content filtering — FAIL-CLOSED** (`analyze-outfit.ts` + `shared/openai.ts`): every photo is screened by OpenAI's `omni-moderation-latest` before it can reach the public Arena. A fit becomes `moderationStatus: approved` **only on a positive clean verdict**. If the model flags it → `rejected`; if the moderation API errors or returns no verdict → `pending`. **Neither `pending` nor `rejected` can ever appear in a public feed** — every Arena entry/read path (`autoEnterArena` gate, `ensureArenaEntry` eligibility, and the live board's `bestFitForUser`) requires `moderationStatus === "approved"`. The user's own **private** analysis still completes and is returned regardless, and a public user whose fit is held back sees "Your fit is being reviewed before it appears publicly." Report/block + the report threshold (`under_review`, now also excluded from the rebuilt board) backstop the automated pass.
- **Moderation queue + rules** (`firestore.rules`): top-level `reports` collection — users can only CREATE reports/blocks as themselves in `open` state; status is admin-only.
- **Admin moderation function** (`functions/src/moderation.ts` → `adminModerate`): list the open queue, remove content, suspend/eject users, resolve reports. Gated by `ADMIN_MODERATION_KEY`.

### Build
- `CFBundleVersion` 5 → **6** (Info.plist + pbxproj). `CFBundleShortVersionString` stays **1.0.0**. Verified embedded in the built app.

---

## 2. Build verification (already run)

| Check | Result |
|---|---|
| `tsc --noEmit` (Cloud Functions) | ✅ TSC_OK |
| iOS Simulator build (Debug) | ✅ BUILD SUCCEEDED |
| iOS device build (Release config) | ✅ BUILD SUCCEEDED |
| Embedded `CFBundleShortVersionString` | ✅ 1.0.0 |
| Embedded `CFBundleVersion` | ✅ 6 |

Commands:
```bash
# Cloud Functions type-check
cd functions && npx tsc --noEmit -p tsconfig.json

# iOS sim build
GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all \
GIT_CONFIG_KEY_1=safe.directory GIT_CONFIG_VALUE_1='*' \
xcodebuild -project FitCheckAI.xcodeproj -scheme FitCheckAI \
  -destination 'generic/platform=iOS Simulator' -configuration Debug build CODE_SIGNING_ALLOWED=NO

# Release archive (do in Xcode with your signing identity, or CLI):
GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all \
GIT_CONFIG_KEY_1=safe.directory GIT_CONFIG_VALUE_1='*' \
xcodebuild -project FitCheckAI.xcodeproj -scheme FitCheckAI \
  -configuration Release -archivePath /tmp/FitCheckAI.xcarchive archive
```

---

## 3. Deploy BEFORE resubmitting (required for the new UGC features to work)

The client writes reports/blocks to Firestore and the backend filters content — both need a deploy. **Run these with an account that has access to the production project `fitcheck-d3091`** (the `firebase login` account must be able to see it in `firebase projects:list`):
```bash
firebase functions:secrets:set ADMIN_MODERATION_KEY   # set once, for adminModerate (paste a strong random value)
cd functions && npx tsc --noEmit -p tsconfig.json && cd ..   # type-check BEFORE deploy
firebase deploy --only firestore:rules,functions --project fitcheck-d3091
```
After deploy, confirm the functions are live:
```bash
firebase functions:list --project fitcheck-d3091   # expect analyzeOutfit, getArenaFinalists, ensureArenaEntry, voteHotFit, postArenaComment, getArenaComments, reportFit, recomputeArenaFinalists, scheduledArenaRecompute, adminModerate, deleteOutfit, …
```

---

## 4. MANUAL App Store Connect steps — IAP submission (this is the real 2.1b fix)

The code/IDs are correct. 2.1(b) happens because the subscriptions weren't submitted **with** this app version. Do this:

1. App Store Connect → **Apps → FitCheck**.
2. Left sidebar → **Subscriptions** (under In-App Purchases). Open the **FitCheck Premium** group.
3. For **Premium Monthly** (`com.fitcheckai.premium.monthly`) and **Premium Yearly** (`com.fitcheckai.premium.yearly`), open each and confirm:
   - Localization (display name + description) is filled in.
   - Price is set ($4.99 / $39.99) with the 3-day free trial **Introductory Offer**.
   - A **Review Screenshot** is uploaded (required — use a paywall screenshot).
   - Status is **Ready to Submit** (or Waiting for Review). Fix any "Missing Metadata".
4. Left sidebar → your **1.0.0** version page (the rejected one).
5. Scroll to **In-App Purchases and Subscriptions** → click the **+** / "Edit" and **select BOTH subscriptions** so they're attached to this version. (This is the step that's usually missing → the 2.1b rejection.)
6. Make sure build **1.0.0 (6)** is selected on the version page.
7. Reply to the reviewer (text below) and **Add for Review → Submit**.

Verify state via the API helper first (read-only, never submits):
```bash
# uses ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH from .env.asc.local
node scripts/asc_verify_iap.mjs
```
It prints each product's `state` and whether a review screenshot is attached.

---

## 5. Screen-recording script for App Review (record on the iPad)

1. **Fresh launch** → onboarding → "Let's Go".
2. **EULA before login**: on the sign-in screen, show the "I agree to the Terms of Use and EULA…" checkbox. Tap **Terms of Use**, **EULA**, **Privacy** links to show they open. Point out the sign-in buttons are **disabled** until the box is ticked.
3. **Accept terms**: tick the box → buttons enable.
4. **Login**: Sign in with Apple (or Google).
5. **Public content**: go to the **Arena** tab. Tap a top fit to open its detail.
6. **Report content**: tap the **⋯** menu → **Report this fit** → pick a reason (e.g. "Nudity or Sexual Content") → show the "Thanks. We'll review this within 24 hours." confirmation → the fit **disappears** from your Arena.
7. **Block user**: open another fit → **⋯** → **Block this user** → confirm → that user's fit/comments vanish and you return to the board.
8. (Optional) Show **Profile → manage Premium → Restore Purchases / Manage Subscription**.

---

## 6. App Review Notes (paste into ASC → App Review Information → Notes)

```
FitCheck is an AI outfit-feedback app with an optional public "Arena."

IN-APP PURCHASES (Guideline 2.1):
Premium is sold only via Apple In-App Purchase. Two auto-renewable subscriptions
in one group:
 - com.fitcheckai.premium.monthly — $4.99/mo, 3-day free trial
 - com.fitcheckai.premium.yearly  — $39.99/yr, 3-day free trial
Open the paywall via Profile → Premium (or any locked feature). Restore Purchases
and Manage Subscription are available. Both subscriptions are submitted with this
version.

USER-GENERATED CONTENT SAFETY (Guideline 1.2):
 - Terms of Use + EULA must be accepted (checkbox) BEFORE any sign-in; the EULA
   states a zero-tolerance policy for objectionable content and abusive users.
 - Public participation is opt-in (off by default).
 - Every public fit/comment has Report (with reasons) and Block. Reporting/blocking
   instantly hides the content from the reporter and prevents further interaction.
 - Uploads are screened for objectionable content before they can appear publicly, and
   the screen is fail-closed: a fit is shown publicly only after it is positively
   approved; if the check is inconclusive it is held back, not shown.
 - We review reports and act within 24 hours (remove content, suspend/eject users).

No demo account needed — Sign in with Apple or "Continue as Guest" both work.
```

---

## 7. Reply to App Review (paste into the Resolution Center reply)

```
Thank you for the review. We have addressed both items in build 6 (1.0.0):

Guideline 2.1(b) — In-App Purchases:
The two Premium auto-renewable subscriptions (com.fitcheckai.premium.monthly and
com.fitcheckai.premium.yearly) are now submitted together with this app version,
with localized metadata, pricing ($4.99/mo, $39.99/yr, 3-day free trial) and
review screenshots. The in-app paywall, Restore Purchases, and Manage Subscription
are all functional.

Guideline 1.2 — User-Generated Content:
We added/confirmed the full set of safeguards:
 • A required Terms of Use + EULA agreement (checkbox) before any account creation
   or sign-in, including an explicit zero-tolerance policy for objectionable content
   and abusive users.
 • Automated, fail-closed filtering of every uploaded image before it can appear in a
   public feed — content is shown publicly only after it is positively approved; if the
   automated check is inconclusive the fit is held back, never shown.
 • A Report mechanism with reasons on every public item.
 • A Block mechanism that instantly removes a user's content and prevents further
   interaction, and notifies us.
 • A moderation queue and process to act on reports within 24 hours by removing
   content and ejecting abusive users.

A screen recording demonstrating the EULA gate, report, and block flows is attached.
Thank you.
```
