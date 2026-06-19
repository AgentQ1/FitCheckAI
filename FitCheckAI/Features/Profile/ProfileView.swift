import SwiftUI

struct ProfileView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openURL) private var openURL

    @State private var showEditProfile = false
    @State private var showMyArena = false
    @State private var showDataPrivacy = false
    @State private var showToS = false
    @State private var showPrivacyPolicy = false
    @State private var showPremium = false
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
        .fullScreenCover(isPresented: $showPremium) {
            // Active subscribers manage their plan; non-subscribers see the paywall.
            if appState.isPremium {
                PremiumStatusView()
                    .environmentObject(appState)
                    .environmentObject(appState.storeKit)
            } else {
                PremiumView()
                    .environmentObject(appState)
                    .environmentObject(appState.storeKit)
            }
        }
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

    private var profileHeader: some View {
        VStack(spacing: 16) {
            // Avatar
            ZStack {
                if let photoURL = user?.photoURL, let url = URL(string: photoURL) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFill()
                                .frame(width: 80, height: 80)
                                .clipShape(Circle())
                        default:
                            avatarInitial
                        }
                    }
                } else {
                    avatarInitial
                }
            }

            VStack(spacing: 4) {
                Text(user?.displayName ?? "Your Name")
                    .font(.fcHeading)
                    .foregroundColor(.fcTextPrimary)
                Text(user?.email ?? "")
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

    private var avatarInitial: some View {
        ZStack {
            Circle()
                .fill(Color.fcAccent2)
                .frame(width: 80, height: 80)
            Circle()
                .strokeBorder(Color.fcAccent, lineWidth: 2.5)
                .frame(width: 80, height: 80)
            Text(String(user?.firstName.prefix(1).uppercased() ?? "?"))
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundColor(.fcAccent)
        }
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

    private var subscriptionBanner: some View {
        Button(action: { showPremium = true }) {
            HStack(spacing: 12) {
                Text("✦")
                    .font(.system(size: 20))
                    .foregroundColor(.fcGold)
                VStack(alignment: .leading, spacing: 2) {
                    Text(appState.isPremium ? "Premium ✦ — Active" : "Upgrade to Premium")
                        .font(.fcBodyBold)
                        .foregroundColor(appState.isPremium ? .fcGold : .fcTextPrimary)
                    Text(appState.isPremium ? "Unlimited checks · All 8 style lenses" : "3 checks/day · Tap to unlock all features")
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
                Divider().background(Color.fcTextSecondary.opacity(0.15))
                actionRow(icon: "flame.fill", label: "My Arena Fits") {
                    showMyArena = true
                }
                Divider().background(Color.fcTextSecondary.opacity(0.15))
                actionRow(icon: "lock.shield.fill", label: "Privacy & Data Settings") {
                    showDataPrivacy = true
                }
                if appState.isPremium {
                    Divider().background(Color.fcTextSecondary.opacity(0.15))
                    actionRow(icon: "creditcard.fill", label: "Manage Subscription", iconColor: .fcGold) {
                        showPremium = true
                    }
                }
                Divider().background(Color.fcTextSecondary.opacity(0.15))
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
