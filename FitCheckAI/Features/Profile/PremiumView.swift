import SwiftUI
import SafariServices
import FirebaseAuth

/// FitCheck Premium paywall — shown only to non-subscribers. Purchasing happens
/// through Stripe Checkout opened in an in-app Safari sheet; on return the
/// `fitcheckai://stripe/success` deep link drives verification. A user who is
/// already premium can never sit on this screen (see the `isPremium` guards).
struct PremiumView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss

    @State private var selectedTier: PremiumTier = .monthly
    @State private var isPurchasing = false
    @State private var purchaseError: String?
    @State private var checkoutSafariURL: IdentifiableURL?
    @State private var showToS = false
    @State private var showPrivacy = false

    enum PremiumTier: String, CaseIterable {
        case monthly = "monthly"
        case yearly  = "yearly"

        var title: String {
            switch self {
            case .monthly: return "Monthly"
            case .yearly:  return "Yearly"
            }
        }
        var price: String {
            switch self {
            case .monthly: return "$4.99"
            case .yearly:  return "$39.99"
            }
        }
        var periodSuffix: String {
            switch self {
            case .monthly: return "per month"
            case .yearly:  return "per year"
            }
        }
        var subline: String {
            switch self {
            case .monthly: return "Billed monthly"
            case .yearly:  return "Just $3.33 per month"
            }
        }
        var badge: String? {
            switch self {
            case .monthly: return "Most popular"
            case .yearly:  return "Save 33%"
            }
        }
    }

    // Clean benefit rows — icon, label, trailing checkmark.
    private let benefits: [(String, String)] = [
        ("infinity",                   "Unlimited outfit checks"),
        ("chart.pie.fill",             "All 8 style lenses"),
        ("chart.line.uptrend.xyaxis",  "Full style progress"),
        ("sparkles",                   "Premium AI feedback"),
        ("wand.and.stars",             "AI outfit upgrades"),
        ("photo.stack.fill",           "Unlimited saved wardrobe"),
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.fcBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 26) {
                        header
                        benefitsList
                        pricing
                        if let msg = purchaseError ?? appState.subscriptionVerificationError {
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
        .onAppear {
            // A premium user must never see the paywall.
            if appState.isPremium { dismiss(); return }
            appState.analyticsService.track(.premiumUpgradeTapped)
        }
        // Stripe confirmed the subscription (deep link → verification) → leave.
        .onChange(of: appState.isPremium) { _, isPremium in
            if isPremium {
                appState.analyticsService.track(.subscriptionStarted,
                                                properties: ["tier": selectedTier.rawValue])
                dismiss()
            }
        }
        // When AppState.handleDeepLink flips showCheckout=false (Stripe redirected
        // back to the app), tear down the Safari sheet so the user sees the premium
        // screen and the verification spinner, not a stale checkout page.
        .onChange(of: appState.showCheckout) { _, show in
            if !show { checkoutSafariURL = nil }
        }
        .fullScreenCover(item: $checkoutSafariURL, onDismiss: {
            // The success deep link normally drives verification — but if the user
            // dismisses Safari manually (or the redirect failed) we still start the
            // verification flow so the UI never sticks. No-op if isPremium already
            // flipped from the deep link path.
            if !appState.isPremium && !appState.isCheckingSubscription {
                appState.startSubscriptionVerification(sessionId: appState.lastCheckoutSessionId)
            }
        }) { identifiable in
            SafariCheckoutSheet(url: identifiable.url)
        }
        .sheet(isPresented: $showToS) { NavigationStack { TermsOfServiceView() } }
        .sheet(isPresented: $showPrivacy) { NavigationStack { PrivacyPolicyView() } }
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

    private var pricing: some View {
        VStack(spacing: 10) {
            ForEach(PremiumTier.allCases, id: \.self) { tier in
                tierCard(tier)
            }
        }
        .padding(.horizontal, 20)
    }

    private func tierCard(_ tier: PremiumTier) -> some View {
        let isSelected = selectedTier == tier
        let isYearly = tier == .yearly
        return Button(action: { selectedTier = tier }) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(tier.title)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.fcTextPrimary)
                        if let badge = tier.badge {
                            Text(badge)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.fcBackground)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(isYearly ? Color.fcGold : Color.fcAccent)
                                .cornerRadius(6)
                        }
                    }
                    Text(tier.subline)
                        .font(.fcCaption)
                        .foregroundColor(.fcTextSecondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(tier.price)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(isSelected ? .fcAccent : .fcTextPrimary)
                    Text(tier.periodSuffix)
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
                    if isPurchasing {
                        progressLabel("Opening checkout…")
                    } else if appState.isCheckingSubscription {
                        progressLabel("Confirming payment…")
                    } else {
                        Text("Start 3-Day Free Trial →")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundColor(.fcBackground)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.fcAccent)
                .cornerRadius(16)
            }
            .disabled(isPurchasing || appState.isCheckingSubscription)
            .buttonStyle(HapticButtonStyle())

            Text("Then \(selectedTier.price) \(selectedTier.periodSuffix). Cancel anytime.")
                .font(.fcCaption)
                .foregroundColor(.fcTextSecondary)
        }
        .padding(.horizontal, 20)
    }

    private func progressLabel(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().tint(.fcBackground)
            Text(text)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.fcBackground)
        }
    }

    // MARK: - Legal footer

    private var legalFooter: some View {
        VStack(spacing: 12) {
            Button(action: {
                appState.startSubscriptionVerification(sessionId: appState.lastCheckoutSessionId)
            }) {
                HStack(spacing: 6) {
                    if appState.isCheckingSubscription {
                        ProgressView().tint(.fcTextSecondary).scaleEffect(0.8)
                    }
                    Text("Restore Purchase")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.fcTextSecondary)
                }
            }
            .disabled(appState.isCheckingSubscription)

            Text("Recurring subscription. Auto-renews until cancelled. Manage or cancel anytime from your account.")
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
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.fcWarning)
            Text(text)
                .font(.fcCaption)
                .foregroundColor(.fcTextPrimary)
                .multilineTextAlignment(.leading)
            Spacer()
            Button(action: {
                purchaseError = nil
                appState.subscriptionVerificationError = nil
            }) {
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
        guard !isPurchasing else { return }
        guard !appState.isPremium else { dismiss(); return }
        guard Auth.auth().currentUser != nil else {
            purchaseError = "Please sign in before subscribing."
            return
        }
        isPurchasing = true
        purchaseError = nil
        appState.analyticsService.track(.premiumUpgradeTapped, properties: ["tier": selectedTier.rawValue])

        Task {
            defer { Task { @MainActor in isPurchasing = false } }
            do {
                let token = try await Auth.auth().currentUser!.getIDToken()
                let url = URL(string: Config.API.createCheckoutSession)!
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                req.timeoutInterval = 30
                req.httpBody = try JSONSerialization.data(withJSONObject: ["plan": selectedTier.rawValue])

                let (data, response) = try await URLSession.shared.data(for: req)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else {
                    let decoded = try? JSONDecoder().decode([String: String].self, from: data)
                    let serverMsg = decoded?["message"]
                    let serverCode = decoded?["error"]
                    let msg: String
                    if serverCode == "price_not_configured" {
                        msg = serverMsg ?? "Subscription pricing isn't set up yet. Please try again later."
                    } else {
                        msg = serverMsg ?? "Could not open checkout (HTTP \(status)). Try again."
                    }
                    print("[PremiumView] checkout failed status=\(status) code=\(serverCode ?? "?") msg=\(serverMsg ?? "?")")
                    await MainActor.run { purchaseError = msg }
                    return
                }
                let body = try JSONDecoder().decode([String: String].self, from: data)
                guard let urlString = body["url"], let checkoutUrl = URL(string: urlString) else {
                    await MainActor.run { purchaseError = "Invalid checkout URL from server." }
                    return
                }
                await MainActor.run {
                    checkoutSafariURL = IdentifiableURL(url: checkoutUrl)
                    appState.showCheckout = true
                }
            } catch {
                await MainActor.run { purchaseError = "Network error. Check your connection and try again." }
                print("[PremiumView] startPurchase error: \(error)")
            }
        }
    }
}

// MARK: - Helpers

struct IdentifiableURL: Identifiable {
    let id = UUID()
    let url: URL
}

struct SafariCheckoutSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}

#Preview {
    PremiumView().environmentObject(AppState())
}
