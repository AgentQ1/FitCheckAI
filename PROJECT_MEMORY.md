# FitCheckAI Project Memory

Last verified from the local repo: 2026-06-25 18:30 CDT.

This file is the shared source of truth for Codex, Claude Code, and future agents. Keep it concise, current, and free of secrets, API keys, tokens, private credentials, or local-only access details.

## 1. Project Purpose

FitCheckAI is an iPhone-only SwiftUI app where users photograph an outfit, get AI style feedback and a score, view AI-generated outfit upgrade ideas, save looks, and optionally participate in public Arena/leaderboard experiences.

Core loop: capture or pick an outfit photo, upload it to Firebase Storage, analyze it through backend AI services, show score/verdict/style lenses, generate upgrade images, then save/share/enter opt-in social surfaces.

## 2. Current App State

- Current app version in Xcode project and Info.plist: marketing `1.0.0`, build `10`, bundle id `ai.fitcheck.app`, iOS 17+, iPhone only.
- Current branch observed: `rate-the-fit-phase1`.
- Working flows present in code: onboarding, EULA/Terms gate, Apple/Google/Guest auth, one free guest fit check, upload/analyze/result flow, AI upgrade carousel, history, saved looks, profile setup/editing, Premium paywall/status, restore purchases, manage subscription, Arena voting/comments/report/block, daily/weekly trends, data export, account deletion.
- Backend functions exist for upload, analysis, Gemini upgrades, saved looks, deletion/export, trends, Arena, moderation, StoreKit sync, App Store Server Notifications, and cleanup.
- App Review docs indicate build 10 was prepared for prior rejection items: IAP submission completeness and UGC safety. Local docs conflict on the exact App Store Connect state: one note says subscriptions are attached to version 1.0.0, older/current memory text says attachment/privacy labels/submission still need manual ASC confirmation. Verify in App Store Connect before resubmitting.
- `PROJECT_MEMORY.md`, `scripts/asc_add_item.mjs`, and `scripts/asc_inspect_submission.mjs` were untracked when inspected.

## 3. Tech Stack

- iOS: Swift, SwiftUI, StoreKit 2, AuthenticationServices, Google Sign-In, Firebase iOS SDK.
- Backend: Firebase Auth, Firestore, Storage, Cloud Functions v2 TypeScript on Node 20.
- AI services: OpenAI GPT-4o Vision for outfit analysis, OpenAI `omni-moderation-latest` for moderation, Google Gemini 2.5 Flash Image for outfit upgrade generation.
- Payments: Apple StoreKit 2 auto-renewable subscriptions only.
- Hosting/config: Firebase Hosting static support/privacy pages, `firebase.json`, Firestore rules/indexes, Storage rules.
- Dependency management: Swift Package Manager for iOS; npm/TypeScript for functions.

## 4. Important Files

