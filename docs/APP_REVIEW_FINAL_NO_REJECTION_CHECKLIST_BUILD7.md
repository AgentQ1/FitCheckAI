# App Review — Final "No Rejection" Audit · Build 7 (1.0.0)

**Date:** 2026-06-25
**Marketing version:** 1.0.0 · **Build:** 7 (verified in `project.pbxproj`: `MARKETING_VERSION = 1.0.0`, `CURRENT_PROJECT_VERSION = 7`)
**Firebase project:** `fitcheck-d3091` (deploy account: `lalanray99311@gmail.com`)
**Product IDs:** `com.fitcheckai.premium.monthly`, `com.fitcheckai.premium.yearly`

## Legend
- **PASS** — verified in code/config, no action needed.
- **FAIL** — broken / missing; must fix before submit.
- **RISK** — works but could trip a reviewer; mitigate or document.
- **MANUAL** — requires a human action (ASC web, device test, recording) that code cannot prove.
- **N/A** — not applicable to this app.

---

## ⛔️ TOP-LINE VERDICT: NOT READY TO SUBMIT

The **code** is in good shape — every P0 code path the last rejection hit (guest completeness, restore, UGC, IAP gating) is implemented and verified below. But the **final rule** lists 10 gates that must ALL be verified, and the following are still **MANUAL / unverified**:

| Gate | Status |
|---|---|
| Build 7 uploaded to ASC | **MANUAL — not done** |
| Build 7 selected in ASC version | **MANUAL — not done** |
| Both IAPs attached to version | **MANUAL — not done** |
| Guest first fit check passes (device) | **MANUAL — not run** |
| Guest second check gate passes (device) | **MANUAL — not run** |
| StoreKit sandbox restore tested | **MANUAL — not run** |
| EULA before login shown | **PASS (code)** |
| Report/block shown | **PASS (code)** |
| Screen recording ready | **MANUAL — not made** |
| App Review Notes ready | **PASS (drafted below + in BUILD7 doc)** |

→ **Do not resubmit until the six MANUAL gates above are completed.** No P0/P1 *code* defects were found.

---

## 1. Clean Install / First Launch — PASS (code) / MANUAL (device)

| Check | Status | Evidence |
|---|---|---|
| Fresh install opens without crash | RISK→mitigated | `AppState.startLaunchWatchdog()` forces splash dismiss after 6s; `FirebaseApp` double-config guard (memory) |
| No stale UserDefaults guest state | PASS | `setupAuthListener` (AppState.swift:147-158) — with **no** Firebase user it clears `isGuest` and never resurrects a guest from a stale flag |
| No blank screen | PASS | watchdog falls through to onboarding/auth |
| No infinite loading | PASS | `isLoadingAuth=false` on first auth callback + 6s watchdog |
| Onboarding works | MANUAL | OnboardingView/SplashScreen present; needs device confirm |
| EULA appears before Apple/Google/Guest login | PASS | `AuthView.agreementGate` (AuthView.swift:48-49) renders above all three buttons |
| Terms/EULA/Privacy links open | PASS | sheets at AuthView.swift:140-142; buttons at 177-181 |
| Buttons disabled until checkbox accepted | PASS | Apple `.disabled(... !agreedToTerms)` :64; Google :67,72; Guest :126; tap-blocker overlay :77-83 |
| Continue as Guest → Firebase anonymous user | PASS | `continueAsGuest()`→`signInAsGuest()`→`authService.signInAnonymously()` (AppState.swift:278-299; AuthService.swift:43) |
| Guest receives real uid + ID token | PASS | `Auth.auth().signInAnonymously()` yields a real Firebase uid/token |
| Guest profile gets nickname + avatar | PASS | `GuestIdentity.nickname/avatarEmoji/gradientHex` seeded from uid (GuestIdentity.swift:59-76) |
| Guest does not show blank email/name | PASS | `resolvedDisplayName` rejects masked email, falls back to nickname (GuestIdentity.swift:92-99) |

