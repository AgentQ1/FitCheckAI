import SwiftUI

struct PremiumView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    @State private var selectedTier: PremiumTier = .monthly
    @State private var isPurchasing = false

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

                        // CTA
                        Button(action: startPurchase) {
                            Group {
                                if isPurchasing {
                                    ProgressView().tint(.fcBackground)
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
                        .disabled(isPurchasing)
                        .buttonStyle(HapticButtonStyle())
                        .padding(.horizontal, 20)

                        VStack(spacing: 6) {
                            Text("Cancel anytime. No commitment.")
                                .font(.fcCaption)
                                .foregroundColor(.fcTextSecondary)
                            Text("Billed via Apple. Subscription auto-renews until cancelled.")
                                .font(.system(size: 11))
                                .foregroundColor(.fcTextSecondary.opacity(0.6))
                                .multilineTextAlignment(.center)
                            Button("Restore Purchases") {}
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.fcTextSecondary)
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
        isPurchasing = true
        // In real build: call RevenueCat purchase
        // Purchases.shared.purchase(package: ...)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            isPurchasing = false
            appState.analyticsService.track(.subscriptionStarted, properties: ["tier": selectedTier.rawValue])
            dismiss()
        }
    }
}

#Preview {
    PremiumView().environmentObject(AppState())
}
