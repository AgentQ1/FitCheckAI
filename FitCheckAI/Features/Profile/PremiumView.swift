import SwiftUI
import SafariServices
import FirebaseAuth

struct PremiumView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    @State private var selectedTier: PremiumTier = .monthly
    @State private var isPurchasing = false
    @State private var purchaseError: String?
    @State private var checkoutSafariURL: IdentifiableURL?

    enum PremiumTier: String, CaseIterable {
        case student = "student"
        case monthly = "monthly"
        case yearly  = "yearly"

        var title: String {
            switch self {
            case .student: return "Student"
            case .monthly: return "Monthly"
            case .yearly:  return "Yearly"
            }
        }
        var price: String {
            switch self {
            case .student: return "$2.99/mo"
            case .monthly: return "$4.99/mo"
            case .yearly:  return "$39.99/yr"
            }
        }
        var subline: String {
            switch self {
            case .student: return ".edu email required"
            case .monthly: return "Most popular"
            case .yearly:  return "Save 33% · $3.33/mo"
            }
        }
        var isRecommended: Bool { self == .monthly }
    }

    private let features: [(String, String, String)] = [
        ("bolt.fill",         "Outfit checks/day",   "3 → Unlimited"),
        ("chart.pie.fill",    "Style lens scores",    "2 → All 8"),
        ("wand.and.stars",    "AI outfit upgrades",   "Locked → 3 options"),
        ("rectangle.2.swap",  "Before/after compare", "Locked → Included"),
        ("photo.stack.fill",  "Saved wardrobe",       "10 → Unlimited"),
        ("bag.fill",          "Shopping links",        "Locked → Included"),
        ("arrow.up.circle",   "Priority AI",           "Locked → Fastest"),
        ("square.and.arrow.up","Story exports",        "Locked → Included"),
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.fcBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 28) {
                        // Header
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

                        // Features list
                        VStack(spacing: 8) {
                            ForEach(features, id: \.0) { feature in
                                HStack(spacing: 12) {
                                    Image(systemName: feature.0)
                                        .foregroundColor(.fcGold)
                                        .font(.system(size: 16))
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(feature.1)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundColor(.fcTextSecondary)
                                        Text(feature.2)
                                            .font(.system(size: 14, weight: .bold))
                                            .foregroundColor(.fcTextPrimary)
                                    }
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

                        // Pricing cards
                        VStack(spacing: 10) {
                            ForEach(PremiumTier.allCases, id: \.self) { tier in
                                tierCard(tier)
                            }
                        }
                        .padding(.horizontal, 20)

                        // Error banner — surfaces both local purchase errors and
                        // verification errors set by AppState after a deep link.
                        if let err = purchaseError ?? appState.subscriptionVerificationError {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.fcWarning)
                                Text(err)
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

                        // CTA
                        Button(action: startPurchase) {
                            Group {
                                if isPurchasing {
                                    HStack(spacing: 10) {
                                        ProgressView().tint(.fcBackground)
                                        Text("Opening checkout…")
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundColor(.fcBackground)
                                    }
                                } else if appState.isCheckingSubscription {
                                    HStack(spacing: 10) {
                                        ProgressView().tint(.fcBackground)
                                        Text("Confirming payment…")
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundColor(.fcBackground)
                                    }
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
                        .padding(.horizontal, 20)

                        VStack(spacing: 6) {
                            Text("Cancel anytime. No commitment.")
                                .font(.fcCaption)
                                .foregroundColor(.fcTextSecondary)
                            Text("Recurring subscription. Auto-renews until cancelled via Stripe.")
                                .font(.system(size: 11))
                                .foregroundColor(.fcTextSecondary.opacity(0.6))
                                .multilineTextAlignment(.center)
                            Button("Check Subscription Status") {
                                appState.startSubscriptionVerification(sessionId: appState.lastCheckoutSessionId)
                            }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.fcTextSecondary)
                            .disabled(appState.isCheckingSubscription)
                        }
                        .padding(.bottom, 40)
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
        .onAppear {
            appState.analyticsService.track(.premiumUpgradeTapped)
        }
        .fullScreenCover(item: $checkoutSafariURL, onDismiss: {
            // The success deep link normally drives verification — but if the
            // user dismisses Safari manually (or the redirect failed) we still
            // start the verification flow so the UI never sticks. It's a no-op
            // if isPremium already flipped from the deep link path.
            if !appState.isPremium && !appState.isCheckingSubscription {
                appState.startSubscriptionVerification(sessionId: appState.lastCheckoutSessionId)
            }
        }) { identifiable in
            SafariCheckoutSheet(url: identifiable.url)
        }
        .onChange(of: appState.isPremium) { _, isPremium in
            if isPremium {
                appState.analyticsService.track(.subscriptionStarted, properties: ["tier": selectedTier.rawValue])
                dismiss()
            }
        }
        // When AppState.handleDeepLink flips showCheckout=false (Stripe redirected
        // back to the app), tear down the Safari sheet so the user sees the
        // premium screen and the verification spinner, not a stale checkout page.
        .onChange(of: appState.showCheckout) { _, show in
            if !show { checkoutSafariURL = nil }
        }
    }

    private func tierCard(_ tier: PremiumTier) -> some View {
        Button(action: { selectedTier = tier }) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(tier.title)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.fcTextPrimary)
                        if tier.isRecommended {
                            Text("Most popular")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.fcBackground)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.fcAccent)
                                .cornerRadius(6)
                        }
                    }
                    Text(tier.subline)
                        .font(.fcCaption)
                        .foregroundColor(.fcTextSecondary)
                }
                Spacer()
                Text(tier.price)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(selectedTier == tier ? .fcAccent : .fcTextPrimary)
            }
            .padding(16)
            .background(selectedTier == tier ? Color.fcAccent.opacity(0.1) : Color.fcSurface)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(selectedTier == tier ? Color.fcAccent : Color.clear, lineWidth: 1.5)
            )
            .cornerRadius(14)
        }
        .buttonStyle(HapticButtonStyle(style: .light))
    }

    private func startPurchase() {
        guard !isPurchasing else { return }
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
                    // Surface specific known failure modes
                    let msg: String
                    if serverCode == "student_plan_unavailable" {
                        msg = "Student pricing isn't available yet. Please choose Monthly or Yearly."
                    } else if serverCode == "price_not_configured" {
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