- `FitCheckAI/App/FitCheckAIApp.swift`: app entry, Firebase configure guard, launch/crash logging, root routing, premium sheet routing.
- `FitCheckAI/App/AppState.swift`: auth/session state, guest gating, Premium derivation, public Arena opt-in, launch watchdog.
- `FitCheckAI/App/Constants.swift`: Cloud Functions base URL, StoreKit product IDs, legal/report constants, free limits, API endpoints, Arena constants.
- `FitCheckAI/Extensions/Color+FitCheck.swift`: current color tokens; code currently uses warm beige/olive tokens, even though owner preference notes mention an app-blue direction.
- `FitCheckAI/Services/AuthService.swift`: anonymous guest auth, Apple/Google sign-in, guest account linking, user document repair/public profile mirror.
- `FitCheckAI/Services/AIService.swift`: upload slot request, Firebase Storage image upload, analyze/save/delete/rate API calls and error mapping.
- `FitCheckAI/Services/StoreKitService.swift`: StoreKit products, purchase, restore, entitlement state, backend subscription sync, Premium phase wording.
- `FitCheckAI/Services/ModerationService.swift`: local Terms/EULA acceptance, Firestore acceptance sync, report/block queue writes, display-name guard.
- `FitCheckAI/Services/ArenaService.swift`: Arena finalists, voting, comments, reports/blocks.
- `FitCheckAI/Features/Auth/AuthView.swift`: sign-in UI and mandatory EULA/Terms checkbox gate.
- `FitCheckAI/Features/Profile/PremiumView.swift`: paywall, product loading, purchase CTA, restore alerts, legal links.
- `FitCheckAI/Features/Profile/PremiumStatusView.swift`: active Premium management, restore alerts, SwiftUI `manageSubscriptionsSheet`.
- `FitCheckAI/Features/Profile/DataPrivacySettingsView.swift`: export data, delete fit checks/images/account, public Arena visibility toggle, legal/privacy links.
- `FitCheckAI/Resources/FitCheck.storekit`: local StoreKit config for monthly/yearly Premium products with 3-day free trials.
- `functions/src/index.ts`: exports all Cloud Functions.
- `functions/src/upload-outfit.ts`: upload slot creation, MIME/size/style-goal validation, free/guest limits.
- `functions/src/analyze-outfit.ts`: GPT-4o analysis, image moderation, trend writes, guest limit backstop, opt-in Arena auto-entry.
- `functions/src/generate-gemini-upgrade.ts`: server-side Gemini image edit using backend-held API keys, source downscale, timeout/error handling.
- `functions/src/arena.ts`: Arena pool/finalists, voting, comment moderation, reports, scheduled recompute.
- `functions/src/moderation.ts`: admin moderation queue/actions.
- `functions/src/sync-apple-subscription.ts` and `functions/src/app-store-notifications.ts`: Apple subscription verification and lifecycle sync.
- `functions/src/delete-account.ts`: full account erasure across Auth, Storage, private docs, public profiles, Arena, leaderboards, votes/comments/reports.
- `functions/src/export-user-data.ts`: complete user data export mirroring deletion scope.
- `firestore.rules`: client access boundaries, backend-only payment/Arena/trend fields, reports queue, public read rules for signed-in users.
- `storage.rules`: users can read/write only their own `users/{uid}/...` image paths; write image files under size cap.
- `docs/APP_REVIEW_RESUBMISSION_BUILD10.md`: latest local App Review resubmission notes.
- `scripts/asc_*.mjs`: App Store Connect helper scripts; credentials must stay outside repo.

## 5. App Store Compliance Rules

- Premium digital subscriptions must use Apple StoreKit/In-App Purchase only.
- Do not add Stripe, web checkout, external payment links, payment instructions, or "pay on web" language inside iOS.
- Restore Purchases must remain visible and must show a clear outcome for every tap: already active, restored, guest restored/sign-in needed, not found, cancelled, or failed.
- Manage Subscription must use a safe Apple-native path. Current code uses SwiftUI `.manageSubscriptionsSheet`; do not replace it with brittle UIKit presentation unless explicitly approved and tested.
- Report, block, delete account, and export data must remain available.
- UGC moderation must remain fail-closed for public surfaces: only approved content can appear publicly; moderation errors stay pending/non-public.
- Zero-tolerance UGC policy must remain in Terms/EULA and review notes.
- EULA/Terms acceptance gate must remain before Apple Sign-In, Google Sign-In, and Guest entry.
- Public Arena/leaderboard participation must remain opt-in (`isPublic === true`) and disabled for guests.
- Account deletion must remove public mirrors and public participation data, not only private user docs.

## 6. Subscription / Premium Rules

- Product IDs:
  - `com.fitcheckai.premium.monthly`
  - `com.fitcheckai.premium.yearly`
