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
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if appState.isLoadingAuth {
                SplashScreen()
            } else if appState.isAuthenticated || appState.isGuest {
                MainTabView()
            } else {
                OnboardingView()
            }
        }
        .sheet(isPresented: $appState.showPremiumSheet) {
            PremiumView()
                .environmentObject(appState)
        }
    }
}
