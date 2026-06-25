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

    /// Result of a purchase attempt, so the view can react without inspecting StoreKit types.
    /// `needsAuth` = no signed-in Firebase account, so the buy was blocked before the
    /// Apple sheet (the view should prompt sign-in first).
    enum PurchaseOutcome { case success, pending, cancelled, failed, needsAuth }

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
            await loadProducts()
            await refreshEntitlement()
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
                await refreshRenewalInfo(for: transaction.productID)
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
        let plan = planDisplayName(for: transaction.productID)
        print("[StoreKit] ✅ premium unlocked locally plan=\(plan) source=apple expires=\(expirationDate.map { "\($0)" } ?? "n/a")")
    }

    // MARK: - Restore

    /// Apple's restore. `AppStore.sync()` refreshes signed transactions, then we
    /// re-derive entitlement. (StoreKit also auto-restores on a fresh install, so
    /// this is the explicit user-triggered path.)
    func restore() async {
        // A restore re-attaches the Apple entitlement to the *current* FitCheck
        // account, so it only makes sense once signed in. Without this a guest could
        // "restore" and the device entitlement still wouldn't unlock the gated UI.
        guard hasSignedInAccount else {
            lastError = "Please sign in to restore your subscription."
            print("[StoreKit] restore blocked — no signed-in Firebase account")
            return
        }
        isRestoring = true
        defer { isRestoring = false }
        AppLog.premium("restore tapped → AppStore.sync()")
        print("[StoreKit] restore started")
        do {
            try await AppStore.sync()
            // Re-derive entitlement from Apple — this updates the SAME @Published state
            // (hasPremium / activeProductID / expirationDate) the purchase path sets and
            // re-syncs Firebase, so a restore unlocks Premium exactly like a fresh buy.
            await refreshEntitlement()
            AppLog.premium(hasPremium
                ? "restore completed → premium active"
                : "restore completed → no entitlement found")
            print("[StoreKit] restore finished → hasPremium=\(hasPremium)")
            if !hasPremium { lastError = "No active subscription found to restore." }
        } catch StoreKitError.userCancelled {
            // The user dismissed the App Store sign-in sheet — not an error.
            print("[StoreKit] restore cancelled by user")
        } catch {
            lastError = "Couldn't restore purchases. Please try again."
            print("[StoreKit] restore error: \(error)")
        }
    }

    // Manage-subscription UI lives in PremiumStatusView via SwiftUI's
    // `.manageSubscriptionsSheet(isPresented:)`, which presents inside SwiftUI's own
    // hierarchy. The previous imperative `AppStore.showManageSubscriptions(in: scene)`
    // resolved a UIWindowScene and presented a UIKit modal on top of the view's
    // fullScreenCover host, which could crash ("already presenting") after a long
    // async fetch — so it was removed in favour of the SwiftUI-managed sheet.

    // MARK: - Entitlement

    /// Scan Apple's current entitlements and return the active premium transaction (and
    /// its signed JWS), if any. Pure read — does not mutate published state.
    private func currentActiveEntitlement() async -> (transaction: Transaction, jws: String)? {
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
        if let active, let activeJWS { return (active, activeJWS) }
        return nil
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
        if let (transaction, jws) = await currentActiveEntitlement() {
            applyEntitlementActive(transaction)
            await refreshRenewalInfo(for: transaction.productID)
            await syncToBackend(jws: jws, productID: transaction.productID, environment: transaction.environment)
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
    private func applyEntitlementActive(_ transaction: Transaction) {
        entitlementRecheckTask?.cancel()
        entitlementRecheckTask = nil
        isReconcilingEntitlement = false
        hasPremium = true
        activeProductID = transaction.productID
        expirationDate = transaction.expirationDate
        print("[StoreKit] ✅ apple entitlement ACTIVE product=\(transaction.productID) env=\(transaction.environment.rawValue) expires=\(expirationDate.map { "\($0)" } ?? "n/a")")
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
        if let (transaction, jws) = await currentActiveEntitlement() {
            print("[StoreKit] ✅ entitlement recheck → ACTIVE; premium retained product=\(transaction.productID)")
            applyEntitlementActive(transaction)
            await refreshRenewalInfo(for: transaction.productID)
            await syncToBackend(jws: jws, productID: transaction.productID, environment: transaction.environment)
        } else {
            print("[StoreKit] ⛔️ entitlement recheck → still INACTIVE; confirming downgrade")
            clearEntitlement(reason: "recheck still inactive")
        }
    }

    /// Best-effort auto-renew / trial flags from the subscription status.
    private func refreshRenewalInfo(for productID: String) async {
        var product = products.first(where: { $0.id == productID })
        if product == nil {
            product = try? await Product.products(for: [productID]).first
        }
        guard let subscription = product?.subscription,
              let statuses = try? await subscription.status,
              let status = statuses.first,
              let renewal = try? checkVerified(status.renewalInfo) else { return }
        willAutoRenew = renewal.willAutoRenew
        if let transaction = try? checkVerified(status.transaction) {
            isInTrialPeriod = transaction.offerType == .introductory
        }
    }

    // MARK: - Display helpers

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