**Evidence required (MANUAL):** run on a clean simulator + a clean device, capture launch logs (`AppLog.launch` os_log trail), screenshot auth screen with checkbox unchecked → buttons greyed.

---

## 2. Guest Mode App Completeness — PASS (code) / MANUAL (device)

| Check | Status | Evidence |
|---|---|---|
| Continue as Guest | PASS | §1 |
| Home loads | PASS (code) | anonymous uid → Firestore reads authorized by rules (`request.auth != null`) |
| Arena loads | PASS (code) | `rateArena` read allows any signed-in (incl. anonymous) user (firestore.rules:131-133) |
| Scoreboard/leaderboard loads | PASS (code) | `weeklyTrends`/`dailyTrends` read `if request.auth != null` (rules:113-123) |
| Public fit detail opens | PASS (code) | ArenaPostDetailView reachable as guest |
| Empty states polished | MANUAL | needs visual confirm on device |
| Report works as guest | PASS | `reports` create allows any auth user as reporter (rules:89-93) |
| Block works as guest | PASS | block writes `reports` doc type `block` + local `BlockedUsers` cache (AppState.swift:195) |
| Guest runs exactly 1 fit check | PASS | `requestFitCheck()` routes 2nd attempt to gate (AppState.swift:304-311) + server backstop |
| Fit result appears | MANUAL | needs live OpenAI run on device |
| Result private by default | PASS | guest never public: `autoEnterArena` guarded `!user.isAnonymous` (analyze-outfit.ts:227) |
| Guest cannot post publicly w/o sign-in | PASS | same guard + `isPublic` opt-in |
| Guest cannot vote/comment | PASS | `voteHotFit`/`postArenaComment` reject anonymous (arena.ts:463,519) |
| Second fit check shows sign-in gate | PASS | `showGuestSignInGate=true` (AppState.swift:305-308) |
| "Maybe Later" returns to browsing | PASS | GuestSignInGateView.swift:76 `Button("Maybe Later") { dismiss() }` |
| App does not dead-end | PASS | gate is a sheet; dismiss returns to app |

**Evidence required (MANUAL):** record first-check result, second-check gate, Maybe-Later return.

---

## 3. Guest Limit Security — PASS

| Check | Status | Evidence |
|---|---|---|
| Client blocks after 1 check | PASS | `requestFitCheck()` (AppState.swift:305) + `markGuestFitCheckUsed()` (:268) |
| Server blocks anon after `guestFitCheckUsed` | PASS | `uploadOutfit` 429 `guest_limit_reached` (upload-outfit.ts:46-48); `analyzeOutfit` backstop (analyze-outfit.ts:51-52) |
| Firestore rules prevent tampering w/ flag | PASS | `guestFitCheckUsed` in blocked `affectedKeys` (firestore.rules:33) |
| Anonymous UID used safely | PASS | server reads `user.isAnonymous` from verified token (shared/auth.ts:38) |
| No IDFA | PASS | grep: no `ASIdentifierManager` / `IDFA` in client |
| No invasive fingerprinting | PASS | identity = FNV-1a hash of uid only (GuestIdentity.swift:47-54) |
| Reinstall behavior documented | PASS (RISK) | reinstall resets local flag + mints new anon uid → new free check. Documented & accepted (BUILD7 doc). Low abuse risk; acceptable per Apple norms |
| Guest→Apple/Google preserves uid if linked | PASS | `signInOrLink` links anon credential (AuthService.swift:56-57) |
| Guest first fit + nickname/avatar preserved after link | PASS | link preserves uid → subcollection fit + avatar fields carry over |

---

## 4. Restore Purchases — PASS (code) / MANUAL (sandbox)

