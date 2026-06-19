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

    /// Result of a purchase attempt, so the view can react without inspecting StoreKit types.
    enum PurchaseOutcome { case success, pending, cancelled, failed }

    /// Invoked after the backend confirms the Firestore mirror write, so AppState can
    /// reload the AuthService user payload. Set by AppState.
    var onEntitlementSynced: (() async -> Void)?

    private var updatesTask: Task<Void, Never>?

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

    deinit { updatesTask?.cancel() }

    // MARK: - Products

    func loadProducts() async {
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        do {
            let loaded = try await Product.products(for: Config.IAP.productIDs)
            // Cheapest-per-month (yearly) first so the best value leads the paywall.
            products = loaded.sorted { $0.price > $1.price }
        } catch {
            lastError = "Couldn't load subscription options. Check your connection and try again."
            print("[StoreKit] loadProducts error: \(error)")
        }
    }

    var monthlyProduct: Product? { products.first { $0.id == Config.IAP.monthlyProductID } }
    var yearlyProduct: Product?  { products.first { $0.id == Config.IAP.yearlyProductID } }

    // MARK: - Purchase

    /// Native Apple purchase sheet → unlock. Never call when already premium.
    @discardableResult
    func purchase(_ product: Product) async -> PurchaseOutcome {
        guard !hasPremium else {
            lastError = "Premium is already active on your account."
            return .failed
        }
        isPurchasing = true
        defer { isPurchasing = false }
        print("[StoreKit] purchase started product=\(product.id)")
        do {
            var options: Set<Product.PurchaseOption> = []
            if let token = appAccountToken() { options.insert(.appAccountToken(token)) }

            let result = try await product.purchase(options: options)
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
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
        isRestoring = true
        defer { isRestoring = false }
        print("[StoreKit] restore started")
        do {
            try await AppStore.sync()
            // Re-derive entitlement from Apple — this updates the SAME @Published state
            // (hasPremium / activeProductID / expirationDate) the purchase path sets and
            // re-syncs Firebase, so a restore unlocks Premium exactly like a fresh buy.
            await refreshEntitlement()
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

    // MARK: - Manage subscription (Apple's native sheet)

    func showManageSubscriptions() async {
        guard let scene = activeWindowScene() else { return }
        do {
            try await AppStore.showManageSubscriptions(in: scene)
            await refreshEntitlement()
        } catch {
            print("[StoreKit] showManageSubscriptions error: \(error)")
        }
    }

    // MARK: - Entitlement

    /// Recompute Premium from Apple's current entitlements (the source of truth).
    func refreshEntitlement() async {
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

        if let transaction = active {
            hasPremium = true
            activeProductID = transaction.productID
            expirationDate = transaction.expirationDate
            print("[StoreKit] ✅ apple entitlement ACTIVE product=\(transaction.productID) env=\(transaction.environment.rawValue) expires=\(expirationDate.map { "\($0)" } ?? "n/a")")
            await refreshRenewalInfo(for: transaction.productID)
            if let jws = activeJWS {
                await syncToBackend(jws: jws, productID: transaction.productID, environment: transaction.environment)
            }
        } else {
            hasPremium = false
            activeProductID = nil
            expirationDate = nil
            willAutoRenew = true
            isInTrialPeriod = false
            print("[StoreKit] ⛔️ apple entitlement INACTIVE → no active premium")
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
        print("[StoreKit] Transaction.updates fired product=\(transaction.productID) revoked=\(transaction.revocationDate != nil)")
        await transaction.finish()
        // Re-derive entitlement from Apple's current state (handles renew + revoke) and
        // re-sync Firebase. refreshEntitlement only syncs an ACTIVE entitlement, so a
        // revocation still gets reported here so the backend can clear Premium.
        await refreshEntitlement()
        if !hasPremium {
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

    private func activeWindowScene() -> UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }
}
