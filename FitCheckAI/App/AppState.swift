import SwiftUI
import Combine
import FirebaseAuth

@MainActor
final class AppState: ObservableObject {
    // MARK: - Auth
    @Published var isAuthenticated: Bool = false
    @Published var isGuest: Bool = false
    @Published var currentUser: AppUser?
    @Published var isLoadingAuth: Bool = true

    // MARK: - Navigation
    @Published var selectedTab: TabItem = .home
    @Published var showPremiumSheet: Bool = false
    @Published var activeOutfitID: String?

    // MARK: - Premium
    @Published var isPremium: Bool = false
    @Published var premiumTier: SubscriptionTier = .free
    @Published var dailyChecksRemaining: Int = Config.freeChecksPerDay

    // MARK: - Streak
    @Published var streakCount: Int = 0

    // MARK: - Services
    let authService      = AuthService()
    let aiService        = AIService()
    let storageService   = StorageService()
    let analyticsService = AnalyticsService()

    private var authListenerHandle: AuthStateDidChangeListenerHandle?

    init() {
        setupAuthListener()
    }

    deinit {
        if let handle = authListenerHandle {
            Auth.auth().removeStateDidChangeListener(handle)
        }
    }

    private func setupAuthListener() {
        authListenerHandle = Auth.auth().addStateDidChangeListener { [weak self] _, firebaseUser in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if firebaseUser != nil {
                    if let user = await self.authService.currentUser() {
                        self.currentUser = user
                        self.isAuthenticated = true
                        self.isGuest = false
                        self.isPremium = user.subscriptionTier != .free
                        self.premiumTier = user.subscriptionTier
                        self.streakCount = user.streakCount
                        self.dailyChecksRemaining = max(0, Config.freeChecksPerDay - user.dailyChecksUsed)
                    }
                } else {
                    self.currentUser = nil
                    self.isAuthenticated = false
                    self.isGuest = UserDefaults.standard.bool(forKey: "isGuest")
                }
                self.isLoadingAuth = false
            }
        }
    }

    func continueAsGuest() {
        isGuest = true
        isLoadingAuth = false
        UserDefaults.standard.set(true, forKey: "isGuest")
        analyticsService.track(.signUp)
    }

    func signOut() async {
        await authService.signOut()
        currentUser = nil
        isAuthenticated = false
        isGuest = false
        isPremium = false
        premiumTier = .free
        dailyChecksRemaining = Config.freeChecksPerDay
        streakCount = 0
        UserDefaults.standard.removeObject(forKey: "isGuest")
    }

    func refreshUser() async {
        if let user = await authService.currentUser() {
            currentUser = user
            isPremium = user.subscriptionTier != .free
            premiumTier = user.subscriptionTier
            streakCount = user.streakCount
            dailyChecksRemaining = max(0, Config.freeChecksPerDay - user.dailyChecksUsed)
        }
    }
}

enum TabItem: Int, CaseIterable {
    case home, fitCheck, trends, saved, profile

    var icon: String {
        switch self {
        case .home:     return "house.fill"
        case .fitCheck: return "camera.circle.fill"
        case .trends:   return "chart.line.uptrend.xyaxis"
        case .saved:    return "bookmark.fill"
        case .profile:  return "person.fill"
        }
    }

    var label: String {
        switch self {
        case .home:     return "Home"
        case .fitCheck: return "Fit Check"
        case .trends:   return "Trends"
        case .saved:    return "Saved"
        case .profile:  return "Profile"
        }
    }

    var isFAB: Bool { self == .fitCheck }
}