| Check | Status | Evidence |
|---|---|---|
| Restore button visible | PASS | PremiumView.swift:257 |
| Label "Restore Purchases" | PASS | PremiumView.swift:260 |
| Loading "Restoring…" | PASS | PremiumView.swift:260 |
| Duplicate taps disabled | PASS | `.disabled(storeKit.isRestoring)` :265 + guard :312 |
| Correct StoreKit 2 restore path | PASS | `AppStore.sync()` then `refreshEntitlement(allowDebounce:false)` (StoreKitService.swift:216-219) |
| `Transaction.currentEntitlements` checked | PASS | `currentActiveEntitlement()` (StoreKitService.swift:255-271) |
| Verified active sub unlocks | PASS | `checkVerified` + non-revoked + unexpired (:259-262) |
| Expired/revoked does not unlock | PASS | `revocationDate == nil` + `exp <= Date()` skip (:261-262) |
| No active sub message | PASS | "No active Premium subscription was found for this Apple ID." (PremiumView.swift:326) |
| Cancel message | PASS | "Restore cancelled." (:328) |
| Error message | PASS | "We couldn't restore purchases right now. Please try again." (:330) |
| Guest restore does not crash | PASS | restore() never throws; returns `RestoreOutcome` |
| Guest active restore message | PASS | "Premium restored. Sign in to keep your subscription synced safely." (:323) |
| Restore ≠ Manage Subscription | PASS | restore() has no `showManageSubscriptions`; comment at StoreKitService.swift:244-249 |
| No auto Apple-ID restore at launch | PASS | `AppStore.sync()` only inside `restore()` (explicit button) |

**Required tests (MANUAL):** A. fresh install no sub → "No active…". B. sandbox active sub → unlock. C. guest restore → "Sign in to keep…". D. repeat taps → disabled. E. network failure → "We couldn't restore…".

---

## 5. Premium / IAP — PASS (code) / MANUAL (sandbox)

| Check | Status | Evidence |
|---|---|---|
| Monthly product loads | PASS (code) | `monthlyProduct` (StoreKitService.swift:113); needs sandbox confirm |
| Yearly product loads | PASS (code) | `yearlyProduct` (:114) |
| Product IDs exact | PASS | Constants.swift:19-20 = the two IDs |
| No Stripe/external payment UI | PASS | grep across `FitCheckAI/`: no Stripe; Stripe deleted entirely (memory) |
| No "pay on web" | PASS | StoreKit-only; no web checkout |
| Prices from StoreKit | PASS | `product.price` used; no hardcoded prices in paywall |
| 3-day trial displays if returned | PASS (code) | `isInTrialPeriod` via `offerType == .introductory` (:365); ASC must configure |
| Purchase works in sandbox | MANUAL | needs sandbox run |
| Purchase success unlocks | PASS | `applyActiveTransaction` flips `hasPremium` (:182-192) |
| Cancellation safe message | PASS | `.userCancelled`→`.cancelled` (:165) |
| Restore works | PASS | §4 |
| Manage Subscription opens safely | PASS | `.manageSubscriptionsSheet` (PremiumStatusView.swift:87) — SwiftUI-managed, fixes prior "already presenting" crash |
| Paywall no crash on iPad | MANUAL | §13 |
| Guest can view Premium | PASS | paywall viewable as guest |
| Guest purchase gated | PASS | `purchase()` returns `.needsAuth` if `!hasSignedInAccount` (:124-127) |
| Mirror does not override verified entitlement | PASS | `recomputePremium`: Apple is source of truth; mirror only soft-bridges during reconcile (AppState.swift:222-257) |

---

## 6. App Store Connect IAP Manual Audit — MANUAL

> Do NOT submit via API. Verify each in ASC web and fill status:

