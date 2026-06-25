# App Review Resubmission — Build 7 (1.0.0)

Two P0 fixes that address App Completeness (Guideline 2.1) and IAP (Guideline 3.1.1):

1. **Guest mode is now a real, usable mode** (was empty/broken).
2. **Restore Purchases now works for StoreKit 2 with clear feedback** (incl. guest).

Marketing version unchanged: **1.0.0**. Build: **6 → 7**.

---

## P0 #1 — Guest mode

### Why it was broken
"Continue as Guest" only set a local `UserDefaults` flag — there was **no Firebase
user**. Every Firestore read and every Cloud Function requires a Firebase ID token, so
in guest mode the scoreboard, Arena, and fit check all silently failed and the app
looked empty. A reviewer entering through Guest could not use the app → Guideline 2.1.

### The fix
Guest mode is now backed by **Firebase Anonymous Auth**. The guest gets a real uid +
ID token, so all reads/functions work, while Premium and public posting stay gated
behind a real account.

| Area | Before | After |
|---|---|---|
| Enter as Guest | local flag, no user | `signInAnonymously()` → real uid |
| Home | empty/failed reads | loads |
| Arena / public feed | failed | loads (approved content only) |
| Scoreboard / leaderboard | failed | loads |
| Open public fit detail | n/a | works |
| Report content | n/a | works (creates `reports` queue doc) |
| Block users | n/a | works (hides fits + comments instantly) |
| Fit check | failed | **exactly 1 free check**, result private |
| 2nd fit check | n/a | sign-in gate ("Save your style journey") |
| Vote / comment | n/a | sign-in gate (UGC stays protected) |
| Premium page | n/a | viewable; purchase → sign-in gate |
| Identity | blank | generated nickname + avatar |

### Guest 1-free-check limit
- Enforced **client-side** (`AppState.requestFitCheck()` routes a 2nd attempt to the
  gate) and **server-side** (`uploadOutfit` + `analyzeOutfit` reject anonymous users
  whose `guestFitCheckUsed === true` with code `guest_limit_reached`).
- The flag is stored locally (UserDefaults) and on the anonymous user doc
  (`guestFitCheckUsed`, backend-only — `firestore.rules` blocks client writes to it).
- No IDFA, no fingerprinting. Reinstall may reset local state and create a new
  anonymous uid — acceptable.

### Nickname + avatar generation
- `GuestIdentity.swift`: deterministic from the uid via a stable FNV-1a hash.
  - Nickname = adjective + animal, e.g. **"Velvet Panda"**, **"Lucky Falcon"**,
    **"Cosmic Tiger"**. Word lists are wholesome only (no sexual/political/religious/
    insulting terms).
  - Avatar = `GeneratedAvatarView.swift`: gradient circle + animal emoji. Never blank.
- Applied to: **guests**, **Apple private-relay/masked-email users**, and **any account
  with no name**. A masked Apple relay email is never shown as a name.
- Shown in Profile (and stored as `avatarEmoji`/`avatarColor` for leaderboards/mirror).

### Account conversion (guest → Apple/Google)
- `AuthService.signInOrLink`: when a guest signs in, the anonymous account is **linked**
  (uid preserved) so the nickname, avatar, and first fit carry over. If the credential
  already belongs to another account, we sign into that account instead (no duplicate
  broken profile). A generated nickname is upgraded to the real provider name on
  conversion; a name the user actually set is always preserved.

### UGC protection (Guideline 1.2) stays strong
- Public feed shows `moderationStatus == "approved"` only (fail-closed, unchanged).
- Guest-reported content hides instantly; guest-blocked users' fits + comments hide.
- Reports/blocks create developer queue records; guests cannot edit moderation status,
  approve their own content, post publicly, vote, or comment (server rejects anonymous
  on `voteHotFit` / `postArenaComment`; `autoEnterArena` also guards `!isAnonymous`).

---

## P0 #2 — Restore Purchases

### Why it looked broken
`restore()` **blocked guests** ("Please sign in to restore") and returned `void`, so the
only feedback was a generic `lastError`. There was no distinct messaging for the four
real outcomes, and a guest reviewer got a dead-end.

### The fix (`StoreKitService.restore()` → `RestoreOutcome`)
- Label is **"Restore Purchases"**; shows **"Restoring…"** and disables duplicate taps
  while running.
- Calls **`AppStore.sync()`**, then re-derives entitlement from
  `Transaction.currentEntitlements` with StoreKit verification (`checkVerified`).
- Verified, non-revoked, unexpired entitlement → `hasPremium`. Revoked/expired never
  unlocks. Firestore mirror is a soft bridge only — a missing mirror never downgrades.
- **Works for guests**: we no longer require sign-in just to check the Apple entitlement.

| Outcome | Message |
|---|---|
| Active sub (signed in) | "Premium restored successfully." (paywall dismisses) |
| Active sub (guest) | "Premium restored. Sign in to keep your subscription synced safely." → sign-in |
| No active sub | "No active Premium subscription was found for this Apple ID." |
| User cancels | "Restore cancelled." |
| Network/StoreKit error | "We couldn't restore purchases right now. Please try again." |

Does **not**: open Manage Subscription, silently fail, read only Firestore, downgrade off
a missing mirror, require re-buying, show success without a verified entitlement, or
auto-prompt Apple ID at launch (`AppStore.sync()` is only on the explicit button).