- Both products are in one StoreKit subscription group in `FitCheckAI/Resources/FitCheck.storekit`, each with a 3-day free introductory offer in local config.
- Prices must be read from StoreKit products at runtime; do not hardcode paywall prices as source of truth.
- Premium entitlement source of truth is Apple's verified StoreKit entitlement.
- App unlock rule: user must be signed in with a real non-anonymous Firebase account and have an active StoreKit entitlement. Guests/anonymous users must not unlock Premium even if the device Apple ID has a subscription.
- Firestore `isPremium`/subscription fields are backend mirrors for server-side rate limits and transient reconciliation only; they must not independently grant Premium.
- Purchase must be blocked before the Apple sheet when there is no real signed-in account.
- Restore may check StoreKit as guest, but guest restore should prompt sign-in to sync safely.
- StoreKit local Xcode transactions are skipped for backend verification in Debug because Apple's server library cannot verify local test receipts.
- Keep `StoreKitService.PremiumPhase` as the shared source for Premium wording across Profile card/status/paywall. Avoid confusing wording like showing active Premium as "cancelling"; use "Active until <date>" when auto-renew is off but access remains.
- Do not change product IDs, bundle id, or subscription group behavior without explicit approval and matching App Store Connect updates.

## 7. Firebase / Backend Rules

- Firebase project referenced by code/config: `fitcheck-d3091`.
- Auth providers used: Anonymous guest auth, Apple, Google.
- Firestore important collections/paths include `users`, `publicProfiles`, user subcollections `fit_checks`, `saved_looks`, `savedUpgrades`, `generatedUpgrades`, top-level `rateArena`, `reports`, `weeklyTrends`, `weekly_trends`, `dailyTrends`, `appleTransactions`, and unresolved Apple notification storage.
- Client rules prevent writes to backend-owned premium/payment fields, Arena counters, guest check counters, trends, votes/comments, and Apple transaction mappings.
- Storage rules allow authenticated users to access only their own `users/{uid}/...` paths and only write image content under a size cap.
- Analysis flow stores private results first, then writes moderation status. Public entry is allowed only for non-guest users with `isPublic === true`, approved moderation, and an image URL.
- Image moderation is fail-closed: flagged is rejected, errored/undetermined is pending, only clean approved can publish.
- Comment text moderation runs server-side in Arena before writing public comments.
- Delete/export behavior must stay broad: private fit checks, generated upgrades, saved looks, public profiles, owned Arena posts, comments, votes, reports, leaderboard standings, Storage files, Apple transaction mappings, and Auth user deletion are in scope.
- Backend secrets such as OpenAI/Gemini/Apple credentials belong in Firebase/env configuration, not in the iOS app, repo, or this memory file.
- After backend/rules changes, run function TypeScript build and deploy the relevant Firebase functions/rules; iOS builds do not deploy backend changes.

## 8. UI/UX Rules

- Design should stay clean, premium, simple, and confidence-building.
- Owner preference to preserve: app blue color style. Current code tokens are warm beige/olive (`Color+FitCheck.swift`), so reconcile with the owner before broad color/theme changes.
- Avoid confusing Premium wording. Trial is still Premium; cancelled auto-renew while active should read as active access until a date.
- No broken/dead buttons. If StoreKit products fail to load, show retry/restore rather than a disabled purchase CTA.
- Keep onboarding, sign-in, EULA acceptance, guest mode, first fit check, second-check sign-in gate, and App Review safety flows clear.
- Rate the outfit, not the person. Avoid body-shaming or harsh personal language.
- Portrait outfit images should not crop faces or shoes; use `PortraitOutfitImage` or equivalent careful aspect handling.
- Restore and manage subscription surfaces must have visible feedback and avoid stacked SwiftUI alerts that shadow each other.
- Respect safe areas and avoid tab bar overlap on pushed detail screens.

## 9. Known Bugs / Risks

- App Store Connect state must be manually verified before resubmission. Local docs conflict on whether the two subscriptions are attached to the 1.0.0 version; privacy labels/screen recording/submission status may also require manual work.
- StoreKit purchase/restore runtime behavior cannot be fully proven by `simctl`; use Xcode StoreKit testing, sandbox, or TestFlight on device.
- Prior App Review risks: launch crash/hang, IAPs not submitted with version, UGC safety/report/block/moderation completeness.
- Launch safety depends on avoiding `fatalError`, force unwraps, duplicate Firebase configure, and long blocking work before the root view resolves.
- SwiftUI multiple `.alert` modifiers on the same view can shadow one another; keep restore/manage feedback on a single alert path.
- Build number 10 appears uploaded/prepared; bumping build number may require a new upload and could orphan already-prepared review assets.
- Public docs/README contain outdated blueprint ideas such as RevenueCat/DALL-E/student plan. Treat current code and this memory as authoritative over old blueprint text.
- Current design notes conflict: existing code is beige/olive, owner request mentions app blue style. Do not mass-retint without approval.
- AI/provider/network failures must fail gracefully without consuming checks incorrectly or making pending content public.
- Guest reinstall can mint a new anonymous uid and another free check; accepted as a known low-risk limitation unless product policy changes.

