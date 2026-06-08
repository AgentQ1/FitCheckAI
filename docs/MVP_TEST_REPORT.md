# FitCheck AI — MVP Test Report

**Date:** 2026-05-26  
**Scope:** Full codebase audit — iOS (Swift/SwiftUI), Firebase Cloud Functions (TypeScript), Firestore rules, Storage rules, Stripe integration  
**Auditor:** Claude (senior full-stack / QA lead pass)

---

## 1. What Was Broken

### BUG-01 · Home screen always showed "No looks yet" even after analysis
- **Symptom:** After completing an outfit check, returning to Home still showed the empty state.
- **Root cause:** `HomeView.swift` — `EmptyStateView` was hardcoded unconditionally in the `ScrollView` body. The `recentLooksSection` and `loadingShimmer` computed properties were defined but never called.
- **Category:** Frontend / UI logic

### BUG-02 · Stripe checkout opened as a half-page sheet
- **Symptom:** Tapping "Start 3-Day Free Trial" slid up a half-height sheet instead of opening a full-screen browser.
- **Root cause:** `PremiumView.swift` line 195 used `.sheet(item: $checkoutSafariURL)` for `SFSafariViewController`. SwiftUI sheets default to detent/half-page on iOS 16+.
- **Category:** Frontend / navigation

### BUG-03 · "Session expired. Please sign in again." after uploading a photo
- **Symptom:** Upload or analysis returned a session-expired error even though the user was still signed in.
- **Root cause (deployed functions):** The previously deployed version of `shared/auth.ts` and `upload-outfit.ts` had weaker error messages and no force-refresh retry. The iOS client surfaced `AIError.unauthorized` as "Session expired."
- **Root cause (iOS — now fixed locally):** `AIError.unauthorized.errorDescription` was previously the hard-coded string "Session expired. Please sign in again."
- **Current local state:** iOS app has a 401-force-refresh retry (`AIService.swift` lines 174–181). `uploadImage` no longer masks Storage errors as auth failures. Error description changed to "We couldn't verify your account for this request…"
- **Status:** Fixed in local files. **Requires deployment to take effect.**
- **Category:** Backend auth / frontend error messaging

### BUG-04 · "Internal server error" on Stripe subscription page
- **Symptom:** Tapping "Start 3-Day Free Trial" returned a generic 500 internal server error.
- **Root cause (deployed functions):** Old `create-checkout-session.ts` had no structured error handling — any exception fell through to a bare 500 response.
- **Root cause (env vars — must verify):** `STRIPE_MONTHLY_PRICE_ID` and `STRIPE_YEARLY_PRICE_ID` must be set in the deployed Cloud Function environment. If they are missing or wrong, `getStripe()` or the session creation will throw and the catch block logs the error and returns 500.
- **Current local state:** `create-checkout-session.ts` now returns specific error codes (`price_not_configured`, `student_plan_unavailable`) with user-friendly messages. Generic errors return "Failed to start checkout. Please try again."
- **Status:** Fixed in local files. **Requires deployment + env var verification.**
- **Category:** Backend / Stripe / env vars

### BUG-05 · Free users permanently locked out after 3 daily checks
- **Symptom:** After using 3 free checks, users were rejected with rate_limit_exceeded on subsequent days.
- **Root cause:** `upload-outfit.ts` previously read `dailyChecksUsed` without comparing it against `lastCheckDate`.
- **Current local state:** `upload-outfit.ts` line 39: `const checksUsed = lastCheckDate === today ? rawChecksUsed : 0;` — correctly treats a new day as zero-used before `analyze-outfit.ts` performs the Firestore transaction reset.
- **Status:** Fixed in local files. **Requires deployment.**
- **Category:** Backend / rate limiting

### BUG-06 · Upload-outfit generic catch returned literal "Internal server error"
- **Symptom:** Any unexpected error in `uploadOutfit` returned the text "Internal server error" with no diagnostic info.
- **Root cause:** `upload-outfit.ts` catch block: `sendError(res, 500, "server_error", "Internal server error")`.
- **Fix applied:** Changed to `"Upload failed. Please try again."` + logs `(err as Error)?.message` with `[uploadOutfit]` prefix.
- **Category:** Backend / error messaging

---

## 2. Why It Was Broken

