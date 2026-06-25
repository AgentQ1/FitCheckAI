import SwiftUI
import os
import FirebaseCore
import GoogleSignIn

/// Lightweight launch/runtime diagnostics.
///
/// Writes breadcrumbs through Apple's unified logging system (`os.Logger`) so the
/// launch sequence is visible in Console.app and is captured in any crash report
/// from a device / TestFlight build — WITHOUT shipping an analytics SDK or any PII.
/// Mirrored to stdout in DEBUG so the same breadcrumbs show in the Xcode console.
enum AppLog {
    private static let launchLog = Logger(subsystem: "ai.fitcheck.app", category: "launch")
    private static let crashLog  = Logger(subsystem: "ai.fitcheck.app", category: "crash")
    private static let premiumLog = Logger(subsystem: "ai.fitcheck.app", category: "premium")
    private static let privacyLog = Logger(subsystem: "ai.fitcheck.app", category: "privacy")

    static func launch(_ message: String) {
        launchLog.log("\(message, privacy: .public)")
        #if DEBUG
        print("[Launch] \(message)")
        #endif
    }

    static func premium(_ message: String) {
        premiumLog.log("\(message, privacy: .public)")
        #if DEBUG
        print("[Premium] \(message)")
        #endif
    }

    /// Breadcrumbs for the privacy-sensitive flows (export / delete fit checks /
    /// delete generated images / delete account) so an App Review run leaves an
    /// auditable trail without shipping any PII off-device.
    static func privacy(_ message: String) {
        privacyLog.log("\(message, privacy: .public)")
        #if DEBUG
        print("[Privacy] \(message)")
        #endif
    }

    static func crash(_ message: String) {
        crashLog.fault("\(message, privacy: .public)")
        #if DEBUG
        print("[Crash] \(message)")
        #endif
    }
}

@main
struct FitCheckAIApp: App {
    @StateObject private var appState = AppState()

    init() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        AppLog.launch("FitCheckAIApp.init — \(Bundle.main.bundleIdentifier ?? "?") v\(version)(\(build))")

        // Leave a breadcrumb for any uncaught Objective-C exception. UIKit, Foundation
        // and the Firebase SDKs surface failures as NSExceptions; logging the name +
        // reason + stack here means an otherwise-invisible launch crash is recoverable
        // from the device log / crash report instead of vanishing. (Best-effort: this
        // does not catch Swift fatalError/precondition traps, only ObjC exceptions.)
        NSSetUncaughtExceptionHandler { exception in
            AppLog.crash("Uncaught \(exception.name.rawValue): \(exception.reason ?? "nil")\n"
                + exception.callStackSymbols.joined(separator: "\n"))
        }

        // Configure Firebase exactly once. The guard makes a second configure (e.g. a
        // SwiftUI lifecycle edge that re-inits the App) a no-op instead of the hard
        // "Default app has already been configured" exception.
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
            AppLog.launch("FirebaseApp.configure() completed")
        } else {
            AppLog.launch("FirebaseApp already configured — skipping")
        }

        if let clientID = FirebaseApp.app()?.options.clientID {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
            AppLog.launch("Google Sign-In configured")
        } else {
            // Non-fatal: Apple Sign-In + Guest still work; only Google is unavailable.
            AppLog.launch("⚠️ no Firebase clientID — Google Sign-In not configured")
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

    /// Which top-level destination RootView is currently showing — logged so the
    /// launch trace records exactly how far the app got (splash → onboarding/main).
    private var rootState: String {
        if appState.isLoadingAuth { return "splash" }
        if appState.isAuthenticated && appState.needsProfileSetup { return "profileSetup" }
        if appState.isAuthenticated || appState.isGuest { return "main" }
        return "onboarding"
    }

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
        .onChange(of: rootState, initial: true) { _, state in
            AppLog.launch("root view shown → \(state)")
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
