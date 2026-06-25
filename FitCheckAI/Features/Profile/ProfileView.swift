import SwiftUI

struct ProfileView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openURL) private var openURL

    @State private var showEditProfile = false
    @State private var showMyArena = false
    @State private var showDataPrivacy = false
    @State private var showToS = false
    @State private var showPrivacyPolicy = false
    @State private var showSignOutAlert = false
    @State private var showShareSheet = false

    var user: AppUser? { appState.currentUser }

    private var shareText: String {
        "Try FitCheck — AI rates your outfit and shows you how to level it up. \(Config.appStoreURL)"
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Color.fcBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        profileHeader
                        subscriptionBanner
                        preferencesSection
                        accountSection
                        aboutSection
                        Text("FitCheck v1.0.0")
                            .font(.fcCaption)
                            .foregroundColor(.fcTextSecondary.opacity(0.5))
                            .padding(.bottom, 130) // clear the floating tab bar / FAB
                    }
                    .padding(.top, 12)
                }

                // Opaque cover so scrolled content never shows under the status bar
                // (ProfileView has no navigation bar to provide one).
                statusBarCover
            }
            .onChange(of: appState.isPremium) { _, isPremium in
                if isPremium { print("[ProfileView] received premium=true — banner now shows Premium Active") }
            }
            .navigationDestination(isPresented: $showMyArena) {
                MyArenaResultsView().environmentObject(appState)
            }
            .navigationDestination(isPresented: $showDataPrivacy) {
                DataPrivacySettingsView().environmentObject(appState)
            }
            .navigationDestination(isPresented: $showToS) {
                TermsOfServiceView()
            }
            .navigationDestination(isPresented: $showPrivacyPolicy) {
                PrivacyPolicyView()
            }
        }
        .fullScreenCover(isPresented: $showEditProfile) {
            EditProfileView().environmentObject(appState)
        }
        // Premium is presented through the SINGLE global path (RootView's
        // `appState.showPremiumSheet`), which does the same premium-vs-paywall routing.
        // The previous local fullScreenCover here was a duplicate presentation path.
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: [shareText])
        }
        .alert("Sign Out", isPresented: $showSignOutAlert) {
            Button("Sign Out", role: .destructive) {
                Task { await appState.signOut() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to sign out?")
        }
    }

    // MARK: - Status bar cover

    private var statusBarCover: some View {
        VStack(spacing: 0) {
            Color.fcBackground.frame(height: safeAreaTop())
            Spacer(minLength: 0)
        }
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
    }

    private func safeAreaTop() -> CGFloat {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
            .windows.first?.safeAreaInsets.top ?? 0
    }

    // MARK: - Sections

    /// Stable avatar seed — the uid (never blank, even for guests).
    private var avatarSeed: String {
        user?.id ?? "fitcheck-user"
    }

    private var profileHeader: some View {
        VStack(spacing: 16) {
            // Avatar — never blank: real photo, else a deterministic generated avatar.
            GeneratedAvatarView(photoURL: user?.photoURL, seed: avatarSeed, name: user?.displayName, size: 80)

            VStack(spacing: 4) {
                Text(user?.displayName ?? GuestIdentity.nickname(seed: avatarSeed))
                    .font(.fcHeading)
                    .foregroundColor(.fcTextPrimary)
                // Never show a (masked) email as the subtitle. Guests get a clear status.
                Text(profileSubtitle)
                    .font(.fcCaption)
                    .foregroundColor(.fcTextSecondary)
            }

            // Stats row
            HStack(spacing: 0) {
                statPill(value: "\(user?.totalFitChecks ?? 0)", label: "Checks")
                Divider().background(Color.fcTextSecondary.opacity(0.2)).frame(height: 30)
                statPill(value: "🔥 \(appState.streakCount)", label: "Streak")
                Divider().background(Color.fcTextSecondary.opacity(0.2)).frame(height: 30)
                statPill(value: user != nil && user!.averageScore > 0 ? String(format: "%.1f", user!.averageScore) : "—", label: "Avg Score")
                Divider().background(Color.fcTextSecondary.opacity(0.2)).frame(height: 30)
                statPill(value: user != nil && user!.bestScore > 0 ? String(format: "%.1f", user!.bestScore) : "—", label: "Best")
            }
            .padding(16)
            .background(Color.fcSurface)
            .cornerRadius(16)
            .shadow(color: Color.fcShadow, radius: 10, y: 4)
            .padding(.horizontal, 20)
        }
        .padding(.top, 8)
    }

    /// Subtitle under the name: a guest sees their status (no email); a real account
    /// shows its email, but never a masked Apple relay address.
    private var profileSubtitle: String {
        if appState.isGuest { return "Guest · sign in to save your progress" }
        let email = user?.email ?? ""
        if email.isEmpty || GuestIdentity.isMaskedAppleEmail(email) { return "Signed in" }
        return email
    }

    private func statPill(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundColor(.fcTextPrimary)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.fcTextSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// Title + subtitle for the subscription card, kept in lock-step with the Premium
    /// detail screen via the shared `appState.premiumPhase`. A trial reads as
    /// "Premium Trial — Active" (never a separate-looking "Free Trial").
    private var bannerTitle: String {
        switch appState.premiumPhase {
        case .trial:               return "Premium Trial — Active"
        case .active, .cancelling: return "Premium — Active"
        case .none:                return "Upgrade to Premium"
        }
    }

    private var bannerSubtitle: String {
        switch appState.premiumPhase {
        case .trial(let ends):
            if let date = StoreKitService.displayDateShort(ends) {
                return "Unlimited checks · Trial ends \(date)"
            }
            return "Unlimited checks · All 8 style lenses"
        case .active(let renews):
            if let date = StoreKitService.displayDateShort(renews) {
                return "Unlimited checks · Renews \(date)"
            }
            return "Unlimited checks · All 8 style lenses"
        case .cancelling(let until):
            // Auto-renew is off but access continues — show the access date, never
            // scary "cancelling" wording.
            if let date = StoreKitService.displayDateShort(until) {
                return "Unlimited checks · Access until \(date)"
            }
            return "Unlimited checks · All 8 style lenses"
        case .none:
            return "Unlimited checks · All 8 style lenses"
        }
    }

    private var subscriptionBanner: some View {
        Button(action: { appState.showPremiumSheet = true }) {
            HStack(spacing: 12) {
                Text("✦")
                    .font(.system(size: 20))
                    .foregroundColor(.fcGold)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bannerTitle)
                        .font(.fcBodyBold)
                        .foregroundColor(appState.isPremium ? .fcGold : .fcTextPrimary)
                    Text(bannerSubtitle)
                        .font(.fcCaption)
                        .foregroundColor(.fcTextSecondary)
                }
                Spacer()
                if !appState.isPremium {
                    Text("Upgrade →")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(Color.fcAccentCream)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.fcAccent)
                        .clipShape(Capsule())
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12))
                        .foregroundColor(.fcGold.opacity(0.7))
                }
            }
            .padding(16)
            .background(appState.isPremium ? Color.fcGold.opacity(0.12) : Color.fcSurface)
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.fcGold.opacity(appState.isPremium ? 0.4 : 0), lineWidth: 1.5))
            .cornerRadius(16)
            .shadow(color: Color.fcShadow, radius: 10, y: 4)
        }
        .padding(.horizontal, 20)
    }

    private var preferencesSection: some View {
        sectionCard(title: "Preferences") {
            VStack(spacing: 0) {
                settingRow(icon: "target", label: "Default Style Goal", value: StyleGoal(rawValue: user?.defaultStyleGoal ?? "gen_z")?.displayName ?? "Gen Z") {
                    showEditProfile = true
                }
            }
        }
    }

    private var accountSection: some View {
        sectionCard(title: "Account") {
            VStack(spacing: 0) {
                actionRow(icon: "person.fill", label: "Edit Profile") {
                    showEditProfile = true
                }
                if !appState.isGuest {
                    Divider().background(Color.fcTextSecondary.opacity(0.15))
                    actionRow(icon: "flame.fill", label: "My Arena Fits") {
                        showMyArena = true
                    }
                }
                Divider().background(Color.fcTextSecondary.opacity(0.15))
                actionRow(icon: "lock.shield.fill", label: "Privacy & Data Settings") {
                    showDataPrivacy = true
                }
                if appState.isPremium {
                    Divider().background(Color.fcTextSecondary.opacity(0.15))
                    actionRow(icon: "creditcard.fill", label: "Manage Subscription", iconColor: .fcGold) {
                        appState.showPremiumSheet = true
                    }
                }
                Divider().background(Color.fcTextSecondary.opacity(0.15))
                if appState.isGuest {
                    // Guests have no account to sign out of — offer conversion instead.
                    Button(action: { appState.showGuestSignInGate = true }) {
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.badge.plus")
                                .foregroundColor(.fcAccent)
                                .frame(width: 20)
                            Text("Sign in to save your progress")
                                .font(.fcBody)
                                .foregroundColor(.fcAccent)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12))
                                .foregroundColor(.fcTextSecondary)
                        }
                        .padding(16)
                    }
                } else {
                    Button(action: { showSignOutAlert = true }) {
                        HStack(spacing: 12) {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                .foregroundColor(.fcError)
                                .frame(width: 20)
                            Text("Sign Out")
                                .font(.fcBody)
                                .foregroundColor(.fcError)
                            Spacer()
                        }
                        .padding(16)
                    }
                }
            }
        }
    }

    private var aboutSection: some View {
        sectionCard(title: "About") {
            VStack(spacing: 0) {
                actionRow(icon: "doc.text.fill", label: "Terms of Service") {
                    showToS = true
                }
                Divider().background(Color.fcTextSecondary.opacity(0.15))
                actionRow(icon: "hand.raised.fill", label: "Privacy Policy") {
                    showPrivacyPolicy = true
                }
                Divider().background(Color.fcTextSecondary.opacity(0.15))
                actionRow(icon: "star.fill", label: "Rate FitCheck ⭐") {
                    if let url = URL(string: Config.writeReviewURL) { openURL(url) }
                }
                Divider().background(Color.fcTextSecondary.opacity(0.15))
                actionRow(icon: "square.and.arrow.up", label: "Share App") {
                    showShareSheet = true
                }
            }
        }
    }

    // MARK: - Helpers

    private func sectionCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.fcTextSecondary)
                .padding(.horizontal, 20)
            content()
                .background(Color.fcSurface)
                .cornerRadius(16)
                .shadow(color: Color.fcShadow, radius: 10, y: 4)
        }
        .padding(.horizontal, 20)
    }

    private func settingRow(icon: String, label: String, value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundColor(.fcAccent)
                    .frame(width: 20)
                Text(label)
                    .font(.fcBody)
                    .foregroundColor(.fcTextPrimary)
                Spacer()
                Text(value)
                    .font(.fcCaption)
                    .foregroundColor(.fcTextSecondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundColor(.fcTextSecondary)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
        }
    }

    private func actionRow(icon: String, label: String, iconColor: Color = .fcAccent, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundColor(iconColor)
                    .frame(width: 20)
                Text(label)
                    .font(.fcBody)
                    .foregroundColor(.fcTextPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundColor(.fcTextSecondary)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
        }
    }
}
