import SwiftUI
import Combine
import FirebaseAuth
import FirebaseFirestore

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

    // MARK: - Stripe Checkout
    @Published var checkoutURL: URL?
    @Published var showCheckout: Bool = false
    @Published var showBillingPortal: Bool = false
    @Published var billingPortalURL: URL?
    @Published var isCheckingSubscription: Bool = false

    // MARK: - Services
    let authService      = AuthService()
    let aiService        = AIService()
    let storageService   = StorageService()
    let analyticsService = AnalyticsService()

    private var authListenerHandle: AuthStateDidChangeListenerHandle?
    private var userListener: ListenerRegistration?

    init() {
        setupAuthListener()
    }

    deinit {
        if let handle = authListenerHandle {
            Auth.auth().removeStateDidChangeListener(handle)
        }
        userListener?.remove()
    }

    private func setupAuthListener() {
        authListenerHandle = Auth.auth().addStateDidChangeListener { [weak self] _, firebaseUser in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let firebaseUser {
                    if let user = await self.authService.currentUser() {
                        self.applyUser(user)
                        self.isAuthenticated = true
                        self.isGuest = false
                    }
                    self.startUserListener(uid: firebaseUser.uid)
                } else {
                    self.stopUserListener()
                    self.currentUser = nil
                    self.isAuthenticated = false
                    self.isGuest = UserDefaults.standard.bool(forKey: "isGuest")
                }
                self.isLoadingAuth = false
            }
        }
    }

    // Real-time Firestore listener — picks up webhook-driven subscription changes
    private func startUserListener(uid: String) {
        userListener?.remove()
        let db = Firestore.firestore()
        userListener = db.collection("users").document(uid).addSnapshotListener { [weak self] snapshot, error in
            guard let self, let snapshot, snapshot.exists else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let user = try? snapshot.data(as: AppUser.self) {
                    self.applyUser(user)
                    // If we were waiting for subscription confirmation, check now
                    if self.isCheckingSubscription && user.isPremium {
                        self.isCheckingSubscription = false
                        self.showCheckout = false
                    }
                }
            }
        }
    }

    private func stopUserListener() {
        userListener?.remove()
        userListener = nil
    }

    private func applyUser(_ user: AppUser) {
        currentUser = user
        isPremium = user.isPremium
        premiumTier = user.subscriptionTier
        streakCount = user.streakCount
        let limit = user.fitCheckLimit > 0 ? user.fitCheckLimit : Config.freeChecksPerDay
        dailyChecksRemaining = user.isPremium ? Int.max : max(0, limit - user.dailyChecksUsed)
    }

    func continueAsGuest() {
        isGuest = true
        isLoadingAuth = false
        UserDefaults.standard.set(true, forKey: "isGuest")
        analyticsService.track(.signUp)
    }

    func signOut() async {
        stopUserListener()
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
            applyUser(user)
        }
    }

    // MARK: - Deep Link Handler
    func handleDeepLink(_ url: URL) {
        guard url.scheme == "fitcheckai" else { return }
        let host = url.host ?? ""
        switch host {
        case "stripe":
            let path = url.path
            if path.hasPrefix("/success") {
                print("[AppState] Stripe checkout success — waiting for webhook...")
                showCheckout = false
                isCheckingSubscription = true
                // Firestore listener will flip isCheckingSubscription when isPremium becomes true
                // Safety timeout after 15s
                Task {
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    await MainActor.run { self.isCheckingSubscription = false }
                }
            } else if path.hasPrefix("/cancel") {
                print("[AppState] Stripe checkout cancelled")
                showCheckout = false
            }
        default:
            break
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
