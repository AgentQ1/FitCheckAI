import Foundation
import StoreKit
import FirebaseAuth

/// StoreKit 2 entitlement engine — the source of truth for Premium.
///
/// Apple is authoritative: `Transaction.currentEntitlements` decides whether the
/// user has Premium, `Transaction.updates` keeps it live (renew / cancel / refund /
/// Ask-to-Buy), and the native purchase sheet keeps the buy flow inside the app.
/// After any entitlement change we mirror the signed transaction to our backend so
/// Firestore (which the server-side rate limits read) stays in sync.
@MainActor
final class StoreKitService: ObservableObject {

    // MARK: - Published state (drives the UI)
    @Published private(set) var products: [Product] = []
    @Published private(set) var hasPremium = false
    @Published private(set) var activeProductID: String?
    @Published private(set) var expirationDate: Date?
    @Published private(set) var willAutoRenew = true
    @Published private(set) var isInTrialPeriod = false
    @Published private(set) var isLoadingProducts = false
    @Published private(set) var isPurchasing = false
    @Published private(set) var isRestoring = false
    @Published var lastError: String?

    /// True while we are debouncing a possibly-transient "no active entitlement" read
    /// (see `refreshEntitlement`). During this window Premium is being re-checked, so
    /// AppState may keep the UI unlocked off the Firestore mirror to avoid a flicker.
    @Published private(set) var isReconcilingEntitlement = false

    /// False until the FIRST entitlement resolution at launch completes. The paywall
    /// shows a loading state (not the upgrade offer) until this flips, so an active
    /// subscriber is never momentarily shown the paywall during the cold-launch window
    /// before Apple's entitlement has resolved.
    @Published private(set) var hasResolvedEntitlement = false

    /// Result of a purchase attempt, so the view can react without inspecting StoreKit types.
    /// `needsAuth` = no signed-in Firebase account, so the buy was blocked before the
    /// Apple sheet (the view should prompt sign-in first).
    enum PurchaseOutcome { case success, pending, cancelled, failed, needsAuth }

    /// Result of a restore attempt, so every surface can show clear, specific feedback
    /// for EVERY tap (Guideline 2.1 / 3.1.1 — a restore must never be silent).
    /// `alreadyActive` = Premium was already active before this restore (a re-tap, or a
    /// premium user tapping Restore on the status screen). `restored` = an active
    /// entitlement was (re)applied on a signed-in account; `trial` distinguishes a
    /// free-trial restore so the message can say "trial". `restoredGuest` = an active
    /// entitlement was verified, but the session is a guest, so they're prompted to sign
    /// in to sync it. `notFound` = no active subscription on this Apple ID. `cancelled` =
    /// user dismissed the App Store prompt. `failed` = network / App Store error.
    enum RestoreOutcome: Equatable {
        case alreadyActive
        case restored(trial: Bool)
        case restoredGuest
        case notFound
        case cancelled
        case failed
    }

    /// A single, user-facing description of the ACTIVE Premium entitlement, so the
    /// Profile card and the status screen can never disagree (the bug where one said
    /// "Premium — Active" while the other said "Free Trial"). Only describes states where
    /// Apple reports an active entitlement; a lapsed subscription is surfaced separately
    /// on the paywall via `recentlyExpiredDate()`.
    enum PremiumPhase: Equatable {
        case none                       // not entitled (free, or fully lapsed)
        case trial(ends: Date?)         // active introductory free trial
        case active(renews: Date?)      // active, auto-renewing paid subscription
        case cancelling(until: Date?)   // active paid, but auto-renew is off
    }

    /// The display phase derived from Apple's live entitlement state (source of truth).
    /// A free trial is reported as `.trial`, never as a separate-looking "Free Trial"
    /// plan — it IS Premium, just in its trial window.
    var premiumPhase: PremiumPhase {
        guard hasPremium else { return .none }
        if isInTrialPeriod { return .trial(ends: expirationDate) }
        return willAutoRenew ? .active(renews: expirationDate) : .cancelling(until: expirationDate)
    }

    /// A real, signed-in Firebase account (not anonymous). Premium is tied to the
    /// signed-in account, so both purchase and restore require one — the StoreKit
    /// entitlement alone (scoped to the device Apple ID) must not unlock a guest.
    private var hasSignedInAccount: Bool {
        guard let user = Auth.auth().currentUser else { return false }
        return !user.isAnonymous
    }

