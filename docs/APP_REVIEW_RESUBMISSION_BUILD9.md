# App Review Resubmission — Build 9 (1.0.0)

Focused P0 fixes on top of Build 8. No redesign, no new features. Marketing version unchanged (1.0.0); build bumped 8 → 9.

## What changed and why

### 1. Premium status wording (cancelled-but-still-active subscriptions)
A subscription with auto-renew turned off (Apple state `cancelling`, `trial=false`, with a future expiry) is **still fully active until the expiry date**. Build 8 showed scary/confusing wording for this case ("Cancels at period end"). Build 9 shows simple, accurate status everywhere from one shared `PremiumPhase` source of truth (Apple StoreKit entitlement + RenewalInfo):

| State | Profile card | Subtitle | Detail screen |
|---|---|---|---|
| Free | Upgrade to Premium | Unlimited checks · All 8 style lenses | Monthly + Yearly plans |
| Trial | Premium Trial — Active | Unlimited checks · Trial ends [date] | Status: Premium Trial Active / Trial ends [date] |
| Active (renewing) | Premium — Active | Unlimited checks · Renews [date] | Status: Active / Renews on [date] |
| Active (auto-renew off) | Premium — Active | Unlimited checks · Access until [date] | Status: Active until [date] / Access until [date] |
| Expired | Upgrade to Premium (paywall shows "Your Premium access ended [date]") | — | Plans + expired notice |

"Free Trial" never appears as a standalone status anywhere.

### 2. Restore Purchases is now always visibly confirmed
Root cause of "the alert wasn't seen": the Premium status screen had **two stacked `.alert` modifiers** on the same view — SwiftUI only reliably presents one `.alert` per view, so the restore result could be silently shadowed. That second alert (a manage-subscription fallback) was also dead code that nothing could ever trigger. Both issues fixed:
- Removed the dead fallback alert → restore now has a single, reliable `.alert`.
- The paywall previously showed restore feedback as an inline banner (which could sit below the fold / behind Apple's prompt) — it now shows a top alert too.
- Alert state is set on the main actor **after** Apple's restore prompt dismisses.

Restore messages (every outcome is shown):
- Already active → "Your Premium is already active."
- Restored → "Premium restored successfully." / trial → "Premium trial restored successfully."
- No subscription → "No active Premium subscription was found for this Apple ID."
- Cancelled → "Restore cancelled."
- Error → "We couldn't restore purchases right now. Please try again."
- Guest with active entitlement → "Premium restored. Sign in to keep your subscription synced safely." (offers Sign In)

Restore is also de-emphasised for active subscribers: **Manage Subscription** is the only primary button; Restore is a small footer link ("Already purchased? Restore Purchases"). Apple's required restore mechanism is retained.

### 3. Profile avatar no longer flickers
For a user with a real profile photo, the avatar briefly flashed a generated placeholder before the real photo loaded. The image view now shows a **neutral loading circle** while the photo loads and only falls back to the generated avatar if there is no photo (or it fails to load).

## Purchase flow
Unchanged and compliant: products are preloaded at launch, tapping a plan calls `product.purchase()` directly (Apple's native sheet), success unlocks Premium in-app and dismisses the paywall. Guests are shown a single sign-in gate before purchase. No web/Stripe payment.

## Backend
No backend changes. Verified the contract is intact: product IDs (`com.fitcheckai.premium.monthly` / `.yearly`) match the verifier's `PREMIUM_PRODUCT_IDS`, the client `syncAppleSubscription` endpoint matches the deployed function, the bundle ID (`ai.fitcheck.app`) matches, and `appStoreNotifications` reverse-maps renew/cancel/refund via `appleTransactions/{originalTransactionId}`.

## Build verification
- Debug simulator build: **succeeded**
- Release device build (validate-for-store): **succeeded**
- Embedded Info.plist: **CFBundleShortVersionString 1.0.0 / CFBundleVersion 9**
- Simulator launch: clean, no crash

## Reviewer test checklist
1. Active monthly, auto-renew off, future expiry → Profile "Premium — Active", subtitle "Access until [date]", detail "Active until [date]". No "Free Trial".
2. Free account → "Upgrade to Premium", Monthly + Yearly visible, small Restore link.
3. Restore while active → visible alert "Your Premium is already active."
4. Restore with no subscription → visible alert "No active Premium subscription…".
5. Restore cancelled at Apple prompt → visible alert "Restore cancelled."
6. Manage Subscription → opens Apple's native manage sheet (distinct from Restore).
7. Existing profile photo, open Profile repeatedly / slow network → no generated-avatar flash.
8. Guest → can view plans; purchase triggers sign-in gate; restore does not crash.

## Screen-recording checklist (for resubmission)
- [ ] Launch app → EULA/terms before login.
- [ ] Continue as guest → Home/Arena/scoreboard load; first fit check works; second fit check shows sign-in gate.
- [ ] Sign in → open Profile, show Premium status card wording.
- [ ] Open Premium → tap Restore → show the alert clearly, tap OK.
- [ ] Active user → Manage Subscription opens Apple's sheet.
- [ ] Profile with a real photo → no avatar flicker.

## Status
Code complete, both builds green. **Not committed, not uploaded** — pending manual on-device StoreKit UI test (simulator can't host real StoreKit purchase flows), then Xcode archive → upload → attach IAPs → Submit.
