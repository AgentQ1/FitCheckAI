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

    /// Presents the "Save your style journey" sign-in gate. Shown when a guest tries
    /// a SECOND fit check (or a sign-in-only action). "Maybe Later" just dismisses it
    /// and the guest keeps browsing — it never dead-ends.
    @Published var showGuestSignInGate: Bool = false

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

    /// A real, signed-in Firebase account — NOT a guest and NOT an anonymous
    /// session. Premium is tied to this (see `recomputePremium`): the StoreKit
    /// entitlement is scoped to the device's Apple ID, so without this gate a
    /// guest on a device whose Apple ID owns a subscription would read as premium.
    var hasSignedInAccount: Bool {
        guard let user = Auth.auth().currentUser else { return false }
        return !user.isAnonymous
    }

    /// User-facing Premium phase for the signed-in account: the account gate (Premium is
    /// tied to a signed-in Firebase account) combined with Apple's live entitlement
    /// phase. Every Premium surface (Profile card, status screen) reads this so the
    /// wording can never disagree. `.none` whenever the account isn't entitled (guest,
    /// free, or lapsed all route to the paywall).
    var premiumPhase: StoreKitService.PremiumPhase {
        guard isPremium else { return .none }
        let phase = storeKit.premiumPhase
        // During the brief soft-bridge window (StoreKit reconciling a transient
        // "inactive" read while the Firestore mirror still holds Premium), keep showing
        // an active state rather than flashing "Upgrade to Premium".
        if case .none = phase { return .active(renews: storeKit.expirationDate) }
        return phase
    }

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
        AppLog.launch("AppState.init — installing auth listener + StoreKit")
        startLaunchWatchdog()
        setupAuthListener()
        // StoreKit owns entitlement. Start the transaction listener and recompute
        // Premium whenever Apple's entitlement state changes.
        storeKit.start()
        storeKit.$hasPremium
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.recomputePremium() }
            .store(in: &cancellables)
        // Re-evaluate when StoreKit starts/ends a debounced entitlement recheck so the
        // soft Firestore mirror can bridge the gap without a flicker (see recomputePremium).
        storeKit.$isReconcilingEntitlement
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

    /// The auth-state listener flips `isLoadingAuth` to false within a few hundred ms
    /// (it fires once on registration, even offline). This watchdog is pure insurance:
    /// if anything ever stops that first callback in a constrained review/network
    /// environment, force the splash to dismiss after 6s so the app falls through to
    /// onboarding instead of hanging on the splash forever (which App Review can read
    /// as a crash/hang). A no-op once auth has already resolved.
    private func startLaunchWatchdog() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self, self.isLoadingAuth else { return }
            AppLog.launch("⏱️ launch watchdog fired — auth unresolved after 6s; forcing isLoadingAuth=false")
            self.isLoadingAuth = false
        }
    }

    private func setupAuthListener() {
        authListenerHandle = Auth.auth().addStateDidChangeListener { [weak self] _, firebaseUser in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let firebaseUser {
                    if let user = await self.authService.currentUser() {
                        self.applyUser(user)
                        if firebaseUser.isAnonymous {
                            // Anonymous = a real, usable GUEST session (not a full
                            // account). It can read the Arena/leaderboards, run its one
                            // free fit check, and report/block — but Premium and public
                            // posting stay gated behind a real account.
                            self.isGuest = true
                            self.isAuthenticated = false
                            self.needsProfileSetup = false   // guests never onboard
                            UserDefaults.standard.set(true, forKey: "isGuest")
                        } else {
                            self.isAuthenticated = true
                            self.isGuest = false
                            UserDefaults.standard.removeObject(forKey: "isGuest")
                        }
                    }
                    self.startUserListener(uid: firebaseUser.uid)
                } else {
                    // No Firebase user at all → NOT a usable session. A real guest is
                    // always backed by an anonymous Firebase user (which Firebase
                    // persists across launches), so we must NOT resurrect a guest from a
                    // stale UserDefaults flag — that would drop the app into a guest UI
                    // with no uid, where every Firestore read fails (the old broken state).
                    self.stopUserListener()
                    self.currentUser = nil
                    self.isAuthenticated = false
                    self.isGuest = false
                    UserDefaults.standard.removeObject(forKey: "isGuest")
                }
                self.isLoadingAuth = false
                AppLog.launch("auth resolved — authed=\(self.isAuthenticated) guest=\(self.isGuest) needsSetup=\(self.needsProfileSetup)")
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
        let firebaseUser = Auth.auth().currentUser
        // Premium is tied to a real signed-in Firebase account. The Apple/StoreKit
        // entitlement is scoped to the *device's Apple ID*, not to our account, so a
        // guest / logged-out / anonymous user must NEVER read as premium — even when
        // the device's Apple ID owns an active subscription. Otherwise the paywall
        // claims "Premium already active" for a user who can't even run a fit check.
        let signedIn = (firebaseUser != nil) && !(firebaseUser?.isAnonymous ?? true)
        let firestoreMirror = user?.isPremium ?? false
        // Apple's live entitlement is the source of truth. The ONE exception: while
        // StoreKit is debouncing a possibly-transient "inactive" read
        // (isReconcilingEntitlement), we let the backend's Apple-verified Firestore mirror
        // hold the unlock so the UI doesn't flicker mid-recheck. This is a soft, transient
        // bridge only — once the recheck resolves, isReconcilingEntitlement clears and
        // Apple's verdict alone decides, so a stale mirror can never grant Premium.
        let appleActive = storeKit.hasPremium
            || (storeKit.isReconcilingEntitlement && firestoreMirror)
        let entitled = signedIn && appleActive
        isPremium = entitled
        if entitled, let id = storeKit.activeProductID {
            premiumTier = (id == Config.IAP.yearlyProductID) ? .yearly : .monthly
        } else {
            premiumTier = .free
        }
        let limit = (user?.fitCheckLimit ?? 0) > 0 ? user!.fitCheckLimit : Config.freeChecksPerDay
        dailyChecksRemaining = entitled ? Int.max : max(0, limit - (user?.dailyChecksUsed ?? 0))
        // Full audit trail: every input that decides Premium + the final value.
        // (There is intentionally no persistent local `isPremium` cache — we never
        // store it in UserDefaults/AppStorage, so a stale flag can't grant Premium.)
        print("""
        [AppState] recomputePremium → final isPremium=\(isPremium) tier=\(premiumTier)
          authUID=\(firebaseUser?.uid ?? "<none>") isAnonymous=\(firebaseUser?.isAnonymous ?? false) signedInAccount=\(signedIn) isGuest=\(isGuest)
          storeKitHasPremium=\(storeKit.hasPremium) reconciling=\(storeKit.isReconcilingEntitlement) effectiveAppleActive=\(appleActive) firestoreMirror=\(firestoreMirror)(soft-bridge-only) localCachedPremium=none(no-persistent-cache)
        """)
    }

    // MARK: - Guest (anonymous) session

    private let guestCheckUsedKey = "guest.fitCheckUsed"

    /// True once this guest has spent their one free fit check (device-local mirror of
    /// the server-side `guestFitCheckUsed` flag on the anonymous user doc). Reset when a
    /// fresh anonymous session begins. Reinstall clears it — acceptable per spec.
    var guestFitCheckUsed: Bool { UserDefaults.standard.bool(forKey: guestCheckUsedKey) }

    func markGuestFitCheckUsed() {
        UserDefaults.standard.set(true, forKey: guestCheckUsedKey)
        print("[AppState] guest free fit check consumed")
    }

    /// Enter the app as a GUEST backed by Firebase Anonymous Auth. This gives the guest
    /// a real uid + ID token, so every Firestore read and Cloud Function the app makes
    /// (Home, Arena, leaderboards, the one fit check, report/block) actually works —
    /// without creating a full account. The auth listener seeds the guest's generated
    /// nickname + avatar and flips `isGuest`.
    func continueAsGuest() {
        Task { await signInAsGuest() }
    }

    private func signInAsGuest() async {
        isLoadingAuth = true
        // Fresh anonymous session → fresh server uid, so clear the local one-check flag
        // to match the new uid's server-side allowance.
        UserDefaults.standard.removeObject(forKey: guestCheckUsedKey)
        do {
            try await authService.signInAnonymously()
            analyticsService.track(.signUp)
            // The auth-state listener (above) applies the user + flips isGuest.
        } catch {
            // Without an anonymous Firebase user there is no usable session (all reads
            // would fail), so do NOT enter a broken guest UI. Stay on the sign-in screen;
            // the user can retry. (This only happens if Anonymous Auth is unreachable.)
            print("[AppState] ⚠️ anonymous sign-in failed: \(error.localizedDescription) — staying on sign-in screen")
            isGuest = false
            isLoadingAuth = false
        }
    }

    /// Single entry point for starting a fit check. A guest gets exactly ONE free
    /// check; a second attempt opens the sign-in gate instead of the camera. Everyone
    /// else (and the guest's first check) opens the camera flow.
    func requestFitCheck() {
        if isGuest && guestFitCheckUsed {
            print("[AppState] guest second fit check → presenting sign-in gate")
            showGuestSignInGate = true
            return
        }
        showCheckFlow = true
    }

    func signOut() async {
        stopUserListener()
        await authService.signOut()
        currentUser = nil
        needsProfileSetup = false
        isAuthenticated = false
        isGuest = false
        // Reset the entitlement UI. The StoreKit entitlement itself stays on the
        // device's Apple ID (we never revoke Apple's record), but Premium is gated
        // on a signed-in account, so it must read as false the instant we sign out.
        isPremium = false
        premiumTier = .free
        dailyChecksRemaining = Config.freeChecksPerDay
        streakCount = 0
        UserDefaults.standard.removeObject(forKey: "isGuest")
        print("[AppState] signOut → cleared user + premium UI (isPremium=false). StoreKit entitlement remains on the device Apple ID until another account signs in.")
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