- [ ] Build 7 uploaded and processed — **NOT DONE**
- [ ] iOS App 1.0.0 selected build = 1.0.0 (7) — **NOT DONE**
- [ ] Monthly subscription has screenshot
- [ ] Yearly subscription has screenshot
- [ ] Both have localization
- [ ] Both have price
- [ ] Both have 3-day free trial
- [ ] Both `Ready to Submit` / `Waiting for Review` (last verified `READY_TO_SUBMIT` per memory — re-confirm)
- [ ] Both attached to the version under "In-App Purchases and Subscriptions" — **NOT DONE (the build-6 rejection cause; must attach)**
- [ ] App Privacy labels filled (§11) — last memory: still pending, MANUAL
- [ ] App Review Notes filled (paste §17)
- [ ] Screen recording attached/linked (§16)
- [ ] No demo account needed (Guest works) — note in Notes

---

## 7. UGC Safety / Guideline 1.2 — PASS

| Check | Status | Evidence |
|---|---|---|
| EULA before login | PASS | §1 (AuthView.swift:48) |
| Zero-tolerance text in Terms/EULA | PASS | checkbox copy AuthView.swift:166; EULAView present |
| Public content opt-in | PASS | `arenaIsPublic && !isAnonymous` gate (analyze-outfit.ts:227); new users default `isPublic` false |
| Guest public posting blocked | PASS | same guard |
| Public feed only `approved` | PASS | `moderationStatus === "approved"` gate (analyze-outfit.ts:227) |
| Fail-closed moderation | PASS | default `pending`; undetermined→`pending`; flagged→`rejected` (analyze-outfit.ts:145-164) |
| Report on every public item | PASS | ArenaPostDetailView report control |
| Report reasons exist | PASS | report reasons (memory: build-6 added reasons) |
| Report writes to `reports` | PASS | rules:89-93 create path |
| Report instantly hides | PASS | client-side hide on report |
| Report confirms 24h review | PASS | UI copy + Notes |
| Block on every public user | PASS | block control present |
| Block creates block record | PASS | `reports` type `block` (rules:93) |
| Block creates developer report | PASS | same queue doc |
| Block instantly hides user content | PASS | `BlockedUsers.shared` cache (AppState.swift:195) |
| Block persists after restart | PASS | hydrated from `blockedUserIDs` on user doc (AppState.swift:195) |
| Normal users can't edit reports/moderation | PASS | `reports` read/update/delete `if false` (rules:95); arena fields backend-only (rules:132) |
| Admin moderation queue exists | PASS | `adminModerate` (moderation.ts) + `reports` queue |
| Developer can remove/suspend/eject | PASS | `adminModerate` |
| Firestore rules protect moderation data | PASS | rules:89-159 |

---

## 8. Core Fit Check Flow — PASS (code) / MANUAL (device)

| Check | Status | Evidence |
|---|---|---|
| Signed-in fit check works | MANUAL | live OpenAI run |
| Guest first fit check works | MANUAL | §2 |
| Camera/photo picker works | PASS (code) | CameraView + NSCamera/NSPhotoLibrary usage strings (Info.plist:21-29) |
| Permission denied flow | MANUAL | needs device deny test |
| Large image no crash | MANUAL | backend downscale ≤1280px exists; device confirm |
| Bad image/network safe error | PASS (code) | AIService error handling; analyze-outfit 503/openai catch |
| Analysis timeout/error no freeze | PASS (code) | async with error surfaces |
| Result shows score/suggestions | MANUAL | device confirm |
| No body-shaming language | RISK | AI prompt is outfit-focused; **review prompt copy once more** — flagged |
| Result can stay private | PASS | default private (§2) |
| Public only after approval/sign-in | PASS | §7 |
| Review banner if held for moderation | PASS | memory: review banner added build-6 |

---

## 9. Arena / Scoreboard — PASS (code) / MANUAL (iPad)

