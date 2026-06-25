# App Review Resubmission — Build 10 (1.0.0)

Addresses the two rejection items on submission `9372427d` (reviewed against build 5):

- **Guideline 2.1(b) — App Completeness:** the "Premium" In-App Purchases were not
  submitted *with* the app version.
- **Guideline 1.2 — Safety / User-Generated Content.**

Marketing version unchanged (1.0.0); build **9 → 10**. (Builds 6–9 were prepared but
never uploaded; ASC's highest prior build is 5.)

## 2.1(b) — In-App Purchases
Both auto-renewable subscriptions already exist and are `READY_TO_SUBMIT` with review
screenshots:

| Product ID | Type | State |
|---|---|---|
| `com.fitcheckai.premium.monthly` | Auto-renewable | READY_TO_SUBMIT |
| `com.fitcheckai.premium.yearly` | Auto-renewable | READY_TO_SUBMIT |

Both are now attached to the 1.0.0 review submission alongside build 10, so they are
reviewed *with* the app. Purchase flow is native StoreKit 2 (`product.purchase()`),
prices read from the App Store at runtime, success unlocks Premium in-app; Restore and
Manage Subscription are present. No web/Stripe payment path.

## 1.2 — UGC Safety (every public surface: outfit photos, display names, Arena cards, comments)

1. **Terms/EULA gate before any sign-in.** [AuthView] shows a required agreement
   checkbox — *"I agree to the Terms of Use and EULA, and understand FitCheck has zero
   tolerance for objectionable content or abusive users."* Apple Sign-In, Google Sign-In
   **and** Guest are all disabled until it is ticked. Acceptance (version + timestamp) is
   recorded locally immediately and mirrored to the user doc after login
   (`acceptedTermsVersion` / `acceptedTermsAt` / `acceptedTermsByUid`).
2. **Zero-tolerance EULA.** [EULAView] leads with the zero-tolerance policy and states
   reports are reviewed and actioned **within 24 hours**.
3. **Objectionable-content filtering (no public visibility until it passes).**
   - Images: every outfit photo is screened by OpenAI `omni-moderation-latest` before it
     can enter any public surface. **Fail-closed** — only a positive *approved* verdict
     publishes; flagged → rejected, errored/undetermined → pending (never public).
   - Text: Arena comment free-text is screened by the same model server-side
     (`postArenaComment`); flagged comments are rejected.
   - Names: obviously abusive display names are blocked client-side before they reach
     public leaderboards/cards.
   - Public participation is **opt-in** (`isPublic === true`); new/guest users are private.
4. **Report.** Every finalist and comment has a Report action (6 reason categories). A
   durable record is written to the top-level `reports` queue
   (`reporterUid`, `reportedUid`, `contentId`, `contentType`, `reason`, `status:"open"`,
   `createdAt`) and the content is hidden from the reporter instantly.
5. **Block.** Every finalist/comment has Block user. Blocking persists to
   `users/{uid}.blockedUserIDs` (+ local cache), files a developer notification, and the
   user's fits **and** comments disappear from this person's Arena immediately
   (`onChange` re-filter + dismiss).
6. **Developer notification + 24h action.** Reports and blocks land in the `reports`
   queue; `adminModerate` (admin-key gated) lists the queue and can `remove_content`,
   `suspend_user`, and `resolve_report` to act within 24 hours.
7. **Deletion erases public mirrors.** Account deletion removes Storage files, the user
   doc + subcollections, the `publicProfiles` mirror, owned Arena posts, leaderboard
   rows, comments, votes, and reports — nothing identifiable remains public.

## What changed since the build-9 working tree
- **Server-side comment text moderation** added (`moderateText` in `shared/openai.ts`,
  applied in `postArenaComment`) — closes the only UGC gap (free-text was previously
  unscreened).
- **Display-name safety guard** (`ModerationService.isDisplayNameAcceptable`) applied in
  profile setup.
- Build bumped 9 → 10.

## Verification
- `tsc --noEmit` (functions): clean.
- iOS Debug clean **build**: succeeded. iOS **analyze**: succeeded (no warnings).
- Firebase: firestore + storage rules deployed; all UGC/IAP Cloud Functions deployed
  (`postArenaComment`, `analyzeOutfit`, `adminModerate`, `reportFit`, `deleteAccount`,
  `exportUserData`, full Arena set).
- Embedded Info.plist: `CFBundleShortVersionString 1.0.0` / `CFBundleVersion 10`.

## App Review reply (paste into Resolution Center)
> Thank you for the review. We have addressed both items:
>
> **2.1(b):** Both auto-renewable subscriptions (Monthly and Yearly "FitCheck Premium")
> are complete with pricing, localization, and review screenshots, and are now submitted
> together with this version (build 10). The paywall uses native StoreKit In-App Purchase
> with Restore and Manage Subscription.
>
> **1.2:** The app now demonstrates the full UGC safety set: (a) a Terms of Use/EULA
> agreement with a zero-tolerance statement that must be actively accepted before any
> sign-in, registration, or guest entry; (b) automated filtering of objectionable content
> — outfit photos and comment text are screened by an OpenAI moderation model and nothing
> becomes public until it passes (public participation is also opt-in); (c) a Report action
> on every public fit and comment; (d) a Block action on every user, which instantly
> removes their content from the viewer's feed; (e) reports and blocks notify us through an
> in-app moderation queue we review and action within 24 hours, including removing content
> and suspending abusive accounts. Account deletion also removes all public copies of a
> user's content.
>
> A short screen recording of the EULA gate, report, and block flows is linked in App
> Review Information notes. Thank you.