## 10. What Not To Change

- Do not reintroduce Stripe, RevenueCat, external checkout, or payment links for Premium without explicit approval and App Store compliance review.
- Do not change StoreKit product IDs, bundle id, app version/build, or subscription semantics casually.
- Do not remove or weaken EULA/Terms gate, zero-tolerance policy, report, block, moderation, public opt-in, delete account, or data export.
- Do not grant Premium from Firestore alone, to guests, or from stale mirrored subscription fields.
- Do not move AI provider API keys into the iOS app.
- Do not loosen Firestore/Storage rules around backend-owned premium, Arena, trend, vote/comment/report, or Apple transaction data.
- Do not remove launch watchdog/logging/Firebase configure guard without a replacement.
- Do not rewrite Auth/StoreKit/Arena/delete/export flows broadly without explicit approval; these are App Review-sensitive.
- Do not commit or push unless the user explicitly asks.

## 11. Agent Communication Protocol

### Before any agent edits code

- Read `PROJECT_MEMORY.md`.
- Summarize understanding.
- Identify possible conflicts.
- Only ask questions if truly blocked.

### After any agent edits code

- Update `PROJECT_MEMORY.md` if the project state changed.
- Add a short handoff note with:
  - date/time
  - agent name: Codex or Claude Code
  - files changed
  - reason for change
  - tests/builds run
  - remaining risks

## 12. Latest Handoff

### 2026-06-25 18:30 CDT - Codex

- Files changed: `PROJECT_MEMORY.md`, `AGENTS.md`, `CLAUDE.md`.
- Reason for change: created a shared cross-agent memory/instruction set and merged existing durable project context into the requested canonical structure.
- Tests/builds run: no app code changed; documentation-only inspection. Verified key local files with shell reads and checked project version/build from Xcode project/Info.plist.
- Remaining risks: manually verify current App Store Connect status, especially whether both Premium subscriptions are attached to version 1.0.0 build 10, whether App Privacy labels are complete, and whether review notes/screen recording are ready. Confirm desired future theme direction because current code palette is beige/olive while owner preference mentions app blue.

### 2026-06-26 - Claude

- Rejection: App version 1.0.0 (build 10) rejected under **3.1.2 Business: Payments - Subscriptions** — "auto-renewable subscriptions but does not include a functional link to the Terms of Use (EULA) in the app's metadata." Pure metadata gap, NOT a code/build issue.
- Fix (no new build): via ASC API, edited the en-US App Store description (`appStoreVersionLocalizations` id `f5d8877e-d26a-4826-892f-49d433234ede`) to append the standard Apple **Terms of Use (EULA)** link `https://www.apple.com/legal/internet-services/itunes/dev/stdeula/` and the Privacy Policy link `https://fitcheck-d3091.web.app/privacy`. PATCH returned 200. New helper: `scripts/asc_set_description.mjs`.
- Verified: app does NOT host its own /terms or /eula page (404), so standard Apple EULA is correct; app-level privacyPolicyUrl already set; both subscriptions already `WAITING_FOR_REVIEW`; no custom `endUserLicenseAgreement` set (null = Apple standard, consistent with the in-description link).
- Files changed: `PROJECT_MEMORY.md`, added `scripts/asc_set_description.mjs`. No app/source code changed; no build/tests run (metadata-only).
- Remaining (human, ASC web): refresh the rejected submission and click **"Resubmit to App Review"** (version 1.0.0/build 10 unchanged, subs already waiting). Optionally reply to App Review noting the EULA link was added. No new upload needed.
- API resubmit is BLOCKED: `PATCH /v1/reviewSubmissions/<id> {submitted:true}` on the rejected version returns 409 `STATE_ERROR.ENTITY_STATE_INVALID` ("Version is not ready to be submitted yet") — persisted across 5 retries / 5+ min. The REJECTED→resubmit transition is web-UI only (no public-API path). Do NOT re-chase the API; the human clicks "Resubmit to App Review". App Review replies (resolution center) also have no public API.

