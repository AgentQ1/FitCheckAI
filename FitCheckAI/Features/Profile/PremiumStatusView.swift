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

    /// Drives Apple's native subscription-management sheet (SwiftUI-managed presentation,
    /// so it never conflicts with the fullScreenCover that hosts this view).
    @State private var isShowingManageSheet = false
    /// Debounce: prevents a double-tap from queueing two presentations.
    @State private var isOpeningManageSubscriptions = false

    private let benefits: [(String, String)] = [
        ("infinity",           "Unlimited outfit checks"),
        ("chart.pie.fill",     "All 8 style lenses"),
        ("chart.line.uptrend.xyaxis", "Full style progress"),
        ("sparkles",           "Premium AI feedback"),
        ("wand.and.stars",     "AI outfit upgrades"),
        ("photo.stack.fill",   "Unlimited saved wardrobe"),
    ]

    // Apple (StoreKit) is the sole source of truth for Premium. One shared phase drives
    // every label here, so this screen can never disagree with the Profile card.
    private var phase: StoreKitService.PremiumPhase { storeKit.premiumPhase }

    private var planName: String {
        storeKit.planDisplayName(for: storeKit.activeProductID)
    }

    /// Status wording. A trial is "Premium Trial Active" — never a bare "Free Trial",
    /// which read like a different, non-Premium plan. A cancelling (auto-renew off)
    /// subscription reads as "Active until <date>" — Premium is still active, so we
    /// never show scary "cancelling" wording.
    private var statusLabel: String {
        switch phase {
        case .trial:      return "Premium Trial Active"
        case .active:     return "Active"
        case .cancelling:
            if let date = renewalString { return "Active until \(date)" }
            return "Active"
        case .none:       return "Active"
        }
    }

    /// Every active phase (including a cancelling-but-still-active sub) is shown in the
    /// success colour — the user still has full Premium access, so there's no warning.
    private var statusIsWarning: Bool { false }

    /// Row label for the date: a trial ends, a renewing sub renews on, a cancelling sub
    /// keeps access until.
    private var renewalRowLabel: String {
        switch phase {
        case .trial:      return "Trial ends"
        case .active:     return "Renews on"
        case .cancelling: return "Access until"
        case .none:       return "Access until"
        }
    }

    private var renewalString: String? {
        StoreKitService.displayDate(storeKit.expirationDate)
    }

    private var headerSubtitle: String {
        switch phase {
        case .trial:      return "You're enjoying your Premium trial."
        case .cancelling: return "Premium stays active until your access ends."
        default:          return "Premium is active on your account."
        }
    }

    // MARK: - Restore feedback
    /// The result message for the most recent Restore tap. Non-nil drives the (single)
    /// alert on this screen, so every restore produces a visible outcome. This is now the
    /// ONLY `.alert` on the view — the previously-stacked, never-triggered manage-fallback
    /// alert was removed (dead code that also shadowed this restore alert).
    @State private var restoreMessage: String?
    /// True when a guest's restore found an active entitlement, so the alert offers Sign In.
    @State private var restoreOffersSignIn = false
    @State private var showAuthSheet = false

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
        // Apple's native subscription-management sheet. SwiftUI owns the presentation,
        // so there is no UIKit "present on a controller that is already presenting"
        // crash (this view is itself inside a fullScreenCover) and no scene/window
        // force-unwrap. The sheet shows its own loading UI while Apple fetches the
        // subscription, so our button never hangs.
        .manageSubscriptionsSheet(isPresented: $isShowingManageSheet)
        .onChange(of: isShowingManageSheet) { _, presented in
            if presented {
                AppLog.premium("presenting StoreKit manage subscriptions")
            } else {
                AppLog.premium("manage subscriptions sheet returned/cancelled")
                isOpeningManageSubscriptions = false
                AppLog.premium("manage subscriptions finished safely")
                // Apple may have changed the plan (cancel / upgrade) inside the sheet.
                Task { await storeKit.refreshEntitlement() }
            }
        }
        // Restore result — the single alert on this screen, shown for EVERY restore tap so
        // the user never returns to a silent, unchanged screen after the Apple prompt.
        .alert("Restore Purchases", isPresented: Binding(
            get: { restoreMessage != nil },
            set: { if !$0 { restoreMessage = nil } }
        )) {
            if restoreOffersSignIn {
                Button("Sign In") { showAuthSheet = true }
                Button("Not Now", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: {
            Text(restoreMessage ?? "")
        }
        .sheet(isPresented: $showAuthSheet) {
            NavigationStack { AuthView().environmentObject(appState) }
        }
    }

    // MARK: - Restore

    /// Restore Purchases — distinct from Manage Subscription: this re-syncs Apple's
    /// entitlements (`AppStore.sync()` → re-derive) and reports a clear result for every
    /// outcome. Duplicate taps are blocked by `storeKit.isRestoring`.
    @MainActor
    private func restorePurchases() {
        guard !storeKit.isRestoring else { return }
        restoreMessage = nil
        restoreOffersSignIn = false
        storeKit.lastError = nil
        Task { @MainActor in
            let outcome = await storeKit.restore()
            let message: String
            switch outcome {
            case .alreadyActive:
                message = "Your Premium is already active."
            case .restored(let trial):
                message = trial ? "Premium trial restored successfully." : "Premium restored successfully."
            case .restoredGuest:
                message = "Premium restored. Sign in to keep your subscription synced safely."
                restoreOffersSignIn = true
            case .notFound:
                message = "No active Premium subscription was found for this Apple ID."
            case .cancelled:
                message = "Restore cancelled."
            case .failed:
                message = "We couldn't restore purchases right now. Please try again."
            }
            // The sync paths showed Apple's prompt; let it fully dismiss before we present
            // our alert, otherwise SwiftUI drops it (presentation context still busy). The
            // fast "already active" path had no prompt, so it stays instant.
            if outcome != .alreadyActive {
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
            restoreMessage = message
            AppLog.premium("restore UI message shown: \(message)")
        }
    }

    // MARK: - Manage subscription

    private func openManageSubscriptions() {
        AppLog.premium("Manage Subscription tapped")
        // Debounce: ignore repeat taps while a presentation is already in flight.
        guard !isOpeningManageSubscriptions else {
            AppLog.premium("manage subscriptions ignored — already opening")
            return
        }
        isOpeningManageSubscriptions = true
        isShowingManageSheet = true
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
            Text(headerSubtitle)
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
            // Manage Subscription is the ONLY primary action for an active subscriber —
            // it opens Apple's native subscription management sheet. Restore is
            // de-emphasised to a small footer link (an active user rarely needs it).
            Button(action: { openManageSubscriptions() }) {
                HStack(spacing: 10) {
                    if isOpeningManageSubscriptions {
                        ProgressView().tint(.fcBackground)
                        Text("Opening…")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundColor(.fcBackground)
                    } else {
                        Image(systemName: "gearshape.fill")
                            .foregroundColor(.fcBackground)
                        Text("Manage Subscription")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundColor(.fcBackground)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.fcAccent)
                .cornerRadius(16)
            }
            .disabled(isOpeningManageSubscriptions)
            .buttonStyle(HapticButtonStyle())

            if let err = storeKit.lastError {
                Text(err)
                    .font(.fcCaption)
                    .foregroundColor(.fcWarning)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 16) {
            // Small, de-emphasised restore link — Apple requires a restore mechanism, but
            // an already-active subscriber doesn't need it front-and-centre. Always
            // reports a clear, visible result via the shared alert.
            Button(action: restorePurchases) {
                HStack(spacing: 6) {
                    if storeKit.isRestoring { ProgressView().tint(.fcTextSecondary).scaleEffect(0.8) }
                    Text(storeKit.isRestoring ? "Restoring…" : "Already purchased? Restore Purchases")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.fcTextSecondary)
                }
            }
            .disabled(storeKit.isRestoring)

            Text("Manage or cancel anytime in the App Store. Your subscription renews automatically until cancelled.")
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
