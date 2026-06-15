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
        do {
            var options: Set<Product.PurchaseOption> = []
            if let token = appAccountToken() { options.insert(.appAccountToken(token)) }

            let result = try await product.purchase(options: options)
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await applyAndSync(transaction: transaction, jws: verification.jwsRepresentation)
                await transaction.finish()
                return .success
            case .pending:
                // Deferred (e.g. Ask to Buy) — entitlement will arrive via Transaction.updates.
                return .pending
            case .userCancelled:
                return .cancelled
            @unknown default:
                return .failed
            }
        } catch {
            lastError = "Purchase couldn't be completed. Please try again."
            print("[StoreKit] purchase error: \(error)")
            return .failed
        }
    }

    // MARK: - Restore

    /// Apple's restore. `AppStore.sync()` refreshes signed transactions, then we
    /// re-derive entitlement. (StoreKit also auto-restores on a fresh install, so
    /// this is the explicit user-triggered path.)
    func restore() async {
        isRestoring = true
        defer { isRestoring = false }
        do {
            try await AppStore.sync()
            await refreshEntitlement()
            if !hasPremium { lastError = "No active subscription found to restore." }
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
            await refreshRenewalInfo(for: transaction.productID)
            if let jws = activeJWS { await syncToBackend(jws: jws) }
        } else {
            hasPremium = false
            activeProductID = nil
            expirationDate = nil
            willAutoRenew = true
            isInTrialPeriod = false
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

    private func handle(verification: VerificationResult<Transaction>) async {
        guard let transaction = try? checkVerified(verification) else { return }
        await applyAndSync(transaction: transaction, jws: verification.jwsRepresentation)
        await transaction.finish()
    }

    private func applyAndSync(transaction: Transaction, jws: String) async {
        await refreshEntitlement()
        // refreshEntitlement already syncs the active entitlement; but a revocation
        // (no active entitlement) still needs to be reported so Firestore clears.
        if !hasPremium { await syncToBackend(jws: jws) }
    }

    /// POST the signed transaction (JWS) to our verifier so Firestore mirrors Apple.
    /// Fire-and-forget from the UI's perspective — local entitlement already gates the app.
    private func syncToBackend(jws: String) async {
        guard let user = Auth.auth().currentUser else { return }
        do {
            let token = try await user.getIDToken()
            var req = URLRequest(url: URL(string: Config.API.syncAppleSubscription)!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.timeoutInterval = 20
            req.httpBody = try JSONSerialization.data(withJSONObject: ["signedTransaction": jws])
            _ = try await URLSession.shared.data(for: req)
        } catch {
            // Non-fatal: the App Store Server Notification will reconcile server-side.
            print("[StoreKit] syncToBackend error: \(error)")
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
