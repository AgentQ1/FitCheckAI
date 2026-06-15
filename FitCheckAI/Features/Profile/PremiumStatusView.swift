import SwiftUI
import StoreKit

/// Shown when a user with ACTIVE Premium opens any premium entry point. This is the
/// management surface — it never offers to buy/upgrade. Apple is the source of truth;
/// "Manage Subscription" opens Apple's native sheet. Non-premium users are routed to
/// `PremiumView` (the paywall) instead.
struct PremiumStatusView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var storeKit: StoreKitService
    @Environment(\.dismiss) var dismiss

    private let benefits: [(String, String)] = [
        ("infinity",           "Unlimited outfit checks"),
        ("chart.pie.fill",     "All 8 style lenses"),
        ("chart.line.uptrend.xyaxis", "Full style progress"),
        ("sparkles",           "Premium AI feedback"),
        ("wand.and.stars",     "AI outfit upgrades"),
        ("photo.stack.fill",   "Unlimited saved wardrobe"),
    ]

    /// True when entitlement comes from Apple (vs. a grandfathered legacy subscriber
    /// whose Premium is still recorded in Firestore).
    private var isAppleEntitlement: Bool { storeKit.hasPremium }

    private var planName: String {
        if isAppleEntitlement { return storeKit.planDisplayName(for: storeKit.activeProductID) }
        if let name = appState.currentUser?.planName, !name.isEmpty { return name }
        return appState.premiumTier.displayName
    }

    private var statusLabel: String {
        if isAppleEntitlement {
            if storeKit.isInTrialPeriod { return "Free Trial" }
            return storeKit.willAutoRenew ? "Active" : "Cancels at period end"
        }
        switch appState.currentUser?.subscriptionStatus.lowercased() {
        case "trialing":              return "Free Trial"
        case "active", "none", nil:   return "Active"
        case "past_due":              return "Past Due"
        case "canceled", "cancelled": return "Cancelled"
        default:
            let raw = appState.currentUser?.subscriptionStatus ?? "Active"
            return raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }

    private var statusIsWarning: Bool {
        if isAppleEntitlement { return !storeKit.willAutoRenew }
        let s = appState.currentUser?.subscriptionStatus.lowercased()
        return s == "canceled" || s == "cancelled" || s == "past_due"
    }

    private var renewalDate: Date? {
        if isAppleEntitlement { return storeKit.expirationDate }
        return appState.currentUser?.currentPeriodEnd ?? appState.currentUser?.subscriptionExpiresAt
    }

    private var renewalRowLabel: String {
        if isAppleEntitlement { return storeKit.willAutoRenew ? "Renews" : "Access until" }
        return statusIsWarning ? "Access until" : "Renews"
    }

    private var renewalString: String? {
        guard let date = renewalDate else { return nil }
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        return fmt.string(from: date)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.fcBackground.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 24) {
                        header
                        detailsCard
                        benefitsCard
                        actions.padding(.horizontal, 20)
                        footer
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 40)
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
        .task { await storeKit.refreshEntitlement() }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 8) {
            Text("✦")
                .font(.system(size: 40))
                .foregroundColor(.fcGold)
            Text("FitCheck Premium")
                .font(.fcDisplay)
                .foregroundColor(.fcTextPrimary)
            Text("Premium is active on your account.")
                .font(.fcBody)
                .foregroundColor(.fcTextSecondary)
        }
        .padding(.top, 8)
    }

    private var detailsCard: some View {
        VStack(spacing: 0) {
            detailRow(label: "Current Plan", value: planName)
            Divider().background(Color.fcTextSecondary.opacity(0.15))
            detailRow(label: "Status", value: statusLabel,
                      valueColor: statusIsWarning ? .fcWarning : .fcSuccess)
            if let renewalString {
                Divider().background(Color.fcTextSecondary.opacity(0.15))
                detailRow(label: renewalRowLabel, value: renewalString)
            }
        }
        .background(Color.fcSurface)
        .cornerRadius(16)
        .shadow(color: Color.fcShadow, radius: 10, y: 4)
        .padding(.horizontal, 20)
    }

    private func detailRow(label: String, value: String, valueColor: Color = .fcTextPrimary) -> some View {
        HStack {
            Text(label)
                .font(.fcBody)
                .foregroundColor(.fcTextSecondary)
            Spacer()
            Text(value)
                .font(.fcBodyBold)
                .foregroundColor(valueColor)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 16)
    }

    private var benefitsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Included with Premium")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.fcTextSecondary)
                .padding(.horizontal, 20)

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
    }

    private var actions: some View {
        VStack(spacing: 12) {
            // Manage Subscription — Apple's native subscription management sheet.
            Button(action: { Task { await storeKit.showManageSubscriptions() } }) {
                HStack(spacing: 10) {
                    Image(systemName: "gearshape.fill")
                        .foregroundColor(.fcBackground)
                    Text("Manage Subscription")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.fcBackground)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.fcAccent)
                .cornerRadius(16)
            }
            .buttonStyle(HapticButtonStyle())

            // Restore Purchases — re-sync Apple entitlements.
            Button(action: { Task { await storeKit.restore() } }) {
                HStack(spacing: 10) {
                    if storeKit.isRestoring {
                        ProgressView().tint(.fcTextPrimary)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .foregroundColor(.fcTextPrimary)
                    }
                    Text("Restore Purchases")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.fcTextPrimary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.fcSurface)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.fcTextSecondary.opacity(0.2), lineWidth: 1))
                .cornerRadius(16)
            }
            .disabled(storeKit.isRestoring)
            .buttonStyle(HapticButtonStyle(style: .light))

            if let err = storeKit.lastError {
                Text(err)
                    .font(.fcCaption)
                    .foregroundColor(.fcWarning)
                    .multilineTextAlignment(.center)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if isAppleEntitlement {
            Text("Manage or cancel anytime in the App Store. Your subscription renews automatically until cancelled.")
                .font(.fcCaption)
                .foregroundColor(.fcTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        } else {
            // Grandfathered legacy subscriber (subscription started outside the App Store).
            Text("Your subscription was started on the web and is billed outside the App Store. To manage or cancel it, contact \(Config.supportEmail).")
                .font(.fcCaption)
                .foregroundColor(.fcTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }
}

#Preview {
    PremiumStatusView()
        .environmentObject(AppState())
        .environmentObject(StoreKitService())
}
