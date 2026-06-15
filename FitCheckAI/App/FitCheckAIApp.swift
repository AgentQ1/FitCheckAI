import SwiftUI
import FirebaseCore
import GoogleSignIn

@main
struct FitCheckAIApp: App {
    @StateObject private var appState = AppState()

    init() {
        FirebaseApp.configure()
        if let clientID = FirebaseApp.app()?.options.clientID {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .preferredColorScheme(.light)
                .onOpenURL { url in
                    appState.handleDeepLink(url)
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if appState.isLoadingAuth {
                SplashScreen()
            } else if appState.isAuthenticated && appState.needsProfileSetup {
                ProfileSetupView()
            } else if appState.isAuthenticated || appState.isGuest {
                MainTabView()
            } else {
                OnboardingView()
            }
        }
        // A single premium entry point. Active subscribers get the management
        // screen; everyone else sees the paywall. Every call site that flips
        // `showPremiumSheet` routes through this check, so no entry point can
        // surface the paywall to a premium user.
        .fullScreenCover(isPresented: $appState.showPremiumSheet) {
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
    }
}