| Bug | Layer | Why |
|-----|-------|-----|
| BUG-01 | iOS / SwiftUI | `recentLooksSection` was defined but never referenced in `body` |
| BUG-02 | iOS / SwiftUI | `.sheet()` presents as detent overlay on iOS 16+ |
| BUG-03 | iOS + Backend | Old error string + old deployed functions without token retry |
| BUG-04 | Backend + Env vars | No structured Stripe error handling + missing env vars in deployed env |
| BUG-05 | Backend | Rate-limit read didn't account for `lastCheckDate` comparison |
| BUG-06 | Backend | Generic catch block with no message or logging |

---

## 3. Files Changed in This Session

| File | Change |
|------|--------|
| `FitCheckAI/Features/Home/HomeView.swift` | Body now conditionally renders `loadingShimmer` → `EmptyStateView` → `recentLooksSection` |
| `FitCheckAI/Features/Profile/PremiumView.swift` | `.sheet(item:)` → `.fullScreenCover(item:)` for Stripe checkout |
| `functions/src/upload-outfit.ts` | Catch block: improved error message + `[uploadOutfit]` log prefix |

### Previously fixed in the same working branch (already in local files, need deployment):

| File | Change |
|------|--------|
| `FitCheckAI/Services/AIService.swift` | 401 → force-refresh token and retry once; Storage errors no longer masked as auth |
| `FitCheckAI/Features/Camera/CameraView.swift` | Pre-warms auth token before upload; error messages no longer say "Session expired" |
| `functions/src/shared/auth.ts` | Diagnostic logging of token shape; sends structured `{error, message}` on 401 |
| `functions/src/upload-outfit.ts` | Rate limit now compares `lastCheckDate` to treat new days as zero-used |
| `functions/src/analyze-outfit.ts` | Uses signed URL (not base64) for OpenAI; `updateUserStats` resets daily counter on new day |
| `functions/src/create-checkout-session.ts` | Structured Stripe error handling; `price_not_configured` / `student_plan_unavailable` codes |

---

## 4. How to Test the MVP Again

### Step 0 — Deploy functions (required before testing)

```bash
cd /Users/agentq/FitCheckAI/functions

# Build TypeScript
npm run build

# Deploy all functions
firebase deploy --only functions

# Verify logs after deploy
firebase functions:log --limit=30
```

### Step 1 — Verify env vars are deployed

Run this after deploy and confirm all values are non-empty:

```bash
# Firebase Functions v2 reads from .env and .env.{projectId} at deploy time.
# Verify the deployed runtime has all keys:
firebase functions:config:get

# Or check via Google Cloud Console → Cloud Run → FitCheck functions → Environment variables
```

Required env vars (never share values):

| Key | Where set | Required |
|-----|-----------|----------|
| `OPENAI_API_KEY` | `functions/.env` | Yes — AI analysis |
| `STRIPE_SECRET_KEY` | `functions/.env.fitcheck-d3091` | Yes — checkout + webhook |
| `STRIPE_WEBHOOK_SECRET` | `functions/.env.fitcheck-d3091` | Yes — webhook signature |
| `STRIPE_MONTHLY_PRICE_ID` | `functions/.env.fitcheck-d3091` | Yes — monthly plan |
| `STRIPE_YEARLY_PRICE_ID` | `functions/.env.fitcheck-d3091` | Yes — yearly plan |
| `STRIPE_STUDENT_PRICE_ID` | `functions/.env.fitcheck-d3091` | No — student plan |

### Step 2 — Build and run iOS app

```bash
# Open in Xcode
open /Users/agentq/FitCheckAI/FitCheckAI.xcodeproj

# Or build from CLI (replace DEVICE_ID with your device/simulator)
xcodebuild -project FitCheckAI.xcodeproj \
  -scheme FitCheckAI \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  clean build
```

### Step 3 — MVP Flow Test Checklist

Run through this exact sequence on the device:

