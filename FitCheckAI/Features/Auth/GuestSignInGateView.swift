import SwiftUI
import AuthenticationServices
import GoogleSignInSwift
import UIKit

/// The "Save your style journey" gate. Shown when a GUEST tries a second fit check
/// (or any sign-in-only action). Signing in here LINKS the anonymous guest account
/// into a permanent one (see AuthService.signInOrLink), so their nickname, avatar, and
/// first fit check carry over. "Maybe Later" just dismisses — the guest keeps browsing
/// the Arena and leaderboards; it never dead-ends.
struct GuestSignInGateView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.fcBackground.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 24) {
                        VStack(spacing: 12) {
                            ZStack {
                                Circle().fill(Color.fcAccent.opacity(0.12)).frame(width: 72, height: 72)
                                Image(systemName: "sparkles")
                                    .font(.system(size: 30, weight: .bold))
                                    .foregroundColor(.fcAccent)
                            }
                            .padding(.top, 8)

                            Text("Save your style journey")
                                .font(.fcDisplay)
                                .foregroundColor(.fcTextPrimary)
                                .multilineTextAlignment(.center)
                            Text("You've used your free guest Fit Check. Sign in to continue checking fits, save progress, and join Arena.")
                                .font(.fcBody)
                                .foregroundColor(.fcTextSecondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 8)
                        }

                        VStack(spacing: 14) {
                            SignInWithAppleButton(.signIn) { request in
                                let nonce = randomNonceString()
                                AppleSignInNonceStore.shared.currentNonce = nonce
                                request.requestedScopes = [.fullName, .email]
                                request.nonce = sha256(nonce)
                            } onCompletion: { result in
                                handleAppleSignIn(result)
                            }
                            .signInWithAppleButtonStyle(.white)
                            .frame(height: 52)
                            .cornerRadius(16)
                            .disabled(isLoading)

                            GoogleSignInButton(scheme: .dark, style: .wide, state: isLoading ? .disabled : .normal) {
                                handleGoogleSignIn()
                            }
                            .frame(height: 52)
                            .cornerRadius(16)
                            .disabled(isLoading)
                        }

                        if let errorMessage {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.circle.fill").foregroundColor(.fcError)
                                Text(errorMessage).font(.fcCaption).foregroundColor(.fcError)
                            }
                            .padding(12)
                            .background(Color.fcError.opacity(0.1))
                            .cornerRadius(10)
                        }

                        Button("Maybe Later") { dismiss() }
                            .font(.fcBodyBold)
                            .foregroundColor(.fcTextSecondary)
                            .padding(.top, 4)

                        Text("Continuing keeps your guest nickname and first fit.")
                            .font(.system(size: 11))
                            .foregroundColor(.fcTextSecondary.opacity(0.7))
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }.foregroundColor(.fcTextSecondary)
                }
            }
        }
        .presentationDetents([.medium, .large])
        // The guest just converted to a real account — close the gate.
        .onChange(of: appState.isAuthenticated) { _, authed in
            if authed { dismiss() }
        }
    }

    // MARK: - Apple
    private func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            guard let cred = auth.credential as? ASAuthorizationAppleIDCredential else {
                errorMessage = "Apple Sign In failed. Try again."
                return
            }
            isLoading = true
            errorMessage = nil
            Task {
                do {
                    let user = try await appState.authService.signInWithApple(credential: cred)
                    await ModerationService.syncAcceptanceToFirestore()
                    await MainActor.run {
                        appState.currentUser = user
                        appState.needsProfileSetup = user.requiresProfileSetup
                        appState.isAuthenticated = true
                        appState.isGuest = false
                        appState.analyticsService.track(.signIn)
                    }
                } catch {
                    await MainActor.run { errorMessage = "Apple Sign In failed. Try again." }
                }
                await MainActor.run { isLoading = false }
            }
        case .failure(let error):
            if let asError = error as? ASAuthorizationError, asError.code == .canceled { return }
            errorMessage = "Apple Sign In failed. Try again."
        }
    }

    // MARK: - Google
    private func handleGoogleSignIn() {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first?.rootViewController else {
            errorMessage = "Unable to present sign-in screen."
            return
        }
        isLoading = true
        errorMessage = nil
        Task {
            do {
                let user = try await appState.authService.signInWithGoogle(presentingVC: rootVC)
                await ModerationService.syncAcceptanceToFirestore()
                await MainActor.run {
                    appState.currentUser = user
                    appState.needsProfileSetup = user.requiresProfileSetup
                    appState.isAuthenticated = true
                    appState.isGuest = false
                    appState.analyticsService.track(.signIn)
                }
            } catch {
                await MainActor.run { errorMessage = "Google Sign In failed. Try again." }
            }
            await MainActor.run { isLoading = false }
        }
    }
}