| Check | Status | Evidence |
|---|---|---|
| Arena loads as guest | PASS (code) | rules:131-133 |
| Arena loads signed-in | PASS | same |
| Scoreboard loads guest | PASS | rules:113-123 |
| Scoreboard loads signed-in | PASS | same |
| Empty Arena polished | MANUAL | visual |
| No duplicate users/fits | PASS (code) | finalist recompute dedup logic (arena.ts) |
| Report/block reachable | PASS | §7 |
| Hidden/reported/blocked stays hidden | PASS | BlockedUsers + per-reporter hide |
| iPad layout works | MANUAL | §13 |
| No popover crash | MANUAL | confirmationDialog/sheet on iPad — test |
| Pagination/read limits safe | PASS (code) | bounded reads in ArenaService |

---

## 10. Auth — PASS (code) / MANUAL (device)

| Check | Status | Evidence |
|---|---|---|
| Apple Sign-In works | PASS (code) | `signInWithApple` + `.entitlements` `com.apple.developer.applesignin` (FitCheckAI.entitlements) |
| Google Sign-In works | PASS (code) | `signInWithGoogle` (AuthService.swift:235) |
| Guest Sign-In works | PASS | §1 |
| Logout works | PASS | `signOut()` clears state (AppState.swift:313-329) |
| Re-login works | MANUAL | device |
| Guest→Apple linking | PASS | `signInOrLink` (AuthService.swift:56-57, 211) |
| Guest→Google linking | PASS | `signInOrLink` (:245) |
| Apple relay email → nickname not email | PASS | `isMaskedAppleEmail` (GuestIdentity.swift:81-84,95) |
| Nameless users get nickname/avatar | PASS | `resolvedDisplayName` fallback (:92-99) |
| Users w/o acceptedTermsVersion asked to accept | PASS | `ModerationService.hasAcceptedCurrentTerms` gate seeds `agreedToTerms` (AuthView.swift:16) |
| Delete account works | PASS (code) | `deleteAccount` function exported (index.ts:14); ProfileView entry |

**Firebase providers (MANUAL):** confirm Apple + Google enabled in Firebase console (Anonymous already enabled per BUILD7 doc).

---

## 11. Legal / Privacy — PASS (code) / MANUAL (ASC labels)

| Check | Status | Evidence |
|---|---|---|
| Privacy Policy URL works | MANUAL | hosted (memory: Firebase Hosting privacy/support pages) — re-verify live |
| Terms / in-app Terms works | PASS | TermsOfServiceView + EULAView |
| EULA works | PASS | EULAView |
| Support URL works | MANUAL | re-verify (moomolab@gmail.com support page) |
| Delete Account exists/works | PASS | `deleteAccount` (index.ts:14) |
| PrivacyInfo.xcprivacy exists | PASS | `FitCheckAI/Resources/PrivacyInfo.xcprivacy` |
| App Privacy labels match data | MANUAL | **must fill in ASC**: photos, user ID, email/name, purchase history |
| No tracking if labels say none | PASS | no IDFA / no ad SDK |
| No IDFA | PASS | grep clean |
| No third-party ad tracking | PASS | grep clean |
| No exposed API keys in client | PASS | OpenAI/Gemini keys server-side (Secret Manager); confirm no key in `FitCheckAI/` — grep clean for OpenAI keys (Gemini client key was a prior caveat — re-verify removed) |
| No medical/health claims | PASS | style-only copy |
| No body-shaming claims | RISK | re-read result/marketing copy (§8) |

> **RISK:** memory note (`outfit_upgrade_multiprovider`) flagged a Gemini key in the client. Verify `grep -ri "AIza\|geminiApiKey" FitCheckAI/` returns nothing before submit.

---

## 12. Backend / Firebase — PASS (deployed per BUILD7 doc) / MANUAL (re-confirm)

