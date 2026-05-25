import SwiftUI
import StoreKit

struct ProfileView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.requestReview) private var requestReview

    @State private var showEditProfile = false
    @State private var showDataPrivacy = false
    @State private var showToS = false
    @State private var showPrivacyPolicy = false
    @State private var showPremium = false
    @State private var showSignOutAlert = false
    @State private var showShareSheet = false
    @State private var notificationsEnabled = true

    var user: AppUser? { appState.currentUser }

    private let shareText = "Try FitCheck AI — the app that rates your outfit with Gen Z, professional, and date-night style upgrades. It's actually insane 🔥 https://apps.apple.com/app/fitcheckai"

    var body: some View {
        NavigationStack {
            ZStack {
                Color.fcBackground.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 20) {
                        profileHeader
                        subscriptionBanner
                        preferencesSection
                        accountSection
                        aboutSection
                        Text("FitCheck AI v1.0.0")
                            .font(.fcCaption)
                            .foregroundColor(.fcTextSecondary.opacity(0.5))
                            .padding(.bottom, 100)
                    }
                    .padding(.top, 16)
                }
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
        .sheet(isPresented: $showEditProfile) {
            EditProfileView().environmentObject(appState)
        }
        .sheet(isPresented: $showPremium) {
            PremiumView().environmentObject(appState)
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
                Divider().background(Color.white.opacity(0.1)).frame(height: 30)
                statPill(value: "🔥 \(appState.streakCount)", label: "Streak")
                Divider().background(Color.white.opacity(0.1)).frame(height: 30)
                statPill(value: user != nil && user!.averageScore > 0 ? String(format: "%.1f", user!.averageScore) : "—", label: "Avg Score")
                Divider().background(Color.white.opacity(0.1)).frame(height: 30)
                statPill(value: user != nil && user!.bestScore > 0 ? String(format: "%.1f", user!.bestScore) : "—", label: "Best")
            }
            .padding(16)
            .background(Color.fcSurface)
            .cornerRadius(16)
            .padding(.horizontal, 20)
        }
        .padding(.top, 8)
    }

    private var avatarInitial: some View {
        ZStack {
            Circle()
                .fill(Color.fcAccent.opacity(0.15))
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
                        .foregroundColor(.fcBackground)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.fcGold)
                        .clipShape(Capsule())
                }
            }
            .padding(16)
            .background(appState.isPremium ? Color.fcGold.opacity(0.08) : Color.fcSurface)
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.fcGold.opacity(appState.isPremium ? 0.3 : 0), lineWidth: 1))
            .cornerRadius(16)
        }
        .padding(.horizontal, 20)
    }

    private var preferencesSection: some View {
        sectionCard(title: "Preferences") {
            VStack(spacing: 0) {
                settingRow(icon: "target", label: "Default Style Goal", value: StyleGoal(rawValue: user?.defaultStyleGoal ?? "gen_z")?.displayName ?? "Gen Z") {
                    showEditProfile = true
                }
                Divider().background(Color.white.opacity(0.06))
                Toggle(isOn: $notificationsEnabled) {
                    HStack(spacing: 12) {
                        Image(systemName: "bell.fill")
                            .foregroundColor(.fcAccent)
                            .frame(width: 20)
                        Text("Daily Reminder")
                            .font(.fcBody)
                            .foregroundColor(.fcTextPrimary)
                    }
                }
                .tint(.fcAccent)
                .padding(.vertical, 14)
                .padding(.horizontal, 16)
            }
        }
    }

    private var accountSection: some View {
        sectionCard(title: "Account") {
            VStack(spacing: 0) {
                actionRow(icon: "person.fill", label: "Edit Profile") {
                    showEditProfile = true
                }
                Divider().background(Color.white.opacity(0.06))
                actionRow(icon: "lock.shield.fill", label: "Privacy & Data Settings") {
                    showDataPrivacy = true
                }
                Divider().background(Color.white.opacity(0.06))
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
                Divider().background(Color.white.opacity(0.06))
                actionRow(icon: "hand.raised.fill", label: "Privacy Policy") {
                    showPrivacyPolicy = true
                }
                Divider().background(Color.white.opacity(0.06))
                actionRow(icon: "star.fill", label: "Rate FitCheck ⭐") {
                    requestReview()
                }
                Divider().background(Color.white.opacity(0.06))
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

    private func actionRow(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundColor(.fcAccent)
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
