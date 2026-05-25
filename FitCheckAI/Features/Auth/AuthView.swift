import SwiftUI
import AuthenticationServices
import GoogleSignInSwift
import UIKit

struct AuthView: View {
    @EnvironmentObject var appState: AppState
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var navigateToProfileSetup = false

    var body: some View {
        ZStack {
            Color.fcBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 28) {
                    // Logo
                    ZStack {
                        Circle()
                            .fill(Color.fcAccent.opacity(0.12))
                            .frame(width: 70, height: 70)
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundColor(.fcAccent)
                    }
                    .padding(.top, 40)

                    VStack(spacing: 6) {
                        Text("Welcome to FitCheck.")
                            .font(.fcDisplay)
                            .foregroundColor(.fcTextPrimary)
                        Text("Sign in to start your style journey.")
                            .font(.fcBody)
                            .foregroundColor(.fcTextSecondary)
                    }

                    VStack(spacing: 14) {
                        // Apple Sign-In
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

                        // Google Sign-In
                        GoogleSignInButton(scheme: .dark, style: .wide, state: isLoading ? .disabled : .normal) {
                            handleGoogleSignIn()
                        }
                        .frame(height: 52)
                        .cornerRadius(16)
                        .disabled(isLoading)
                    }

                    // Error
                    if let errorMessage {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundColor(.fcError)
                            Text(errorMessage)
                                .font(.fcCaption)
                                .foregroundColor(.fcError)
                        }
                        .padding(12)
                        .background(Color.fcError.opacity(0.1))
                        .cornerRadius(10)
                    }

                    // Terms
                    Text("By continuing you agree to our Terms & Privacy Policy")
                        .font(.fcCaption)
                        .foregroundColor(Color.fcTextSecondary.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)

                    // Guest option
                    VStack(spacing: 12) {
                        HStack {
                            Rectangle().fill(Color.fcTextSecondary.opacity(0.2)).frame(height: 1)
                            Text("or").font(.fcCaption).foregroundColor(.fcTextSecondary.opacity(0.5))
                                .padding(.horizontal, 12)
                            Rectangle().fill(Color.fcTextSecondary.opacity(0.2)).frame(height: 1)
                        }

                        Button(action: { appState.continueAsGuest() }) {
                            HStack(spacing: 6) {
                                Image(systemName: "person.fill")
                                    .font(.system(size: 13))
                                Text("Continue as Guest")
                                    .font(.system(size: 15, weight: .medium))
                            }
                            .foregroundColor(.fcTextSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.fcSurface)
                            .cornerRadius(16)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(Color.fcTextSecondary.opacity(0.2), lineWidth: 1)
                            )
                        }
                        .buttonStyle(HapticButtonStyle())

                        Text("Guest mode: 3 checks/day · progress not saved")
                            .font(.system(size: 11))
                            .foregroundColor(Color.fcTextSecondary.opacity(0.5))
                    }
                    .padding(.bottom, 40)
                }
                .padding(.horizontal, 24)
            }
        }
        .navigationBarBackButtonHidden(false)
        .navigationDestination(isPresented: $navigateToProfileSetup) {
            ProfileSetupView()
        }
    }

    // MARK: - Apple Sign-In
    private func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            guard let cred = auth.credential as? ASAuthorizationAppleIDCredential else { return }
            isLoading = true
            errorMessage = nil
            Task {
                do {
                    let user = try await appState.authService.signInWithApple(credential: cred)
                    await MainActor.run {
                        appState.currentUser = user
                        appState.isAuthenticated = true
                        appState.analyticsService.track(.signIn)
                        if user.displayName == nil || user.displayName?.isEmpty == true {
                            navigateToProfileSetup = true
                        }
                    }
                } catch {
                    await MainActor.run { errorMessage = "Apple Sign In failed. Try again." }
                }
                await MainActor.run { isLoading = false }
            }
        case .failure:
            errorMessage = "Apple Sign In was cancelled."
        }
    }

    // MARK: - Google Sign-In
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
                await MainActor.run {
                    appState.currentUser = user
                    appState.isAuthenticated = true
                    appState.analyticsService.track(.signIn)
                }
            } catch {
                await MainActor.run { errorMessage = "Google Sign In failed. Try again." }
            }
            await MainActor.run { isLoading = false }
        }
    }
}

#Preview {
    NavigationStack { AuthView() }
        .environmentObject(AppState())
}