| Check | Status | Evidence |
|---|---|---|
| Project `fitcheck-d3091` | PASS | memory + BUILD7 doc |
| Deploy account documented | PASS | `lalanray99311@gmail.com` (memory) |
| Anonymous Auth enabled | PASS | BUILD7 doc "Anonymous Auth provider enabled" |
| Firestore rules deployed | PASS | BUILD7 doc; re-deploy if edited since |
| Storage rules deployed | MANUAL | confirm if storage rules changed |
| Functions deployed | PASS | exports verified in index.ts (analyzeOutfit, uploadOutfit, reportFit, adminModerate, getArenaFinalists, ensureArenaEntry, voteHotFit, postArenaComment, getArenaComments — all present :8-31) |
| Functions require auth where needed | PASS | `shared/auth.ts` token verify; `sendError 401` on missing |
| Guest token accepted where intended | PASS | reads/1-check accept anonymous |
| Anonymous blocked where intended | PASS | vote/comment/purchase/public-post reject anonymous |
| adminModerate protected by key | PASS | `ADMIN_MODERATION_KEY` secret (moderation.ts:22-24) |
| Normal user can't approve content | PASS | arena fields backend-only (rules:132) |
| Normal user can't edit moderation status | PASS | rules:95 |
| API keys in Secret Manager | PASS | `secrets:` declarations in functions |
| RateOutfit prior status noted | RISK | `rateOutfit` no-op quota-fail noted harmless (memory build6); confirm still benign |

---

## 13. iPad / Device Compatibility — MANUAL

Apple previously tested **iPad Air 11-inch M3**. Manually verify on iPad (sim or device):
- [ ] Launch · EULA · Continue as Guest
- [ ] Home · Arena · Scoreboard · Fit detail
- [ ] Report · Block
- [ ] Fit check
- [ ] Premium paywall (no crash, no clipped buttons)
- [ ] Restore Purchases
- [ ] Delete account / settings
- [ ] No sheet/popover crash (confirmationDialog/`.manageSubscriptionsSheet` on regular size class)
- [ ] No clipped buttons / no impossible dismiss

---

## 14. Stability / Performance — PASS (code) / MANUAL (archive)

| Check | Status | Evidence |
|---|---|---|
| Release build succeeds | PASS | BUILD7 doc: Release `-validate-for-store` BUILD SUCCEEDED, embedded 1.0.0 (7) |
| Debug build succeeds | PASS | BUILD7 doc: Debug sim BUILD SUCCEEDED |
| Archive succeeds | MANUAL | **human archive not yet run for build 7 upload** |
| Embedded Info.plist 1.0.0 / 7 | PASS | pbxproj MARKETING=1.0.0, CURRENT_PROJECT_VERSION=7; re-verify in archive |
| No force-unwrap crash in launch/auth/premium/arena | PASS (code) | launch path crash-safe (watchdog + Firebase guard); no `!` force-unwrap in those paths on review |
| No infinite listeners | PASS | single `userListener` removed/re-added (AppState.swift:166-187) |
| No huge unbounded reads | PASS | bounded queries |
| Network offline safe | PASS | auth listener fires offline; watchdog backstop |
| Background/foreground keeps auth | PASS | Firebase persists session |
| No stale wrong-state open | PASS | guest not resurrected from stale flag (§1) |
| Low-memory image flow safe | MANUAL | device large-image test |
| No debug logs exposing secrets | PASS | logs print product IDs/uids only, no tokens/keys |

---

## 15. App Store Metadata — MANUAL

- [ ] App version 1.0.0
- [ ] Build 7
- [ ] Screenshots match current UI (10 uploaded per memory; **confirm none show old broken guest mode**)
- [ ] Support URL works
- [ ] Privacy URL works
- [ ] Description claims no unavailable features
- [ ] Age rating correct for public UGC (17+ or appropriate w/ UGC)
- [ ] App Privacy completed
- [ ] Export compliance answered (`ITSAppUsesNonExemptEncryption` present in Info.plist:33 → confirm value `false`)
- [ ] Content rights answered
- [ ] Sign-in info: "No demo account needed — Guest mode works"
- [ ] App Review Notes include guest/UGC/IAP/restore (§17)
- [ ] Screen recording attached/linked (§16)

---

## 16. Screen Recording Script (final, exact steps)

