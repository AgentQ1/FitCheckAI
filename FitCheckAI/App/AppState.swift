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
    // StoreKit 2 entitlement is the source of truth. The Firestore `isPremium` flag is
    // the backend's Apple-verified mirror (written by syncAppleSubscription) and is only
    // used as a fast-path fallback before the local entitlement resolves.
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
    let storeKit         = StoreKitService()
    private var cancellables = Set<AnyCancellable>()

    private var authListenerHandle: AuthStateDidChangeListenerHandle?
    private var userListener: ListenerRegistration?

    init() {
        setupAuthListener()
        // StoreKit owns entitlement. Start the transaction listener and recompute
        // Premium whenever Apple's entitlement state changes.
        storeKit.start()
        storeKit.$hasPremium
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.recomputePremium() }
            .store(in: &cancellables)
        // After the backend mirrors the Apple entitlement into Firestore, reload the
        // AuthService user so the persisted premium fields flow back into AppState.
        storeKit.onEntitlementSynced = { [weak self] in
            print("[AppState] backend confirmed premium — refreshing AuthService user")
            await self?.refreshUser()
        }
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
                // Lenient fallback so a partial/legacy doc still updates state instead
                // of silently dropping the snapshot (which left Profile stale).
                let user = (try? snapshot.data(as: AppUser.self))
                    ?? snapshot.data().map { AppUser(firestoreData: $0, uid: snapshot.documentID) }
                if let user {
                    self.applyUser(user)
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
        streakCount = user.streakCount
        // Keep the local Arena block list in sync with the durable Firestore list so
        // a blocked user's fits/comments stay hidden on every device.
        BlockedUsers.shared.hydrate(user.blockedUserIDs ?? [])
        recomputePremium()
    }

    /// Persist the user's public Arena/leaderboard opt-in to Firestore and refresh
    /// local state. Public participation is OPT-IN — nothing is published until the
    /// user turns this on. `isPublic` isn't a rules-protected field, so the client
    /// may write it on its own user doc.
    @discardableResult
    func updateArenaVisibility(_ isPublic: Bool) async -> Bool {
        guard let uid = Auth.auth().currentUser?.uid else { return false }
        do {
            try await Firestore.firestore().collection("users").document(uid)
                .setData(["isPublic": isPublic], merge: true)
            await refreshUser()
            return true
        } catch {
            print("[AppState] updateArenaVisibility failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Premium on iOS is gated **only** by a valid Apple StoreKit entitlement — Apple
    /// is the single source of truth. The Firestore `isPremium` mirror (and any legacy
    /// Stripe value still sitting in the doc) is intentionally NOT used to unlock the
    /// app, so a stale flag can never grant Premium. The backend mirror exists purely
    /// so server-side rate limits match what StoreKit unlocked on-device.
    private func recomputePremium() {
        let user = currentUser
        let appleActive = storeKit.hasPremium
        isPremium = appleActive
        if appleActive, let id = storeKit.activeProductID {
            premiumTier = (id == Config.IAP.yearlyProductID) ? .yearly : .monthly
        } else {
            premiumTier = .free
        }
        let limit = (user?.fitCheckLimit ?? 0) > 0 ? user!.fitCheckLimit : Config.freeChecksPerDay
        dailyChecksRemaining = appleActive ? Int.max : max(0, limit - (user?.dailyChecksUsed ?? 0))
        let firestoreMirror = user?.isPremium ?? false
        print("[AppState] recomputePremium → isPremium=\(isPremium) source=\(appleActive ? "apple-storekit" : "free") | appleEntitlement=\(appleActive) firestoreMirror=\(firestoreMirror)(ignored-for-unlock) tier=\(premiumTier)")
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
    /// The app's `fitcheckai://` URL scheme handler. Premium now runs entirely
    /// through StoreKit (no web redirect), so there are currently no in-app
    /// deep-link routes — kept as the entry point for future universal links.
    func handleDeepLink(_ url: URL) {
        guard url.scheme == "fitcheckai" else { return }
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