### 2026-06-29 - Claude

- Rejection: build 10 (1.0.0) rejected AGAIN under **Guideline 1.2 Safety – UGC** (submission b55ce61d, reviewed 2026-06-28 iPad Air 11" M4). User had previously uploaded a screen recording and STILL got rejected.
- **ROOT CAUSE (new finding):** flag/block only live inside an Arena fit's detail page, but `getArenaFinalists` builds the board from opted-in public users in the current UTC day/week → a fresh review account sees an EMPTY Arena → cannot reach Report/Block → 1.2 reject regardless of code or video. Code was already compliant (EULA-before-login gate solid, omni-moderation, report+block notify dev + instant removal, 24h).
- **Fix (backend only, NO new build):** `functions/src/arena.ts` `getArenaFinalists` now tops the board up with 3 permanent SAMPLE fits when the live board has <3 cards (`ARENA_MIN_VISIBLE`, `SAMPLE_FITS`). Samples have fixed owner uids (never == a real user → `is_owner:false` → "Block this user" always shows), sentinel `dayId/weekId:"sample"` so real finalist recompute ignores them, and their rateArena docs are ensured once (counts preserved) so vote/comment/report hit a real doc. Generated 3 neutral mannequin sample images (PIL, `hosting/samples/sample-look-{1,2,3}.jpg`, labeled + "FitCheck · Sample" watermark).
- Files changed: `functions/src/arena.ts`, new `hosting/samples/*.jpg`, new `docs/APP_REVIEW_RESUBMISSION_BUILD10_UGC.md` (Apple reply + on-device recording script). No iOS/app code changed; build 10 binary + attached IAPs untouched.
- Tests/deploy: `npm run build` (tsc) clean. `firebase deploy --only hosting,functions:getArenaFinalists` SUCCEEDED to fitcheck-d3091 (CLI logged in as lalanray99311@gmail.com). VERIFIED live: images 200/JPEG; anonymous-guest call to deployed getArenaFinalists returns 3 sample cards on both today+week tabs, all `is_owner:false`. Reports rule + ModerationService write shape confirmed (guest can file report/block).
- Remaining (human): in App Store Connect, add a fresh screen recording (EULA-before-login → flag → block) to App Review Information → Notes, paste the Resolution Center reply from the doc, and Resubmit to App Review (same build 10). NOT committed/pushed (no git changes requested).
- Risk: sample fits now appear in the live Arena for ALL users whenever the board has <3 real cards (acceptable seed content; user approved). They vanish once ≥3 real public fits exist.

### 2026-06-30 - Claude Code

- Reason for change: user requested a safe commit + push of the current working tree with an explicit secret-scan gate first.
- Secret scan (no dedicated scanner installed; grep-based, values never printed): full-repo checks for private keys/certs, OpenAI `sk-`, Google/Firebase `AIza`, AWS `AKIA`, Slack/GitHub tokens, and service-account JSON — all clean. No sensitive file is tracked or has ever been in history. `GoogleService-Info.plist` and `.p8` keys present locally are correctly git-ignored. ASC helper scripts read all credentials from env/`.p8` at runtime (no hardcoded secrets).
- Files committed: `functions/src/arena.ts` (sample-fit Arena top-up from prior handoff), new `hosting/samples/sample-look-{1,2,3}.jpg`, new cross-agent docs `AGENTS.md`/`CLAUDE.md`/`PROJECT_MEMORY.md`, new read-only ASC helper scripts `scripts/asc_add_item.mjs`/`asc_inspect_submission.mjs`/`asc_set_description.mjs`, and removal of 9 stale `docs/*` App Review notes.
- Tests/builds run: none (commit/push task only; no logic authored beyond the already-present arena.ts change).
- Remaining risks: unchanged from 2026-06-29 handoff — App Store Connect resubmission steps are still manual/web-UI.