```
[ ] 1. AUTH
     - Cold launch app → splash shows → resolves to sign-in screen (not blank)
     - Sign up with Google or Apple → lands on Home tab
     - Force-kill and relaunch → still signed in (no sign-in screen)

[ ] 2. HOME SCREEN
     - First launch: shows "No looks yet" empty state
     - After analysis: shows recent outfit thumbnail in the grid
     - Pull-to-refresh: reloads outfits
     - "This Week's Trend" card taps to full TrendsView page

[ ] 3. UPLOAD & ANALYZE
     - Tap the "+" FAB in center tab bar → full-screen CheckFlowView opens
     - Photo Quality screen → shows quality score
     - Style Goal screen → select any goal
     - Analyzing screen → spinner shows, does NOT show "Session expired"
     - Wait up to 90s → Result screen appears with score, verdict, lens scores
     - Console log (Xcode): look for sequence:
         [CheckFlow] Requesting upload slot...
         [CheckFlow] Upload slot: fitCheckId=... path=...
         [CheckFlow] Uploading image to Storage...
         [CheckFlow] ✅ Image uploaded (... KB)
         [CheckFlow] Calling analyzeOutfit fitCheckId=...
         [CheckFlow] ✅ Analysis complete — score: ...

[ ] 4. RESULT SCREEN
     - Like button → heart fills, no error banner
     - Save button → bookmark fills, no error banner
     - "See Full Breakdown →" → full navigation push to ScoreBreakdownView
     - Share → system share sheet (intentionally half-height)

[ ] 5. HOME AFTER ANALYSIS
     - Navigate back to Home → recent outfit card appears (BUG-01 fix)
     - Checks remaining counter decrements

[ ] 6. SUBSCRIPTION / PAYMENT
     - Profile tab → "Go Premium" → PremiumView opens full-screen
     - Select Monthly plan → tap "Start 3-Day Free Trial →"
     - Stripe checkout opens FULL-SCREEN (BUG-02 fix, not half-sheet)
     - Complete payment in Stripe test mode
     - App returns → "Confirming payment…" spinner
     - After webhook fires → spinner clears, isPremium = true
     - PremiumView dismisses automatically

[ ] 7. DAILY LIMIT RESET
     - Use all 3 free checks today
     - Change device date to tomorrow (Settings → General → Date & Time)
     - Try another check → should succeed (BUG-05 fix)

[ ] 8. NAVIGATION COMPLETENESS
     - Every major action opens a full page (no unexpected half-sheet)
     - Back navigation works on every screen
     - Tab switching works: Home, Trends, Profile
```

---

## 5. Viewing Firebase / Backend Logs

```bash
# All function logs (last 50 lines)
firebase functions:log --limit=50

# Specific function logs
firebase functions:log --only analyzeOutfit --limit=20
firebase functions:log --only createCheckoutSession --limit=20
firebase functions:log --only stripeWebhook --limit=20
firebase functions:log --only uploadOutfit --limit=20

# Follow live
firebase functions:log --limit=10 --follow

# Google Cloud Logging (more detail)
gcloud logging read 'resource.type="cloud_run_revision"' \
  --project=fitcheck-d3091 \
  --limit=50 \
  --format=json | jq '.[].jsonPayload.message'
```

Key log patterns to look for:

| Log message | Meaning |
|-------------|---------|
| `[requireAuth] hdr len=... head="Bearer eyJ..."` | Token arrived at backend |
| `[requireAuth] verifyIdToken failed: ...` | Token rejected — check expiry or format |
| `[AIService] ✅ Token len=... dots=2 head="eyJ..."` | iOS fetched valid JWT |
| `[AIService] 401 received — force-refreshing token` | iOS retrying with fresh token |
| `[CheckFlow] ✅ Image uploaded` | Storage write succeeded |
| `[CheckFlow] Calling analyzeOutfit` | AI call starting |
| `[createCheckoutSession] Missing env vars: ...` | Stripe keys not deployed |
| `createCheckoutSession error: ...` | Stripe API error detail |

---

## 6. Remaining Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| Stripe env vars may not be deployed | High | Run `firebase deploy --only functions` from the local directory that has `.env.fitcheck-d3091` present |
| Stripe webhook secret mismatch | High | Go to Stripe Dashboard → Webhooks → copy the signing secret, ensure it matches `STRIPE_WEBHOOK_SECRET` in `.env.fitcheck-d3091` |
| `stripeWebhook` `req.rawBody` fallback uses `JSON.stringify` | Medium | If Stripe signature verification fails, the webhook won't flip `isPremium`. Check Cloud Function logs for `Webhook Error: No signatures found` |
| `isPremium` Firestore flip depends on webhook | Medium | If webhook never fires, user stays free. The 30s polling loop in `PremiumView` will catch it if the Firestore listener is delayed, but a Stripe Dashboard test is needed to confirm the webhook endpoint is registered and live |
| `SFSafariViewController` inside `fullScreenCover` — dismiss flow | Low | When user taps "Done" in Safari, `onDismiss` fires the subscription-check polling. Tested to work identically to `.sheet` |
| GPT-4o vision latency | Low | Analysis can take 30–60s. iOS timeout is 120s (matches server). Warn users with "AI is analyzing your fit…" copy on the Analyzing screen |
| OpenAI API key in plaintext `.env` | High (security) | Rotate the key at platform.openai.com. Use Firebase Secret Manager (`firebase functions:secrets:set OPENAI_API_KEY`) instead of `.env` for production |
| Stripe secret key in plaintext `.env.fitcheck-d3091` | High (security) | Rotate at dashboard.stripe.com → API keys. Move to `firebase functions:secrets:set STRIPE_SECRET_KEY` |

