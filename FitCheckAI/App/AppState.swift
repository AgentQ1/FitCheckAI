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

    /// True when a signed-in account still needs to finish onboarding
    /// (ProfileSetupView). RootView shows the setup flow instead of the main app
    /// while this is set. Cleared once ProfileSetupView persists the user's input.
    @Published var needsProfileSetup: Bool = false

    // MARK: - Navigation
    @Published var selectedTab: TabItem = .home
    @Published var showPremiumSheet: Bool = false
    @Published var showCheckFlow: Bool = false
    @Published var activeOutfitID: String?

    /// When true, the floating CustomTabBar hides itself. Detail screens that are
    /// pushed onto a NavigationStack (History, Trends detail, etc.) should set this
    /// in onAppear and clear it in onDisappear so the tab bar doesn't overlap them.
    @Published var hideTabBar: Bool = false

    /// Set by ResultView when the user taps "History" — HomeView observes this
    /// and pushes HistoryView once the CheckFlow fullScreenCover finishes
    /// dismissing.
    @Published var pendingHistoryNav: Bool = false

    /// Bumped after each completed analysis (the backend has already written the
    /// new weekly-leaderboard standing by then). HomeView's "This Week's Trend"
    /// preview watches this and reloads, so a fresh score appears without the
    /// user pulling to refresh.
    @Published var weeklyTrendRefreshToken: Int = 0

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
    @Published var subscriptionVerificationError: String?
    /// Last Stripe Checkout Session id seen via deep link or onDismiss. Lets
    /// "Check Subscription Status" re-verify the exact session instead of just
    /// polling the user doc.
    @Published var lastCheckoutSessionId: String?
    private var verificationTask: Task<Void, Never>?

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
        needsProfileSetup = user.requiresProfileSetup
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
        needsProfileSetup = false
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
                let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
                let sessionId = comps?.queryItems?.first(where: { $0.name == "session_id" })?.value
                print("[AppState] Stripe checkout success deep link sessionId=\(sessionId ?? "<missing>")")
                showCheckout = false
                lastCheckoutSessionId = sessionId
                startSubscriptionVerification(sessionId: sessionId)
            } else if path.hasPrefix("/cancel") {
                print("[AppState] Stripe checkout cancelled")
                showCheckout = false
                isCheckingSubscription = false
            }
        default:
            break
        }
    }

    /// Kick off the post-checkout verification flow. Calls verifyCheckoutSession
    /// (authoritative when the webhook hasn't fired yet) and then waits up to
    /// the configured timeout for the Firestore listener to surface premium.
    /// Always clears `isCheckingSubscription` — the UI never sticks.
    func startSubscriptionVerification(sessionId: String?) {
        verificationTask?.cancel()
        isCheckingSubscription = true
        subscriptionVerificationError = nil
        let id = sessionId ?? lastCheckoutSessionId
        verificationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Hard cap so we never sit on "Confirming payment…" forever.
            let timeout: TimeInterval = 10
            let deadline = Date().addingTimeInterval(timeout)

            // 1) Try the verify endpoint first (works even if webhook is dead).
            if let id, !id.isEmpty {
                let ok = await self.verifyCheckoutSession(sessionId: id)
                if Task.isCancelled { return }
                if ok {
                    self.isCheckingSubscription = false
                    self.subscriptionVerificationError = nil
                    return
                }
            }

            // 2) Fall back to polling the user doc (the webhook may land any moment).
            while Date() < deadline {
                if Task.isCancelled { return }
                await self.refreshUser()
                if self.isPremium {
                    self.isCheckingSubscription = false
                    self.subscriptionVerificationError = nil
                    return
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }

            if Task.isCancelled { return }
            self.isCheckingSubscription = false
            if !self.isPremium {
                self.subscriptionVerificationError = id == nil
                    ? "We couldn't confirm your subscription. Tap 'Check Subscription Status' or contact support if charged."
                    : "Payment received but activation is taking longer than expected. Tap 'Check Subscription Status'."
            }
        }
    }

    /// Hits verifyCheckoutSession. Returns true iff the backend confirms the
    /// user is now premium (so the caller can stop polling immediately).
    private func verifyCheckoutSession(sessionId: String) async -> Bool {
        guard let user = Auth.auth().currentUser else { return false }
        do {
            let token = try await user.getIDToken()
            var req = URLRequest(url: URL(string: Config.API.verifyCheckoutSession)!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.timeoutInterval = 8
            req.httpBody = try JSONSerialization.data(withJSONObject: ["sessionId": sessionId])

            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status != 200 {
                let decoded = try? JSONDecoder().decode([String: String].self, from: data)
                print("[AppState] verifyCheckoutSession failed status=\(status) body=\(decoded ?? [:])")
                self.subscriptionVerificationError = decoded?["message"] ?? "Verification failed (HTTP \(status))."
                return false
            }
            struct VerifyResponse: Decodable {
                let isPremium: Bool
                let subscriptionStatus: String?
            }
            let body = try JSONDecoder().decode(VerifyResponse.self, from: data)
            print("[AppState] verifyCheckoutSession isPremium=\(body.isPremium) status=\(body.subscriptionStatus ?? "?")")
            // Refresh the in-memory user so the UI flips before the Firestore snapshot lands.
            await self.refreshUser()
            return body.isPremium || self.isPremium
        } catch {
            print("[AppState] verifyCheckoutSession network error: \(error)")
            self.subscriptionVerificationError = "Network error confirming your subscription."
            return false
        }
    }
}

enum TabItem: Int, CaseIterable {
    case home, fitCheck, trends, saved, profile, arena

    var icon: String {
        switch self {
        case .home:     return "house.fill"
        case .fitCheck: return "camera.circle.fill"
        case .trends:   return "chart.line.uptrend.xyaxis"
        case .saved:    return "bookmark.fill"
        case .profile:  return "person.fill"
        case .arena:    return "flame.fill"
        }
    }

    var label: String {
        switch self {
        case .home:     return "Home"
        case .fitCheck: return "Fit Check"
        case .trends:   return "Trends"
        case .saved:    return "Saved"
        case .profile:  return "Profile"
        case .arena:    return "Arena"
        }
    }

    var isFAB: Bool { self == .fitCheck }
}
