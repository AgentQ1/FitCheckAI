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
        // The single premium entry point. PremiumView self-dismisses for users who
        // are already premium, so no call site can leave the paywall in front of a
        // subscriber. Premium management (billing portal) lives in ProfileView.
        .fullScreenCover(isPresented: $appState.showPremiumSheet) {
            PremiumView()
                .environmentObject(appState)
        }
    }
}