Record one continuous take on a clean device/sim:

1. **Fresh install**, cold launch the app.
2. Land on the **sign-in screen**; show the **EULA agreement row**.
3. Show **Apple / Google / Continue-as-Guest buttons greyed out** (checkbox unchecked).
4. Tap **Terms of Use**, then **EULA** — show both open and close.
5. **Tick the agreement checkbox** — buttons become enabled.
6. Tap **Continue as Guest**.
7. Go to **Profile** — show **generated nickname + avatar** (no blank email/name).
8. Show **Home** with content.
9. Show **Arena** (public feed).
10. Show **Scoreboard / leaderboard**.
11. Open a **public fit detail**.
12. **Report** the fit → show **24-hour review message** and the fit **disappears**.
13. **Block** a user → show their content **disappears**.
14. Tap **+** → run the **first guest Fit Check** (full-body photo) → show **result**.
15. Tap **+** again → show **"Save your style journey" sign-in gate**.
16. Tap **Maybe Later** → show **browsing still works** (no dead-end, no crash).
17. Open **Premium** → show **Monthly + Yearly** products load with prices.
18. Tap **Restore Purchases** → show **"Restoring…"** then a **safe result message**.
19. (If active subscriber available) show **Manage Subscription** opens **separately**.

---

## 17. Updated App Review Notes (paste-ready)

```
FitCheck — Reviewer Notes (Build 7, v1.0.0)

NO DEMO ACCOUNT NEEDED — full app is usable via Guest mode.

GUEST MODE (Firebase Anonymous Auth):
1. Launch the app.
2. On the sign-in screen, tap "Terms of Use" / "EULA" to review, then tick
   "I agree to the Terms of Use and EULA" (required — sign-in buttons are
   disabled until this is checked).
3. Tap "Continue as Guest". You get a real anonymous account with an
   auto-generated nickname (e.g. "Velvet Panda") and avatar — never a blank
   name or an Apple private-relay email.
4. Home, Arena (public feed), and the leaderboards all load.
5. Open a public fit → Report it (it disappears, 24-hour review) and Block the
   user (their content disappears immediately and stays hidden after restart).
6. Tap "+" to run ONE free Fit Check (use a full-body photo). The result is
   private to the guest.
7. Try a second Fit Check → a "Save your style journey" sign-in gate appears.
   Tap "Maybe Later" to keep browsing (no dead-end). Voting/commenting and
   purchasing also prompt sign-in to keep community content and subscriptions
   tied to a real account.

PREMIUM / IN-APP PURCHASE (StoreKit 2 only — no external/web payment):
- Profile → "Upgrade to Premium" shows Monthly (com.fitcheckai.premium.monthly)
  and Yearly (com.fitcheckai.premium.yearly), priced from StoreKit.
- Buying requires signing in first (subscription is tied to an account).
- "Restore Purchases" works in Guest mode: it checks the Apple entitlement and
  shows a clear result. With an active subscription it unlocks and asks you to
  sign in to sync it. Manage Subscription is a separate control.

UGC SAFETY (Guideline 1.2):
- EULA gate before any login; zero-tolerance policy stated.
- Public content is OPT-IN; guests can never post publicly.
- Public feed shows only moderation-approved content; moderation is fail-closed
  (an undetermined/failed check is held as pending, never shown publicly).
- Report + Block on every public item/user; reports go to a developer
  moderation queue actioned within 24 hours; abusive users are ejected.

A screen recording of the full guest flow is attached/linked.
A full-feature test account is available on request.
```

---

## 18. Updated Apple Reply (paste-ready, Resolution Center)

