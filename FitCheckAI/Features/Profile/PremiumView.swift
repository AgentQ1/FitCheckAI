import SwiftUI
import StoreKit

/// FitCheck Premium paywall — shown only to non-subscribers. Purchasing happens
/// entirely inside the app through Apple's native StoreKit sheet (no web checkout).
/// Active subscribers are routed to `PremiumStatusView` before they ever reach here.
struct PremiumView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var storeKit: StoreKitService
    @Environment(\.dismiss) var dismiss

    @State private var selectedProductID: String?
    @State private var showToS = false
    @State private var showPrivacy = false
    @State private var showAuth = false
    @State private var infoMessage: String?
    /// Set when this user's Premium has lapsed, so the paywall shows an "access ended"
    /// line for context (an expired user reaches the paywall, not the status screen).
    @State private var expiredDate: Date?
    /// Restore result, shown as an ALERT (on top of the paywall) rather than an inline
    /// banner — an inline banner can sit below the fold / behind Apple's restore prompt,
    /// which is why the restore feedback wasn't being clearly seen.
    @State private var restoreAlertMessage: String?
    /// True when a guest's restore found an active entitlement, so the alert offers Sign In.
    @State private var restoreOffersSignIn = false

    // Lead with the headline benefits, then the rest of the unlock list. NOTE: "AI
    // outfit upgrades" is intentionally NOT listed — the upgrade carousel is free for
    // everyone, so promising it as a Premium perk would misrepresent what's gated.
    private let benefits: [(String, String)] = [
        ("infinity",           "Unlimited outfit checks"),
        ("chart.pie.fill",     "All 8 style lenses"),
        ("chart.line.uptrend.xyaxis", "Full style progress"),
        ("sparkles",           "Premium AI feedback"),
        ("photo.stack.fill",   "Unlimited saved wardrobe"),
    ]

    private var selectedProduct: Product? {
        if let id = selectedProductID, let p = storeKit.products.first(where: { $0.id == id }) { return p }
        return storeKit.yearlyProduct ?? storeKit.products.first
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.fcBackground.ignoresSafeArea()

                if !storeKit.hasResolvedEntitlement {
                    // Don't show the upgrade offer until Apple's entitlement has resolved —
                    // otherwise an active subscriber could glimpse the paywall during the
                    // cold-launch window before isPremium flips (and the router swaps to the
                    // status screen). Explicit loading state instead.
                    paywallLoadingState
                } else {
                ScrollView {
                    VStack(spacing: 26) {
                        header
                        if let expiredDate { expiredNotice(expiredDate) }
                        benefitsList
                        pricing
                        if let msg = infoMessage ?? storeKit.lastError {
                            messageBanner(msg)
                        }
                        cta
                        legalFooter
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.fcTextSecondary)
                            .font(.system(size: 22))
                    }
                }
            }
        }
        .task {
            AppLog.launch("paywall opened — products=\(storeKit.products.count) authed=\(appState.isAuthenticated) premium=\(appState.isPremium)")
            // Resolve Apple's live entitlement up front. At cold launch `isPremium` is
            // briefly false until StoreKit loads, so an existing subscriber could land on
            // this paywall; once the entitlement resolves, isPremium flips true and the
            // `onChange` below dismisses us (the router then shows the management screen).
            // This is what prevents an active subscriber from being offered Premium again.
            await storeKit.refreshEntitlement()
            if storeKit.products.isEmpty { await storeKit.loadProducts() }
            if selectedProductID == nil {
                selectedProductID = storeKit.yearlyProduct?.id ?? storeKit.products.first?.id
            }
            // Show "your access ended" context if this Apple ID once had Premium.
            expiredDate = await storeKit.recentlyExpiredDate()
            appState.analyticsService.track(.premiumUpgradeTapped)
        }
        // Apple confirmed the purchase (or restore) → entitlement flipped → leave.
        .onChange(of: appState.isPremium) { _, isPremium in
            if isPremium {
                appState.analyticsService.track(.subscriptionStarted,
                                                properties: ["product": selectedProductID ?? "?"])
                dismiss()
            }
        }
        .sheet(isPresented: $showToS) { NavigationStack { TermsOfServiceView() } }
        .sheet(isPresented: $showPrivacy) { NavigationStack { PrivacyPolicyView() } }
        .sheet(isPresented: $showAuth) {
            NavigationStack { AuthView().environmentObject(appState) }
        }
        // Restore result — presented ON TOP of the paywall for EVERY tap so it's always
        // visibly seen (never a banner hidden below the fold or behind Apple's prompt).
        .alert("Restore Purchases", isPresented: Binding(
            get: { restoreAlertMessage != nil },
            set: { if !$0 { restoreAlertMessage = nil } }
        )) {
            if restoreOffersSignIn {
                Button("Sign In") { showAuth = true }
                Button("Not Now", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: {
            Text(restoreAlertMessage ?? "")
        }
        // The guest signed in from the auth sheet — close it and surface a nudge so
        // they can tap "Start Premium" now that the buy can be attributed to them.
        .onChange(of: appState.isAuthenticated) { _, isAuthed in
            if isAuthed && showAuth {
                showAuth = false
                infoMessage = "You're signed in — tap Start Premium to continue."
            }
        }
    }

    // MARK: - Loading

    /// Shown while Apple's entitlement is still resolving, so the paywall offer never
    /// flashes for a user who actually already has Premium.
    private var paywallLoadingState: some View {
        VStack(spacing: 14) {
            ProgressView().tint(.fcAccent)
            Text("Checking your subscription…")
                .font(.fcBody)
                .foregroundColor(.fcTextSecondary)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            Text("✦")
                .font(.system(size: 40))
                .foregroundColor(.fcGold)
            Text("FitCheck Premium")
                .font(.fcDisplay)
                .foregroundColor(.fcTextPrimary)
            Text("Dress better, every day.")
                .font(.fcBody)
                .foregroundColor(.fcTextSecondary)
        }
        .padding(.top, 8)
    }

    // MARK: - Benefits

    private var benefitsList: some View {
        VStack(spacing: 8) {
            ForEach(benefits, id: \.1) { benefit in
                HStack(spacing: 12) {
                    Image(systemName: benefit.0)
                        .foregroundColor(.fcGold)
                        .font(.system(size: 16))
                        .frame(width: 24)
                    Text(benefit.1)
                        .font(.fcBody)
                        .foregroundColor(.fcTextPrimary)
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.fcGold)
                        .font(.system(size: 16))
                }
                .padding(14)
                .background(Color.fcSurface)
                .cornerRadius(12)
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Pricing

    @ViewBuilder
    private var pricing: some View {
        if storeKit.isLoadingProducts && storeKit.products.isEmpty {
            ProgressView().tint(.fcAccent).padding(.vertical, 24)
        } else if storeKit.products.isEmpty {
            VStack(spacing: 10) {
                Text("Subscription options couldn't load.")
                    .font(.fcBody)
                    .foregroundColor(.fcTextSecondary)
                Button("Try Again") { Task { await storeKit.loadProducts() } }
                    .font(.fcBodyBold)
                    .foregroundColor(.fcAccent)
            }
            .padding(.vertical, 16)
        } else {
            VStack(spacing: 10) {
                ForEach(storeKit.products) { product in
                    tierCard(product)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func tierCard(_ product: Product) -> some View {
        let isSelected = selectedProduct?.id == product.id
        let isYearly = product.id == Config.IAP.yearlyProductID
        return Button(action: { selectedProductID = product.id }) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(storeKit.planDisplayName(for: product.id))
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.fcTextPrimary)
                        if let badge = badge(for: product) {
                            Text(badge)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.fcBackground)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(isYearly ? Color.fcGold : Color.fcAccent)
                                .cornerRadius(6)
                        }
                    }
                    if let sub = subline(for: product) {
                        Text(sub)
                            .font(.fcCaption)
                            .foregroundColor(.fcTextSecondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(product.displayPrice)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(isSelected ? .fcAccent : .fcTextPrimary)
                    Text(periodSuffix(for: product))
                        .font(.system(size: 11))
                        .foregroundColor(.fcTextSecondary)
                }
            }
            .padding(16)
            .background(isSelected ? Color.fcAccent.opacity(0.1) : Color.fcSurface)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? Color.fcAccent : Color.clear, lineWidth: 1.5)
            )
            .cornerRadius(14)
        }
        .buttonStyle(HapticButtonStyle(style: .light))
    }

    // MARK: - CTA

    @ViewBuilder
    private var cta: some View {
        // Never present a purchase CTA without a real, loaded StoreKit product. When
        // products can't load, `pricing` shows "couldn't load" + Try Again and the
        // footer shows Restore Purchases — so there is never a dead/disabled
        // "Start Premium" button (Guideline 2.1 / a confusing paywall).
        if let product = selectedProduct {
            VStack(spacing: 10) {
                Button(action: startPurchase) {
                    Group {
                        if storeKit.isPurchasing {
                            HStack(spacing: 10) {
                                ProgressView().tint(.fcBackground)
                                Text("Starting…")
                                    .font(.system(size: 17, weight: .bold))
                                    .foregroundColor(.fcBackground)
                            }
                        } else {
                            Text(appState.isAuthenticated ? "Start Premium" : "Sign in to start Premium")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundColor(.fcBackground)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.fcAccent)
                    .cornerRadius(16)
                }
                .disabled(storeKit.isPurchasing)
                .buttonStyle(HapticButtonStyle())

                if let trial = trialLabel(for: product) {
                    Text(trial)
                        .font(.fcCaption)
                        .foregroundColor(.fcTextSecondary)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    // MARK: - Legal footer

    private var legalFooter: some View {
        VStack(spacing: 12) {
            Button(action: restorePurchases) {
                HStack(spacing: 6) {
                    if storeKit.isRestoring { ProgressView().tint(.fcTextSecondary).scaleEffect(0.8) }
                    Text(storeKit.isRestoring ? "Restoring…" : "Already subscribed? Restore Purchases")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.fcTextSecondary)
                }
            }
            .disabled(storeKit.isRestoring)

            Text(autoRenewDisclosure)
                .font(.system(size: 11))
                .foregroundColor(.fcTextSecondary.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            HStack(spacing: 6) {
                Button("Terms of Service") { showToS = true }
                Text("·").foregroundColor(.fcTextSecondary.opacity(0.5))
                Button("Privacy Policy") { showPrivacy = true }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.fcTextSecondary)
        }
        .padding(.top, 4)
    }

    /// "Your Premium access ended" context for a lapsed subscriber — shown above the
    /// benefits/pricing (which serve as the upgrade options).
    private func expiredNotice(_ date: Date) -> some View {
        VStack(spacing: 4) {
            Text("Your Premium access ended")
                .font(.fcBodyBold)
                .foregroundColor(.fcTextPrimary)
            Text(StoreKitService.displayDate(date).map { "Ended \($0) · Resubscribe to unlock everything again." }
                 ?? "Resubscribe to unlock everything again.")
                .font(.fcCaption)
                .foregroundColor(.fcTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(14)
        .background(Color.fcGold.opacity(0.12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.fcGold.opacity(0.35), lineWidth: 1))
        .cornerRadius(12)
        .padding(.horizontal, 20)
    }

    private func messageBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundColor(.fcWarning)
            Text(text)
                .font(.fcCaption)
                .foregroundColor(.fcTextPrimary)
                .multilineTextAlignment(.leading)
            Spacer()
            Button(action: { infoMessage = nil; storeKit.lastError = nil }) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.fcTextSecondary)
            }
        }
        .padding(12)
        .background(Color.fcWarning.opacity(0.15))
        .cornerRadius(12)
        .padding(.horizontal, 20)
    }

    // MARK: - Actions

    /// Restore Purchases — clear feedback for every outcome (Guideline 2.1 / 3.1.1).
    /// Duplicate taps are blocked by `storeKit.isRestoring` (button disabled) and the
    /// guard below. Never silently fails; never shows "success" without a verified
    /// active entitlement.
    @MainActor
    private func restorePurchases() {
        guard !storeKit.isRestoring else { return }
        infoMessage = nil
        restoreAlertMessage = nil
        restoreOffersSignIn = false
        storeKit.lastError = nil
        Task { @MainActor in
            let outcome = await storeKit.restore()
            let message: String
            switch outcome {
            case .alreadyActive:
                message = "Your Premium is already active."
            case .restored(let trial):
                // A signed-in account: recomputePremium flips isPremium → onChange dismisses.
                message = trial ? "Premium trial restored successfully." : "Premium restored successfully."
            case .restoredGuest:
                // Entitlement verified on the device's Apple ID, but no account to sync to.
                message = "Premium restored. Sign in to keep your subscription synced safely."
                restoreOffersSignIn = true
            case .notFound:
                message = "No active Premium subscription was found for this Apple ID."
            case .cancelled:
                message = "Restore cancelled."
            case .failed:
                message = "We couldn't restore purchases right now. Please try again."
            }
            // The sync paths showed Apple's prompt; let it fully dismiss before presenting
            // our alert so SwiftUI doesn't drop it. The fast "already active" path had no
            // prompt, so it stays instant.
            if outcome != .alreadyActive {
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
            restoreAlertMessage = message
            AppLog.premium("restore UI message shown: \(message)")
        }
    }

    private func startPurchase() {
        guard let product = selectedProduct else { return }
        // Premium is tied to the signed-in account — a guest must sign in before any
        // purchase, so the subscription can be attributed to a real FitCheck user.
        guard appState.isAuthenticated else {
            infoMessage = nil
            storeKit.lastError = nil
            showAuth = true
            return
        }
        // Block a second purchase off BOTH our gate and Apple's live entitlement. Checking
        // `storeKit.hasPremium` (not just `appState.isPremium`) closes the cold-launch
        // window where the account already owns a subscription but `isPremium` hasn't
        // resolved yet — so an active subscriber can never be charged twice.
        guard !appState.isPremium && !storeKit.hasPremium else {
            infoMessage = "Premium is already active on your account."
            // Re-resolve so isPremium flips → onChange dismisses → router shows status.
            Task { await storeKit.refreshEntitlement() }
            return
        }
        infoMessage = nil
        storeKit.lastError = nil
        Task {
            let outcome = await storeKit.purchase(product)
            switch outcome {
            case .success:   break               // onChange(isPremium) dismisses
            case .pending:   infoMessage = "Your purchase is pending approval. Premium unlocks once it's approved."
            case .needsAuth: showAuth = true     // signed out between tap and purchase
            case .cancelled: break
            case .failed:    break               // storeKit.lastError shows the reason
            }
        }
    }

    // MARK: - Formatting helpers

    private func periodSuffix(for product: Product) -> String {
        guard let unit = product.subscription?.subscriptionPeriod.unit else { return "" }
        switch unit {
        case .year:  return "per year"
        case .month: return "per month"
        case .week:  return "per week"
        case .day:   return "per day"
        @unknown default: return ""
        }
    }

    private func badge(for product: Product) -> String? {
        if product.id == Config.IAP.yearlyProductID {
            if let pct = yearlySavingsPercent() { return "Save \(pct)%" }
            return "Best value"
        }
        if product.id == Config.IAP.monthlyProductID { return "Most popular" }
        return nil
    }

    private func subline(for product: Product) -> String? {
        if product.id == Config.IAP.yearlyProductID,
           let perMonth = yearlyPerMonthDisplay() {
            return "Just \(perMonth) per month"
        }
        return nil
    }

    /// Yearly price ÷ 12, formatted in the product's currency.
    private func yearlyPerMonthDisplay() -> String? {
        guard let yearly = storeKit.yearlyProduct else { return nil }
        let perMonth = yearly.price / 12
        return perMonth.formatted(yearly.priceFormatStyle)
    }

    private func yearlySavingsPercent() -> Int? {
        guard let yearly = storeKit.yearlyProduct, let monthly = storeKit.monthlyProduct else { return nil }
        let yearlyPerMonth = yearly.price / 12
        guard monthly.price > 0 else { return nil }
        let pct = (monthly.price - yearlyPerMonth) / monthly.price * 100
        let value = Int(NSDecimalNumber(decimal: pct).doubleValue.rounded())
        return value > 0 ? value : nil
    }

    private func trialLabel(for product: Product) -> String? {
        guard let offer = product.subscription?.introductoryOffer, offer.paymentMode == .freeTrial else { return nil }
        let n = offer.period.value
        let unit: String
        switch offer.period.unit {
        case .day:   unit = n == 1 ? "day" : "days"
        case .week:  unit = n == 1 ? "week" : "weeks"
        case .month: unit = n == 1 ? "month" : "months"
        case .year:  unit = n == 1 ? "year" : "years"
        @unknown default: unit = "days"
        }
        return "Includes a \(n)-\(unit) free trial, then \(product.displayPrice) \(periodSuffix(for: product))."
    }

    private var autoRenewDisclosure: String {
        let period = selectedProduct.map { storeKit.renewalPeriodLabel(for: $0) } ?? "period"
        return "Subscription automatically renews every \(period) until cancelled. Cancel anytime in the App Store. Payment is charged to your Apple ID."
    }
}

#Preview {
    PremiumView()
        .environmentObject(AppState())
        .environmentObject(StoreKitService())
}
