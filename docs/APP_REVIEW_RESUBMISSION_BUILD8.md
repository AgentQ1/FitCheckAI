# App Review Resubmission — Build 8 (1.0.0)

One P0 area: **Premium status wording + Restore Purchases feedback** (Guideline 2.1
App Completeness / 3.1.1 In-App Purchase). No new features — this is a
correctness/clarity pass on the subscription surfaces that a reviewer touches.

Marketing version unchanged: **1.0.0**. Build: **7 → 8**.

---

## Bug #1 — Premium status wording was contradictory

### Why it was confusing
The Profile card always said **"Premium ✦ — Active"**, while the Premium detail screen
showed **Status: "Free Trial"**. Two surfaces describing the same subscription
disagreed, and a bare "Free Trial" reads like a *different, non-Premium* plan. During a
3-day intro trial a reviewer saw "Active" in one place and "Free Trial" in another →
looks broken / incomplete.

### The fix — one shared model
A single `StoreKitService.PremiumPhase` (`trial` / `active` / `cancelling` / `none`) now
drives every Premium surface, so they can never disagree.

| State | Profile card | Detail screen | Date row |
|---|---|---|---|
| **Trial** | "Premium Trial — Active" · "Unlimited checks · Trial ends Jun 27, 2026" | Status: **Premium Trial Active** | **Trial ends** Jun 27, 2026 |
| **Paid (auto-renew)** | "Premium ✦ — Active" | Status: **Active** | **Renews on** [date] |
| **Cancelling** | "Premium ✦ — Active" | Status: **Cancels at period end** | **Access until** [date] |
| **Expired** | "Upgrade to Premium" | Paywall with **"Your Premium access ended [date]"** + upgrade options | — |
| **Free** | "Upgrade to Premium" | Paywall (monthly/yearly) | — |

The word "Free Trial" is gone as a standalone status — a trial is now always shown as
**"Premium Trial Active"** (it *is* Premium, just in its trial window).

---

## Bug #2 — Restore Purchases gave no feedback

### Why it looked broken
On the active-Premium **status screen**, the Restore button ran
`Task { await storeKit.restore() }` and **threw away the result**. After the Apple
account prompt the user tapped OK and… nothing visible happened — no success, no
failure, no "already active". (The paywall already handled this; the status screen did
not.) A reviewer can't tell whether restore worked → Guideline 2.1 / 3.1.1 risk.

### The fix — every tap produces a visible result
`restore()` now returns a specific outcome and **both** Premium surfaces present a clear
message for it. Duplicate taps are blocked (button disabled + `isRestoring` guard) and
the button shows "Restoring…" + spinner.

| Situation | Message shown |
|---|---|
| Already had Premium | "Your Premium is already active." |
| Subscription restored | "Premium restored successfully." |
| Trial restored | "Premium trial restored successfully." |
| Nothing to restore | "No active Premium subscription was found for this Apple ID." |
| Apple prompt cancelled | "Restore cancelled." |
| StoreKit / network error | "We couldn't restore purchases right now. Please try again." |
| Guest with entitlement | "Premium restored. Sign in to keep your subscription synced safely." (offers Sign In) |

"Already active" vs "restored" is distinguished by capturing `hasPremium` *before*
`AppStore.sync()`. Restore stays separate from **Manage Subscription** (Apple's native
sheet) — Restore never opens Manage.

---

## App Review notes (paste into "Notes for Reviewer")

> FitCheck Premium is a StoreKit 2 auto-renewable subscription (Monthly / Yearly), each
> with a 3-day free trial.
>
> • **Premium status wording** is now consistent across the Profile card and the Premium
>   detail screen. During the free trial both show "Premium Trial Active" with the trial
>   end date; after the trial they show "Active" with the renewal date.
> • **Restore Purchases** always shows a clear result (already active / restored /
>   nothing found / cancelled / error). It is separate from "Manage Subscription".
> • **Guest mode**: tap "Continue as Guest" to browse and run one free check. Restore and
>   Premium are available; purchasing prompts sign-in so the subscription is tied to an
>   account.
>
> To test Premium: sign in → Profile → tap the Premium card → Start Premium (3-day free
> trial). The Profile card then reads "Premium Trial — Active".

---

## Screen-recording checklist (for the reviewer reply / your capture)

1. Profile shows **"Premium Trial — Active"** + "Trial ends Jun 27, 2026".
2. Tap the card → detail shows **Current Plan: Monthly · Status: Premium Trial Active ·
   Trial ends: Jun 27, 2026** (no "Free Trial" anywhere).
3. Tap **Restore Purchases** → Apple prompt → **OK** → alert **"Your Premium is already
   active."** (no silent return).
4. Tap **Restore Purchases** → Apple prompt → **Cancel** → alert **"Restore cancelled."**
5. Tap **Manage Subscription** → Apple's native manage sheet opens (separate from
   Restore) → dismiss without crash.
6. (Free/guest path) Sign out or use Guest → Premium card reads **"Upgrade to Premium"**;
   paywall shows Monthly + Yearly; **Restore Purchases** → **"No active Premium
   subscription was found for this Apple ID."**
7. Repeat-tap Restore mid-flight → button is disabled / shows "Restoring…", no duplicate
   prompt, no stuck spinner.

---

## Files changed (Build 8)

| File | Change |
|---|---|
| `FitCheckAI/Services/StoreKitService.swift` | `PremiumPhase` model + computed phase; enriched `RestoreOutcome` (alreadyActive / restored(trial:) / restoredGuest / notFound / cancelled / failed); `restore()` captures pre-state + App-Review-safe logging; `recentlyExpiredDate()`; shared `displayDate`; trial flag set directly from the transaction |
| `FitCheckAI/Features/Profile/PremiumStatusView.swift` | Phase-driven status/plan/date wording; **restore result alert** (was silent); Sign-In action for guest; "Restoring…" label |
| `FitCheckAI/Features/Profile/PremiumView.swift` | Restore switch updated for new outcomes; "Your Premium access ended [date]" expired notice |
| `FitCheckAI/Features/Profile/ProfileView.swift` | Subscription card trial wording ("Premium Trial — Active" + trial-ends subtitle) |
| `FitCheckAI/App/AppState.swift` | `premiumPhase` accessor (account-gated, soft-bridge safe) |
| `FitCheckAI/Resources/Info.plist` · `project.pbxproj` | `CFBundleVersion` / `CURRENT_PROJECT_VERSION` **7 → 8** |

## Verification
- iOS **Debug** (simulator) build: **BUILD SUCCEEDED**.
- iOS **Release** (device, `-validate-for-store`) build: **BUILD SUCCEEDED**; embedded
  **1.0.0 (8)**.
- Launch smoke test on iPhone 17 Pro simulator: launches and renders, no crash.
- StoreKit restore/trial *runtime* flows must be confirmed in Xcode with the bundled
  `FitCheck.storekit` test config (simctl can't host the StoreKit test environment) — the
  outcome→message mapping is verified by code + compile-time exhaustive switches.