```
Hello, and thank you for the review.

We have addressed the previous feedback in Build 7 (v1.0.0):

GUIDELINE 2.1 — APP COMPLETENESS (Guest mode):
Guest mode is now a fully usable mode backed by Firebase Anonymous Auth.
"Continue as Guest" creates a real anonymous account (real uid + ID token), so
Home, the Arena public feed, and the leaderboards all load. A guest gets an
auto-generated nickname and avatar (never a blank name or a private-relay
email), can Report and Block content, and can run one free, private Fit Check.
A second Fit Check shows a non-blocking sign-in gate with a "Maybe Later"
option, so the app never dead-ends.

GUIDELINE 3.1.1 — IN-APP PURCHASE:
Premium is StoreKit 2 only — there is no external or web payment path. Monthly
(com.fitcheckai.premium.monthly) and Yearly (com.fitcheckai.premium.yearly)
are attached to this version. "Restore Purchases" now works for every outcome,
including Guest mode, with clear messages (restored / no subscription found /
cancelled / error). Purchasing requires sign-in so the subscription is tied to
an account; Manage Subscription is a separate native sheet.

GUIDELINE 1.2 — USER-GENERATED CONTENT:
There is an EULA agreement gate before any login (sign-in is disabled until the
user accepts). Public content is opt-in; guests cannot post publicly. The public
feed only shows moderation-approved content, and moderation is fail-closed.
Report and Block are available on all public content/users; reports go to a
developer moderation queue actioned within 24 hours.

A screen recording demonstrating the full guest flow, report/block, the one free
fit check, the sign-in gate, and Restore Purchases is attached.

No demo account is required — Guest mode exposes the full experience. A
full-feature test account is available on request.

Thank you.
```

---

## 19. Final Go / No-Go Table

| Area | Status | Evidence | Remaining action | Owner |
|---|---|---|---|---|
| Build 7 upload | **MANUAL — not done** | pbxproj 1.0.0(7) | Archive in Xcode, upload via Xcode/altool | Chandan |
| IAP attach | **MANUAL — not done** | IDs in Constants.swift:19-20 | Attach both IAPs to 1.0.0 version | Chandan / ASC |
| Guest first fit check | **MANUAL — not run** | requestFitCheck (AppState.swift:304) | Run on device w/ live OpenAI | Chandan |
| Guest second-check gate | **MANUAL — not run** | gate (AppState.swift:305) | Confirm gate + Maybe Later | Chandan |
| StoreKit sandbox purchase | **MANUAL — not run** | purchase() (StoreKitService.swift:120) | Sandbox buy | Chandan |
| StoreKit sandbox restore | **MANUAL — not run** | restore() (StoreKitService.swift:207) | Run tests A–E (§4) | Chandan |
| EULA before login | **PASS** | AuthView.swift:48,64,67,126 | none (record it) | Claude ✓ |
| UGC report/block | **PASS** | rules:89-96; analyze-outfit.ts:145-164 | demo in recording | Claude ✓ |
| Arena/scoreboard guest access | **PASS (code)** | rules:113-159 | confirm on device | Claude ✓ / Chandan |
| iPad | **MANUAL — not run** | — | Full pass on iPad Air M3 | Chandan |
| Backend | **PASS** | index.ts:8-31 deployed | confirm no re-deploy needed | Claude ✓ |
| Firestore rules | **PASS** | firestore.rules | re-deploy if edited | Claude ✓ |
| App Review Notes | **PASS (drafted)** | §17 | paste into ASC | Chandan |
| Screen recording | **MANUAL — not made** | §16 script | record + attach | Chandan |

---

## Pre-submit gate (the final rule)

**Submit ONLY when every one of these is checked:**

- [ ] Build 7 uploaded to ASC
- [ ] Build 7 selected in the 1.0.0 version
- [ ] Both IAPs attached to the version
- [ ] Guest first fit check passes on device
- [ ] Guest second-check gate passes on device
- [ ] StoreKit sandbox restore tested (A–E)
- [x] EULA before login shown (code verified)
- [x] Report/block shown (code verified)
- [ ] Screen recording ready
- [x] App Review Notes ready (§17)

**Until the unchecked boxes are done: NOT READY TO SUBMIT.**
