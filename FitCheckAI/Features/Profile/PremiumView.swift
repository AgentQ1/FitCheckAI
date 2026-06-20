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

    // Lead with the four headline benefits, then the rest of the unlock list.
    private let benefits: [(String, String)] = [
        ("infinity",           "Unlimited outfit checks"),
        ("chart.pie.fill",     "All 8 style lenses"),
        ("chart.line.uptrend.xyaxis", "Full style progress"),
        ("sparkles",           "Premium AI feedback"),
        ("wand.and.stars",     "AI outfit upgrades"),
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

                ScrollView {
                    VStack(spacing: 26) {
                        header
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
            if storeKit.products.isEmpty { await storeKit.loadProducts() }
            if selectedProductID == nil {
                selectedProductID = storeKit.yearlyProduct?.id ?? storeKit.products.first?.id
            }
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
        // The guest signed in from the auth sheet — close it and surface a nudge so
        // they can tap "Start Premium" now that the buy can be attributed to them.
        .onChange(of: appState.isAuthenticated) { _, isAuthed in
            if isAuthed && showAuth {
                showAuth = false
                infoMessage = "You're signed in — tap Start Premium to continue."
            }
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

    private var cta: some View {
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
            .disabled(storeKit.isPurchasing || selectedProduct == nil)
            .buttonStyle(HapticButtonStyle())

            if let product = selectedProduct, let trial = trialLabel(for: product) {
                Text(trial)
                    .font(.fcCaption)
                    .foregroundColor(.fcTextSecondary)
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Legal footer

    private var legalFooter: some View {
        VStack(spacing: 12) {
            Button(action: { Task { await storeKit.restore() } }) {
                HStack(spacing: 6) {
                    if storeKit.isRestoring { ProgressView().tint(.fcTextSecondary).scaleEffect(0.8) }
                    Text("Restore Purchases")
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
        guard !appState.isPremium else {
            infoMessage = "Premium is already active on your account."
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