Product IDs confirmed: `com.fitcheckai.premium.monthly`, `com.fitcheckai.premium.yearly`.

---

## Files changed

**New (iOS)**
- `FitCheckAI/Services/GuestIdentity.swift`
- `FitCheckAI/Components/GeneratedAvatarView.swift`
- `FitCheckAI/Features/Auth/GuestSignInGateView.swift`

**Modified (iOS)**
- `App/AppState.swift` — anonymous guest auth, `requestFitCheck()`, guest-check tracking, gate flag
- `Services/AuthService.swift` — `signInAnonymously`, `signInOrLink` (conversion), identity seeding
- `Services/AIService.swift` — `guestLimitReached` (429 `guest_limit_reached`)
- `Services/StoreKitService.swift` — `RestoreOutcome`, guest restore, anon sync skip
- `Models/AppUser.swift` — `avatarEmoji` / `avatarColor`
- `Features/Auth/AuthView.swift` — guest copy
- `Features/Camera/CameraView.swift` — mark guest check used + handle guest-limit backstop
- `Features/Home/MainTabView.swift` — FAB → `requestFitCheck()`, gate sheet host
- `Features/Home/HomeView.swift` — hero CTA → `requestFitCheck()`
- `Features/Arena/ArenaView.swift` + `ArenaPostDetailView.swift` — gate vote/comment, empty state
- `Features/Profile/ProfileView.swift` — generated avatar, no masked email, guest sign-in CTA
- `Features/Profile/PremiumView.swift` — restore handler + messages
- `Resources/Info.plist` + `project.pbxproj` — build 6 → 7

**Backend / config**
- `functions/src/shared/auth.ts` — expose `provider` / `isAnonymous`
- `functions/src/upload-outfit.ts` + `analyze-outfit.ts` — guest 1-check limit + autoEnter guard
- `functions/src/arena.ts` — reject anonymous on vote/comment
- `firestore.rules` — block client writes to `guestFitCheckUsed`

---

## Build / deploy / verification status

- ✅ `tsc --noEmit` (functions) — clean
- ✅ iOS **Debug** simulator build — BUILD SUCCEEDED
- ✅ iOS **Release** device build (`-validate-for-store`) — BUILD SUCCEEDED, embedded **1.0.0 (7)**
- ✅ Firestore **rules** + functions `uploadOutfit`, `analyzeOutfit`, `voteHotFit`,
  `postArenaComment` **deployed** to `fitcheck-d3091`
- ✅ **Anonymous Auth provider enabled** in Firebase (required for guest mode)

### Still required before submit (human)
1. Archive in Xcode and upload **build 7** to App Store Connect.
2. Attach the two IAPs (`READY_TO_SUBMIT`) to the 1.0.0 version.
3. Confirm Apple + Google sign-in providers are enabled in Firebase (already were).
4. Sandbox/TestFlight pass of the test flow below (live OpenAI + StoreKit sandbox).
5. Submit.

> NOT "ready to resubmit" until the sandbox test flow below passes on a real build.

---

## App Review Notes (paste into ASC "Notes")

```
FitCheck — Reviewer notes (build 7)

GUEST MODE (no account needed):
1. Launch the app.
2. On the sign-in screen, tick "I agree to the Terms of Use and EULA" (required).
3. Tap "Continue as Guest".
4. You get an auto-generated nickname (e.g. "Velvet Panda") and avatar.
5. Home, Arena (public feed), and the leaderboards are all usable.
6. Open a public fit → you can Report it (it disappears) and Block the user.
7. Tap the + button to run ONE free Fit Check (use a full-body photo). The result is
   private to the guest.
8. Try a second Fit Check → "Save your style journey" sign-in gate appears. Tap
   "Maybe Later" to return to browsing (no dead-end). Voting/commenting also prompt
   sign-in to keep community content safe.

PREMIUM / RESTORE PURCHASES:
- Profile → "Upgrade to Premium" (or the paywall) shows Monthly + Yearly products.
- Buying Premium requires signing in first (so the subscription is tied to an account).
- "Restore Purchases" works in guest mode: it checks the Apple entitlement and shows a
  clear result. If an active subscription exists it unlocks and asks you to sign in to
  sync it.

UGC SAFETY (Guideline 1.2): EULA gate before any login; public feed shows only
moderation-approved content; report + block available everywhere; reports go to a
developer moderation queue actioned within 24h.

Test account (optional, full features): available on request.
```

---

## Screen recording checklist

1. Cold launch → sign-in screen.
2. Tick EULA checkbox → tap **Continue as Guest**.
3. Show generated **nickname + avatar** (Profile tab).
4. **Home** visible with content.
5. **Arena** visible (public feed) — open a public fit.
6. **Report** the fit → it disappears. **Block** a user → their content disappears.
7. **Scoreboard / leaderboard** visible.
8. Tap **+** → run **1 free Fit Check** → show the result.
9. Tap **+** again → **"Save your style journey"** gate → tap **Maybe Later** → back to app (no crash).
10. Open **Premium** → show **Monthly + Yearly** products load.
11. Tap **Restore Purchases** → show **"Restoring…"** then the result message.
12. (If available) show **Manage Subscription** separately for an active subscriber.
```