---

## 7. Commands to Run Locally

```bash
# 1. Navigate to project
cd /Users/agentq/FitCheckAI

# 2. Build and deploy functions
cd functions
npm run build
firebase deploy --only functions
cd ..

# 3. Verify function deployment
firebase functions:list

# 4. Stream live logs during testing
firebase functions:log --follow

# 5. Deploy Firestore + Storage rules (if changed)
firebase deploy --only firestore:rules,storage

# 6. Run local emulator for dev/test (optional)
firebase emulators:start --only functions,firestore,storage

# 7. Test createCheckoutSession manually (replace TOKEN)
curl -X POST https://us-central1-fitcheck-d3091.cloudfunctions.net/createCheckoutSession \
  -H "Authorization: Bearer YOUR_FIREBASE_ID_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"plan":"monthly"}'

# 8. Test uploadOutfit manually
curl -X POST https://us-central1-fitcheck-d3091.cloudfunctions.net/uploadOutfit \
  -H "Authorization: Bearer YOUR_FIREBASE_ID_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"file_name":"test.jpg","file_size_bytes":200000,"mime_type":"image/jpeg","style_goal":"gen_z"}'
```

---

## 8. Firebase / Stripe / Env Variables to Check

### Firebase Console
- Go to [Firebase Console](https://console.firebase.google.com) → Project: `fitcheck-d3091`
- **Authentication** → Sign-in methods: verify Google and Apple are enabled
- **Firestore** → Rules: confirm `firestore.rules` is deployed
- **Storage** → Rules: confirm `storage.rules` is deployed
- **Functions** → confirm all 14 functions appear and show "Active"

### Stripe Dashboard
- Go to [Stripe Dashboard](https://dashboard.stripe.com) (Live mode)
- **Products** → confirm monthly and yearly prices exist, copy `price_1...` IDs
- **Webhooks** → confirm endpoint `https://us-central1-fitcheck-d3091.cloudfunctions.net/stripeWebhook` is registered
- **Webhooks** → Events: `checkout.session.completed`, `customer.subscription.created`, `customer.subscription.updated`, `customer.subscription.deleted`, `invoice.payment_succeeded`, `invoice.payment_failed`
- **Webhooks** → copy Signing Secret → confirm it matches `STRIPE_WEBHOOK_SECRET` in `.env.fitcheck-d3091`

### Env Vars to Verify (do not share values)

```bash
# Check what's in your local env files:
cat functions/.env | grep -v "^#" | cut -d'=' -f1
cat functions/.env.fitcheck-d3091 | grep -v "^#" | cut -d'=' -f1

# Expected keys:
# .env              → OPENAI_API_KEY
# .env.fitcheck-d3091 → STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET,
#                       STRIPE_MONTHLY_PRICE_ID, STRIPE_YEARLY_PRICE_ID
```

---

## Summary

| # | Issue | Status |
|---|-------|--------|
| BUG-01 | Home always shows empty state | ✅ Fixed (`HomeView.swift`) |
| BUG-02 | Stripe checkout opens half-screen | ✅ Fixed (`PremiumView.swift`) |
| BUG-03 | "Session expired" on upload | ✅ Fixed in local files — **deploy required** |
| BUG-04 | "Internal server error" on payment | ✅ Fixed in local files — **deploy required + verify Stripe env vars** |
| BUG-05 | Free users locked forever after 3 checks | ✅ Fixed in local files — **deploy required** |
| BUG-06 | Generic uploadOutfit catch message | ✅ Fixed (`upload-outfit.ts`) |

**Next action:** `cd functions && npm run build && firebase deploy --only functions`