    /// Invoked after the backend confirms the Firestore mirror write, so AppState can
    /// reload the AuthService user payload. Set by AppState.
    var onEntitlementSynced: (() async -> Void)?

    private var updatesTask: Task<Void, Never>?
    /// Pending debounced re-check of the entitlement after a transient "inactive" read.
    private var entitlementRecheckTask: Task<Void, Never>?
    /// How long to wait before trusting an "inactive" read enough to downgrade. Apple's
    /// `Transaction.currentEntitlements` can momentarily return empty right after an
    /// `AppStore.sync()` / `Transaction.updates` event; this window lets it settle.
    private let entitlementRecheckDelay: UInt64 = 2_500_000_000 // 2.5s

    // MARK: - Lifecycle

    /// Begin listening for transaction updates and load the current entitlement.
    /// Safe to call once at app launch.
    func start() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.handle(verification: update)
            }
        }
        Task {
            // Resolve the entitlement at launch (needed to know Premium state), but DON'T
            // load products here — that StoreKit network call is deferred until the paywall
            // is actually opened (PremiumView.task loads them lazily). Keeps the launch path
            // off an unnecessary App Store round-trip.
            await refreshEntitlement()
            hasResolvedEntitlement = true
        }
    }

    deinit {
        updatesTask?.cancel()
        entitlementRecheckTask?.cancel()
    }

    // MARK: - Products

    func loadProducts() async {
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        do {
            let loaded = try await Product.products(for: Config.IAP.productIDs)
            // Cheapest-per-month (yearly) first so the best value leads the paywall.
            products = loaded.sorted { $0.price > $1.price }
            // App Review breadcrumb (os_log): confirms StoreKit returned the products
            // and exactly which IDs, so a reviewer's device log shows the IAPs loaded.
            AppLog.premium("StoreKit products loaded: \(products.count)/\(Config.IAP.productIDs.count) ids=[\(products.map(\.id).joined(separator: ", "))]")
            AppLog.launch("StoreKit products loaded: \(products.count)/\(Config.IAP.productIDs.count) [\(products.map(\.id).joined(separator: ", "))]")
            if products.isEmpty {
                // Not a crash — the paywall renders Retry + Restore — but worth a
                // breadcrumb: in production this means the IAPs aren't approved /
                // attached to the app version yet in App Store Connect.
                AppLog.launch("⚠️ StoreKit returned 0 products — IAPs not available in this environment")
            }
        } catch {
            lastError = "Couldn't load subscription options. Check your connection and try again."
            AppLog.launch("⚠️ StoreKit loadProducts failed: \(error.localizedDescription)")
            print("[StoreKit] loadProducts error: \(error)")
        }
    }

    var monthlyProduct: Product? { products.first { $0.id == Config.IAP.monthlyProductID } }
    var yearlyProduct: Product?  { products.first { $0.id == Config.IAP.yearlyProductID } }

    // MARK: - Purchase

    /// Native Apple purchase sheet → unlock. Never call when already premium.
    @discardableResult
    func purchase(_ product: Product) async -> PurchaseOutcome {
        // Premium is tied to the signed-in Firebase account. Block the buy before the
        // Apple sheet if there's no real account — otherwise a guest could pay and the
        // purchase couldn't be attributed to any FitCheck user.
        guard hasSignedInAccount else {
            print("[StoreKit] purchase blocked — no signed-in Firebase account; sign-in required first")
            return .needsAuth
        }
        guard !hasPremium else {
            lastError = "Premium is already active on your account."
            return .failed
        }
        isPurchasing = true
        defer { isPurchasing = false }
        AppLog.premium("purchase tapped → product=\(product.id)")
        print("[StoreKit] purchase started product=\(product.id)")
        do {
            var options: Set<Product.PurchaseOption> = []
            if let token = appAccountToken() { options.insert(.appAccountToken(token)) }

            let result = try await product.purchase(options: options)
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                AppLog.premium("purchase verified → product=\(transaction.productID) premium unlocked")
                print("[StoreKit] ✅ transaction verified product=\(transaction.productID) id=\(transaction.id)")
                // 1) Finish immediately so StoreKit stops re-delivering the transaction.
                await transaction.finish()
                // 2) Flip Premium ON instantly from the verified transaction itself.
                //    We do NOT wait on a Transaction.currentEntitlements re-query here —
                //    that async sequence can race right after a purchase and miss the new
                //    transaction, which would leave the UI stuck on "Upgrade to Premium".
                applyActiveTransaction(transaction)
                // 3) Mirror to Firebase (server-side rate limits read isPremium) and
                //    pull the auto-renew / trial flags. Both are best-effort: the local
                //    entitlement above already unlocked the app.
                await syncToBackend(jws: verification.jwsRepresentation,
                                    productID: transaction.productID,
                                    environment: transaction.environment)
                // Refine the auto-renew / trial flags from the subscription status (a fresh
                // purchase is renewing, so this confirms rather than flips — no UI bounce).
                let renewal = await renewalState(for: transaction)
                willAutoRenew = renewal.willAutoRenew
                isInTrialPeriod = renewal.isTrial
                return .success
            case .pending:
                // Deferred (e.g. Ask to Buy) — entitlement will arrive via Transaction.updates.
                print("[StoreKit] purchase pending (deferred / Ask to Buy)")
                return .pending
            case .userCancelled:
                print("[StoreKit] purchase cancelled by user")
                return .cancelled
            @unknown default:
                print("[StoreKit] purchase returned unknown result")
                return .failed
            }
        } catch {
            lastError = "Purchase couldn't be completed. Please try again."
            print("[StoreKit] ❌ purchase error: \(error)")
            return .failed
        }
    }

    /// Flip local Premium state from a verified, active transaction. Synchronous and on
    /// the main actor, so the `@Published` change propagates to AppState (→ ProfileView)
    /// immediately — no app restart, no entitlement re-query needed.
    private func applyActiveTransaction(_ transaction: Transaction) {
        // A confirmed-active transaction supersedes any in-flight "inactive" recheck.
        entitlementRecheckTask?.cancel()
        entitlementRecheckTask = nil
        isReconcilingEntitlement = false
        hasPremium = true
        activeProductID = transaction.productID
        expirationDate = transaction.expirationDate
        // Trial state direct from the transaction's offer type, so a free-trial purchase
        // reads as a trial immediately (don't wait on the async renewal-info fetch). A
        // brand-new purchase always auto-renews, so seed willAutoRenew=true → the card
        // reads "Renews", never a spurious "Access until", before the refine step confirms.
        isInTrialPeriod = transaction.offerType == .introductory
        willAutoRenew = true
        let plan = planDisplayName(for: transaction.productID)
        print("[StoreKit] ✅ premium unlocked locally plan=\(plan) source=apple trial=\(isInTrialPeriod) expires=\(expirationDate.map { "\($0)" } ?? "n/a")")
    }

    // MARK: - Restore

    /// Apple's restore — the explicit, user-triggered path. `AppStore.sync()` refreshes
    /// signed transactions from Apple, then we re-derive the entitlement from
    /// `Transaction.currentEntitlements` (StoreKit verification) and update Premium.
    ///
    /// Restore works for GUESTS too: we never require sign-in just to CHECK the Apple
    /// entitlement (Guideline 2.1 — a reviewer in guest mode must get a clear result).
    /// If a guest's Apple ID owns an active subscription, the entitlement is detected and
    /// the caller asks them to sign in to sync it to their account. Returns a specific
    /// `RestoreOutcome` so the paywall can show the right message; never throws, never
    /// downgrades off a missing Firestore mirror.
    @discardableResult
    func restore() async -> RestoreOutcome {
        // Fast path: an already-active, signed-in account has NOTHING to restore. Return
        // immediately WITHOUT calling AppStore.sync() — that avoids Apple's sync/sign-in
        // prompt entirely, so its dismissal can't swallow the "already active" alert (the
        // bug where tapping Restore just left the unchanged status screen). The slow path
        // below still fully handles guests and not-yet-active accounts.
        if hasPremium && hasSignedInAccount {
            AppLog.premium("restore → already active (fast path; skipped AppStore.sync)")
            print("[StoreKit] restore fast-path → already active (signed-in account, no sync)")
            return .alreadyActive
        }
        isRestoring = true
        defer { isRestoring = false }
        lastError = nil
        // Capture the pre-restore state so we can tell "already active" (a re-tap / a
        // premium user on the status screen) apart from a genuine restore.
        let wasPremiumBefore = hasPremium
        AppLog.premium("restore tapped (guest=\(!hasSignedInAccount), wasActive=\(wasPremiumBefore))")
        AppLog.premium("restore sync started → AppStore.sync()")
        print("[StoreKit] restore started signedInAccount=\(hasSignedInAccount) wasActive=\(wasPremiumBefore)")
        do {
            // Refresh signed transactions from the App Store (may prompt for Apple ID —
            // expected for an explicit restore; we never call this automatically at launch).
            try await AppStore.sync()
            AppLog.premium("restore sync completed → re-deriving entitlement")
            // Authoritative re-derive from Apple. `allowDebounce: false` because this is a
            // deliberate user action — we want the real current state now, not a held value.
            await refreshEntitlement(allowDebounce: false)
            if hasPremium {
                let trial = isInTrialPeriod
                let plan = planDisplayName(for: activeProductID)
                let state = trial ? "trial" : (willAutoRenew ? "active" : "cancelling")
                AppLog.premium("restore → entitlement found plan=\(plan) state=\(state)")
                if !hasSignedInAccount {
                    AppLog.premium("restore → guest session → prompt sign-in to sync")
                    print("[StoreKit] restore finished → hasPremium=true (guest, needs sign-in to sync)")
                    return .restoredGuest
                }
                if wasPremiumBefore {
                    AppLog.premium("restore → premium already active")
                    print("[StoreKit] restore finished → already active (account)")
                    return .alreadyActive
                }
                AppLog.premium("restore → premium restored (trial=\(trial))")
                print("[StoreKit] restore finished → restored hasPremium=true (account)")
                return .restored(trial: trial)
            } else {
                AppLog.premium("restore → no active entitlement on this Apple ID")
                print("[StoreKit] restore finished → hasPremium=false")
                return .notFound
            }
        } catch StoreKitError.userCancelled {
            AppLog.premium("restore sync cancelled by user")
            print("[StoreKit] restore cancelled by user")
            return .cancelled
        } catch {
            AppLog.premium("restore failed: \(error.localizedDescription)")
            print("[StoreKit] restore error: \(error)")
            return .failed
        }
    }

    /// The most recent expiration date for a premium product whose entitlement is no
    /// longer active — i.e. the user *was* Premium and it lapsed. Returns nil if they
    /// were never Premium or are currently Premium. The paywall uses this to show an
    /// "access ended" line so an expired user gets clear context instead of a bare
    /// upgrade screen. Pure read; mutates nothing.
    func recentlyExpiredDate() async -> Date? {
        guard !hasPremium else { return nil }
        var latest: Date?
        for await result in Transaction.all {
            guard let t = try? checkVerified(result),
                  Config.IAP.isPremiumProduct(t.productID),
                  let exp = t.expirationDate else { continue }
            if latest == nil || exp > latest! { latest = exp }
        }
        if let latest, latest <= Date() {
            AppLog.premium("paywall expired-context → last premium access ended \(Self.displayDate(latest) ?? "?")")
            return latest
        }
        return nil
    }

    // Manage-subscription UI lives in PremiumStatusView via SwiftUI's
    // `.manageSubscriptionsSheet(isPresented:)`, which presents inside SwiftUI's own
    // hierarchy. The previous imperative `AppStore.showManageSubscriptions(in: scene)`
    // resolved a UIWindowScene and presented a UIKit modal on top of the view's
    // fullScreenCover host, which could crash ("already presenting") after a long
    // async fetch — so it was removed in favour of the SwiftUI-managed sheet.

    // MARK: - Entitlement

    /// A fully-resolved snapshot of the active entitlement, gathered BEFORE we publish
    /// anything. Bundling the renewal flags (auto-renew / trial) with the transaction lets
    /// us flip every `@Published` property in a single batch, so the derived `premiumPhase`
    /// can't bounce `.active` → `.cancelling` (or show a momentarily-missing date) while a
    /// second async pass catches up. That two-step apply was the "sometimes cancel,
    /// sometimes missing" wording flicker.
    private struct ActiveEntitlement {
        let transaction: Transaction
        let jws: String
        let willAutoRenew: Bool
        let isTrial: Bool
    }

    /// Scan Apple's current entitlements and return the active premium entitlement —
    /// transaction, signed JWS, and its resolved renewal flags — if any. Pure read.
    private func currentActiveEntitlement() async -> ActiveEntitlement? {
        var active: Transaction?
        var activeJWS: String?
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? checkVerified(result) else { continue }
            guard Config.IAP.isPremiumProduct(transaction.productID),
                  transaction.revocationDate == nil else { continue }
            if let exp = transaction.expirationDate, exp <= Date() { continue }
            // Prefer the entitlement that expires latest (handles plan upgrades).
            if active == nil || (transaction.expirationDate ?? .distantFuture) > (active?.expirationDate ?? .distantFuture) {
                active = transaction
                activeJWS = result.jwsRepresentation
            }
        }
        guard let active, let activeJWS else { return nil }
        // Resolve the renewal flags NOW, so they land atomically with the entitlement.
        let renewal = await renewalState(for: active)
        return ActiveEntitlement(transaction: active, jws: activeJWS,
                                 willAutoRenew: renewal.willAutoRenew, isTrial: renewal.isTrial)
    }

    /// Resolve `(willAutoRenew, isTrial)` from the product's subscription status. Defaults
    /// to **renewing, non-trial** when the status can't be read, so the UI never spuriously
    /// shows a "cancelling / access until" state off a transient/failed status fetch.
    private func renewalState(for transaction: Transaction) async -> (willAutoRenew: Bool, isTrial: Bool) {
        var isTrial = transaction.offerType == .introductory
        var willAutoRenew = true
        var product = products.first(where: { $0.id == transaction.productID })
        if product == nil { product = try? await Product.products(for: [transaction.productID]).first }
        if let subscription = product?.subscription,
           let statuses = try? await subscription.status,
           let status = statuses.first,
           let renewal = try? checkVerified(status.renewalInfo) {
            willAutoRenew = renewal.willAutoRenew
            if let t = try? checkVerified(status.transaction) { isTrial = t.offerType == .introductory }
        }
        return (willAutoRenew, isTrial)
    }

    /// Recompute Premium from Apple's current entitlements (the source of truth).
    ///
    /// `allowDebounce` (default true) guards the downgrade path: `currentEntitlements`
    /// can momentarily read empty right after an `AppStore.sync()` or a non-revoked
    /// `Transaction.updates` event, which previously flickered a just-restored user back
    /// to Free. When we currently hold Premium and the read comes back empty, we keep
    /// Premium and re-scan once after a short delay, only downgrading if it is STILL
    /// inactive. Pass `allowDebounce: false` for an explicit revocation, where the
    /// downgrade is authoritative and must apply immediately.
    func refreshEntitlement(allowDebounce: Bool = true) async {
        if let entitlement = await currentActiveEntitlement() {
            applyEntitlementActive(entitlement)
            await syncToBackend(jws: entitlement.jws,
                                productID: entitlement.transaction.productID,
                                environment: entitlement.transaction.environment)
            return
        }

        // No active entitlement found.
        if hasPremium && allowDebounce {
            // Possibly transient. Hold Premium and confirm with a debounced recheck
            // instead of flickering the user back to Free.
            print("[StoreKit] ⚠️ apple entitlement INACTIVE (first pass) — premium currently active; holding and scheduling \(Double(entitlementRecheckDelay) / 1e9)s recheck")
            scheduleEntitlementRecheck()
            return
        }

        clearEntitlement(reason: allowDebounce ? "no active premium" : "explicit revocation")
    }

    /// Apply a confirmed-active entitlement and cancel any pending downgrade recheck.
    /// Every Premium-relevant property is set in ONE synchronous batch (the renewal flags
    /// were resolved before this call), so `premiumPhase` snaps straight to its final value
    /// — no `.active`↔`.cancelling` flip, no momentarily-missing expiry date.
    private func applyEntitlementActive(_ entitlement: ActiveEntitlement) {
        entitlementRecheckTask?.cancel()
        entitlementRecheckTask = nil
        isReconcilingEntitlement = false
        hasPremium = true
        activeProductID = entitlement.transaction.productID
        expirationDate = entitlement.transaction.expirationDate
        isInTrialPeriod = entitlement.isTrial
        willAutoRenew = entitlement.willAutoRenew
        print("[StoreKit] ✅ apple entitlement ACTIVE product=\(entitlement.transaction.productID) env=\(entitlement.transaction.environment.rawValue) trial=\(isInTrialPeriod) autoRenew=\(willAutoRenew) expires=\(expirationDate.map { "\($0)" } ?? "n/a")")
    }

    /// Clear all Premium state. Called once a downgrade is confirmed (or there was never
    /// an entitlement to begin with).
    private func clearEntitlement(reason: String) {
        entitlementRecheckTask?.cancel()
        entitlementRecheckTask = nil
        isReconcilingEntitlement = false
        hasPremium = false
        activeProductID = nil
        expirationDate = nil
        willAutoRenew = true
        isInTrialPeriod = false
        print("[StoreKit] ⛔️ apple entitlement INACTIVE (\(reason)) → no active premium")
    }

    /// Wait out the StoreKit settle window, then re-scan. If the entitlement is back, we
    /// keep Premium; if it is still gone, the downgrade is now confirmed.
    private func scheduleEntitlementRecheck() {
        entitlementRecheckTask?.cancel()
        isReconcilingEntitlement = true
        entitlementRecheckTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.entitlementRecheckDelay)
            if Task.isCancelled { return }
            await self.finishEntitlementRecheck()
        }
    }

    private func finishEntitlementRecheck() async {
        entitlementRecheckTask = nil
        if let entitlement = await currentActiveEntitlement() {
            print("[StoreKit] ✅ entitlement recheck → ACTIVE; premium retained product=\(entitlement.transaction.productID)")
            applyEntitlementActive(entitlement)
            await syncToBackend(jws: entitlement.jws,
                                productID: entitlement.transaction.productID,
                                environment: entitlement.transaction.environment)
        } else {
            print("[StoreKit] ⛔️ entitlement recheck → still INACTIVE; confirming downgrade")
            clearEntitlement(reason: "recheck still inactive")
        }
    }

    // MARK: - Display helpers

    /// Shared medium-style formatter for subscription dates, e.g. "Jun 27, 2026".
    private static let displayDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    /// "Jun 27, 2026" for a subscription date, or nil when there is no date. Used by
    /// every Premium surface so trial/renew/expiry dates format identically.
    static func displayDate(_ date: Date?) -> String? {
        guard let date else { return nil }
        return displayDateFormatter.string(from: date)
    }

    /// Compact month-day, e.g. "Jul 25" (locale-aware). Used for the Profile card
    /// subtitle ("Access until Jul 25") where the year would be noise; the detail
    /// screen still uses the full `displayDate` ("Jul 25, 2026").
    private static let shortDisplayDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()

    /// "Jul 25" for a subscription date, or nil when there is no date.
    static func displayDateShort(_ date: Date?) -> String? {
        guard let date else { return nil }
        return shortDisplayDateFormatter.string(from: date)
    }

    func planDisplayName(for productID: String?) -> String {
        switch productID {
        case Config.IAP.monthlyProductID: return "Monthly"
        case Config.IAP.yearlyProductID:  return "Yearly"
        default: return "Premium"
        }
    }

    /// Apple's localized auto-renew disclosure period, e.g. "month" / "year".
    func renewalPeriodLabel(for product: Product) -> String {
        guard let unit = product.subscription?.subscriptionPeriod.unit else { return "period" }
        switch unit {
        case .day:   return "day"
        case .week:  return "week"
        case .month: return "month"
        case .year:  return "year"
        @unknown default: return "period"
        }
    }

    // MARK: - Backend mirror

    /// Out-of-band transaction updates (renewals, cancels, refunds, deferred buys).
    private func handle(verification: VerificationResult<Transaction>) async {
        guard let transaction = try? checkVerified(verification) else { return }
        let revoked = transaction.revocationDate != nil
        print("[StoreKit] Transaction.updates fired product=\(transaction.productID) revoked=\(revoked)")
        await transaction.finish()
        // Re-derive entitlement from Apple's current state. A revocation (refund /
        // family-sharing removal) is authoritative → downgrade immediately. A non-revoked
        // update is a renewal or just StoreKit re-delivering a restored transaction; its
        // `currentEntitlements` read can momentarily be empty, so let the debounce protect
        // a currently-premium user instead of flickering them back to Free.
        await refreshEntitlement(allowDebounce: !revoked)
        // Only report a *confirmed* loss of Premium to the backend. While a debounced
        // recheck is in flight (isReconcilingEntitlement) we still believe the user is
        // premium, so we must not tell the backend to clear it.
        if !hasPremium && !isReconcilingEntitlement {
            await syncToBackend(jws: verification.jwsRepresentation,
                                productID: transaction.productID,
                                environment: transaction.environment)
        }
    }

    /// POST the signed transaction (JWS) to our verifier so Firestore mirrors Apple.
    /// Best-effort from the UI's perspective — the local entitlement already gates the
    /// app — but on success we trigger an AuthService user refresh so the persisted
    /// `isPremium` flows back into AppState.
    ///
    /// `environment` lets us short-circuit local Xcode StoreKit-config transactions:
    /// those are signed by Xcode's local test certificate, which Apple's server-side
    /// `SignedDataVerifier` cannot validate, so the backend would always return
    /// 400 invalid_transaction. Sandbox/TestFlight/App Store transactions are real and
    /// flow through to the verifier unchanged.
    private func syncToBackend(jws: String, productID: String?, environment: AppStore.Environment) async {
        #if DEBUG
        // Xcode environment only ever occurs when running against a local .storekit
        // configuration file (simulator / debug device) — never in TestFlight or the
        // App Store. Skip the backend round-trip and explain why, so local testing
        // doesn't look broken. Premium is already unlocked locally via the entitlement.
        // This whole branch is compiled out of Release, so production never skips
        // verification.
        if environment == .xcode {
            print("[StoreKit] ⏭️ Firebase verify SKIPPED — Xcode-local StoreKit transaction (Apple's server library can't verify local test receipts). Premium remains unlocked locally via the StoreKit entitlement. final isPremium source=apple(local-xcode)")
            return
        }
        #endif
        guard let user = Auth.auth().currentUser else {
            print("[StoreKit] syncToBackend skipped — no signed-in Firebase user")
            return
        }
        // A guest (anonymous) has no real account to mirror entitlement onto. We detect
        // the Apple entitlement locally for them, but only sync once they sign in (the
        // sign-in flow re-derives the entitlement on the permanent account).
        if user.isAnonymous {
            print("[StoreKit] syncToBackend skipped — guest (anonymous) session; will sync after sign-in")
            return
        }
        print("[StoreKit] → Firebase verify START product=\(productID ?? "?") env=\(environment.rawValue)")
        do {
            let token = try await user.getIDToken()
            var req = URLRequest(url: URL(string: Config.API.syncAppleSubscription)!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.timeoutInterval = 20
            req.httpBody = try JSONSerialization.data(withJSONObject: ["signedTransaction": jws])
            let (data, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            if (200..<300).contains(code) {
                print("[StoreKit] ✅ Firebase verify SUCCESS product=\(productID ?? "?") status=\(code)")
                await onEntitlementSynced?()
            } else {
                let body = String(data: data, encoding: .utf8) ?? ""
                print("[StoreKit] ⚠️ Firebase verify FAILED status=\(code) body=\(body) — local Apple entitlement still gates Premium; the App Store Server Notification will reconcile Firestore server-side")
            }
        } catch {
            // Non-fatal: the App Store Server Notification will reconcile server-side.
            print("[StoreKit] ⚠️ Firebase verify ERROR: \(error) — local Apple entitlement still gates Premium")
        }
    }

    // MARK: - Private helpers

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error): throw error
        case .verified(let safe):       return safe
        }
    }

    /// Stable per-account UUID so the App Store Server Notification can correlate a
    /// transaction back to this Firebase user. Persisted per uid in UserDefaults.
    private func appAccountToken() -> UUID? {
        guard let uid = Auth.auth().currentUser?.uid else { return nil }
        let key = "appAccountToken.\(uid)"
        if let saved = UserDefaults.standard.string(forKey: key), let uuid = UUID(uuidString: saved) {
            return uuid
        }
        let uuid = UUID()
        UserDefaults.standard.set(uuid.uuidString, forKey: key)
        return uuid
    }

}
