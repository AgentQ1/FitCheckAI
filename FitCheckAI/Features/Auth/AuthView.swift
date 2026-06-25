import SwiftUI
import AuthenticationServices
import GoogleSignInSwift
import UIKit

struct AuthView: View {
    @EnvironmentObject var appState: AppState
    @State private var isLoading = false
    @State private var errorMessage: String?

    // MARK: - Terms / EULA gate (Apple Guideline 1.2)
    // The user MUST agree to the Terms of Use + EULA (which state a zero-tolerance
    // policy for objectionable content / abusive users) before ANY account creation
    // or sign-in — Apple Sign-In, Google Sign-In, or Guest. The agreement is recorded
    // locally the instant it's ticked and mirrored to the user doc after login.
    @State private var agreedToTerms = ModerationService.hasAcceptedCurrentTerms
    @State private var showToS = false
    @State private var showPrivacy = false
    @State private var showEULA = false
    @State private var showAgreementHint = false

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

                    // Terms / EULA agreement gate — REQUIRED before any sign-in.
                    agreementGate

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
                        .disabled(isLoading || !agreedToTerms)

                        // Google Sign-In
                        GoogleSignInButton(scheme: .dark, style: .wide, state: (isLoading || !agreedToTerms) ? .disabled : .normal) {
                            handleGoogleSignIn()
                        }
                        .frame(height: 52)
                        .cornerRadius(16)
                        .disabled(isLoading || !agreedToTerms)
                    }
                    // Block the native Apple/Google button taps until the box is ticked,
                    // and nudge the user to the agreement instead of silently no-op'ing.
                    .opacity(agreedToTerms ? 1 : 0.5)
                    .overlay {
                        if !agreedToTerms {
                            Color.fcBackground.opacity(0.001)
                                .contentShape(Rectangle())
                                .onTapGesture { showAgreementHint = true }
                        }
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

                    // Guest option
                    VStack(spacing: 12) {
                        HStack {
                            Rectangle().fill(Color.fcTextSecondary.opacity(0.2)).frame(height: 1)
                            Text("or").font(.fcCaption).foregroundColor(.fcTextSecondary.opacity(0.5))
                                .padding(.horizontal, 12)
                            Rectangle().fill(Color.fcTextSecondary.opacity(0.2)).frame(height: 1)
                        }

                        Button(action: { continueAsGuest() }) {
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
                        .disabled(!agreedToTerms)
                        .opacity(agreedToTerms ? 1 : 0.5)

                        Text("Guest mode: 1 free fit check · browse the Arena · no account needed")
                            .font(.system(size: 11))
                            .foregroundColor(Color.fcTextSecondary.opacity(0.5))
                            .multilineTextAlignment(.center)
                    }
                    .padding(.bottom, 40)
                }
                .padding(.horizontal, 24)
            }
        }
        .navigationBarBackButtonHidden(false)
        .sheet(isPresented: $showToS) { NavigationStack { TermsOfServiceView() } }
        .sheet(isPresented: $showPrivacy) { NavigationStack { PrivacyPolicyView() } }
        .sheet(isPresented: $showEULA) { NavigationStack { EULAView() } }
        .alert("Agree to continue", isPresented: $showAgreementHint) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Please review and accept the Terms of Use and EULA to start using FitCheck.")
        }
    }

    // MARK: - Terms / EULA agreement gate

    /// The required agreement row. Ticking the box records local acceptance of the
    /// current Terms version; the three sign-in paths stay disabled until it's on.
    private var agreementGate: some View {
        VStack(spacing: 10) {
            Button {
                agreedToTerms.toggle()
                if agreedToTerms {
                    ModerationService.recordLocalAcceptance()
                }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: agreedToTerms ? "checkmark.square.fill" : "square")
                        .font(.system(size: 20))
                        .foregroundColor(agreedToTerms ? .fcAccent : .fcTextSecondary)
                    Text("I agree to the Terms of Use and EULA, and understand FitCheck has zero tolerance for objectionable content or abusive users.")
                        .font(.fcCaption)
                        .foregroundColor(.fcTextPrimary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)

            HStack(spacing: 6) {
                Button("Terms of Use") { showToS = true }
                Text("·").foregroundColor(.fcTextSecondary.opacity(0.5))
                Button("EULA") { showEULA = true }
                Text("·").foregroundColor(.fcTextSecondary.opacity(0.5))
                Button("Privacy") { showPrivacy = true }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.fcAccent)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(Color.fcSurface)
        .cornerRadius(14)
    }

    /// Guest entry — only reachable once the agreement box is ticked. Mirrors the
    /// acceptance locally (guests have no Firestore doc to write to).
    private func continueAsGuest() {
        guard agreedToTerms else { showAgreementHint = true; return }
        ModerationService.recordLocalAcceptance()
        appState.continueAsGuest()
    }

    // MARK: - Apple Sign-In
    private func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            guard let cred = auth.credential as? ASAuthorizationAppleIDCredential else {
                print("[AppleSignIn] credential was not an ASAuthorizationAppleIDCredential")
                errorMessage = "Apple Sign In failed. Try again."
                return
            }
            print("[AppleSignIn] Apple credential received (user=\(cred.user), hasToken=\(cred.identityToken != nil), hasName=\(cred.fullName != nil), email=\(cred.email ?? "<nil>"))")
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
                        appState.analyticsService.track(.signIn)
                    }
                } catch {
                    print("[AppleSignIn] Firebase sign-in error: \(error.localizedDescription)")
                    await MainActor.run { errorMessage = "Apple Sign In failed. Try again." }
                }
                await MainActor.run { isLoading = false }
            }
        case .failure(let error):
            // A user-initiated cancel is not an error — silently dismiss without an alert.
            if let asError = error as? ASAuthorizationError {
                switch asError.code {
                case .canceled:
                    print("[AppleSignIn] cancelled by user")
                    return
                case .unknown:
                    // Often a simulator/no-Apple-ID case; surface a gentle hint.
                    print("[AppleSignIn] ASAuthorizationError.unknown: \(asError.localizedDescription)")
                    errorMessage = "Apple Sign In is unavailable. Make sure you're signed into an Apple ID."
                    return
                default:
                    break
                }
            }
            print("[AppleSignIn] authorization failed: \(error.localizedDescription)")
            errorMessage = "Apple Sign In failed. Try again."
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
                await ModerationService.syncAcceptanceToFirestore()
                await MainActor.run {
                    appState.currentUser = user
                    appState.needsProfileSetup = user.requiresProfileSetup
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
