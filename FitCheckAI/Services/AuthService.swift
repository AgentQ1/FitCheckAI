import Foundation
import AuthenticationServices
import CryptoKit
import FirebaseAuth
import FirebaseFirestore
import GoogleSignIn
import UIKit

// MARK: - Auth Errors
enum AuthError: LocalizedError {
    case invalidCredentials
    case emailAlreadyInUse
    case weakPassword
    case networkError
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:  return "Sign in failed. Please try again."
        case .emailAlreadyInUse:   return "An account with this email already exists."
        case .weakPassword:        return "Use 8+ characters for better security."
        case .networkError:        return "Connection issue. Try again."
        case .unknown(let msg):    return msg
        }
    }
}

// MARK: - Auth Service
final class AuthService {
    private let db = Firestore.firestore()

    // MARK: - Anonymous (Guest)

    /// Start a real, usable GUEST session backed by Firebase Anonymous Auth. The guest
    /// gets a uid + ID token, so Firestore reads and Cloud Functions work — but no PII
    /// is collected. The auth-state listener then seeds the guest's generated identity
    /// via `currentUser()` → `repairUserDocument`.
    func signInAnonymously() async throws {
        let result = try await Auth.auth().signInAnonymously()
        print("[AuthService] anonymous (guest) session started uid=\(result.user.uid)")
        // Eagerly create the guest doc with its generated nickname/avatar so the rest of
        // the app has a profile immediately (the listener also calls currentUser()).
        await repairUserDocument(firebaseUser: result.user)
    }

    /// Sign in with a federated credential, MERGING a guest (anonymous) session into it
    /// when one is active so the guest's uid — and therefore their nickname, avatar, and
    /// first fit check — are preserved (account conversion, Apple Guideline 10/data
    /// continuity). Falls back to a plain sign-in when the credential already belongs to
    /// another account.
    private func signInOrLink(with credential: AuthCredential) async throws -> AuthDataResult {
        if let current = Auth.auth().currentUser, current.isAnonymous {
            do {
                let result = try await current.link(with: credential)
                print("[AuthService] guest LINKED → permanent account (uid preserved=\(result.user.uid))")
                return result
            } catch let error as NSError {
                if error.code == AuthErrorCode.credentialAlreadyInUse.rawValue {
                    // The Apple/Google account already exists — sign into it instead.
                    // The guest's anonymous doc is simply abandoned (no duplicate broken
                    // profile is created because we switch to the existing uid).
                    let updated = error.userInfo[AuthErrorUserInfoUpdatedCredentialKey] as? AuthCredential
                    print("[AuthService] link failed (credential already in use) → signing into existing account")
                    return try await Auth.auth().signIn(with: updated ?? credential)
                }
                throw error
            }
        }
        return try await Auth.auth().signIn(with: credential)
    }

    func currentUser() async -> AppUser? {
        guard let firebaseUser = Auth.auth().currentUser else { return nil }
        print("[AuthService] login uid=\(firebaseUser.uid) email=\(firebaseUser.email ?? "<nil>")")
        // Self-heal first: guarantees the doc exists with every field the app reads,
        // so a legacy/partial account (e.g. created before a field was added) loads
        // correctly on login and session restore instead of decoding to nil.
        await repairUserDocument(firebaseUser: firebaseUser)
        return await fetchFirestoreUser(uid: firebaseUser.uid)
    }

    /// Defensive repair: ensures `users/{uid}` exists and carries every field the app
    /// depends on. Merges defaults ONLY for fields that are currently missing — it
    /// never overwrites an existing value, so a name/photo the user set in Edit Profile
    /// always survives. Runs on every auth state change (login + session restore).
    private func repairUserDocument(firebaseUser: User) async {
        let uid = firebaseUser.uid
        let ref = db.collection("users").document(uid)
        let snapshot = try? await ref.getDocument()
        let exists = snapshot?.exists ?? false
        let existing = snapshot?.data() ?? [:]
        print("[AuthService] user doc exists? \(exists) uid=\(uid)")

        var fill: [String: Any] = [:]
        func ensure(_ key: String, _ value: @autoclosure () -> Any) {
            if existing[key] == nil { fill[key] = value() }
        }
        ensure("uid", uid)
        ensure("email", firebaseUser.email ?? "")
        ensure("provider", firebaseUser.providerData.first?.providerID ?? "unknown")
        ensure("stylePreferences", [String]())
        ensure("defaultStyleGoal", "gen_z")
        ensure("subscriptionTier", SubscriptionTier.free.rawValue)
        ensure("dailyChecksUsed", 0)
        ensure("dailyChecksResetAt", FieldValue.serverTimestamp())
        ensure("streakCount", 0)
        ensure("photoRetentionDays", 7)
        ensure("totalFitChecks", 0)
        ensure("averageScore", 0.0)
        ensure("bestScore", 0.0)
        ensure("savedLooksCount", 0)
        ensure("isPremium", false)
        ensure("subscriptionStatus", "none")
        ensure("fitCheckLimit", Config.freeChecksPerDay)
        // Public Arena/leaderboard participation is OPT-IN — new accounts start
        // private and only publish after the user explicitly turns it on.
        ensure("isPublic", false)
        ensure("createdAt", FieldValue.serverTimestamp())
        ensure("lastLoginAt", FieldValue.serverTimestamp())

        // Seed displayName ONLY when absent. A masked Apple relay email is NEVER shown
        // as a name; guests / masked-email / nameless accounts get a friendly generated
        // nickname (e.g. "Velvet Panda") so no profile is ever blank.
        let hasName = (existing["displayName"] as? String)?.isEmpty == false
        if !hasName {
            if let n = firebaseUser.displayName, !n.isEmpty, !GuestIdentity.isMaskedAppleEmail(n) {
                fill["displayName"] = n
            } else if let email = firebaseUser.email, !email.isEmpty, !GuestIdentity.isMaskedAppleEmail(email) {
                fill["displayName"] = String(email.prefix(while: { $0 != "@" }))
            } else {
                fill["displayName"] = GuestIdentity.nickname(seed: uid)
            }
        }
        // Seed photo from the provider only when absent (never clobber an uploaded one).
        let hasPhoto = (existing["photoURL"] as? String)?.isEmpty == false
        if !hasPhoto, let p = firebaseUser.photoURL?.absoluteString {
            fill["photoURL"] = p
            fill["avatarURL"] = p
        }
        // Deterministic generated-avatar fallback (gradient + animal emoji), stored so
        // the public mirror / leaderboards can render it for users without a photo.
        if existing["avatarEmoji"] == nil { fill["avatarEmoji"] = GuestIdentity.avatarEmoji(seed: uid) }
        if existing["avatarColor"] == nil { fill["avatarColor"] = GuestIdentity.gradientHex(seed: uid).0 }
        // Missing onboarding flag: guests never onboard; a brand-new full account must;
        // an existing one is treated as already set up so returning users aren't re-sent.
        if existing["profileSetupComplete"] == nil {
            fill["profileSetupComplete"] = firebaseUser.isAnonymous ? true : (exists ? true : false)
        }

        // Firestore rules forbid client updates that touch payment/limit/arena fields
        // (only the backend webhook + Arena functions may write them). On an EXISTING
        // doc the merge is an `update`, so including any of these keys makes Firestore
        // reject the whole write atomically — silently dropping even safe repairs like
        // `profileSetupComplete`. So strip them when the doc already exists; a missing
        // `isPremium`/`subscriptionStatus`/`fitCheckLimit` already reads as free
        // everywhere. On a brand-new doc the write is a `create`, which rules allow in
        // full, so we keep the defaults there.
        if exists {
            let backendOnlyKeys: Set<String> = [
                "isPremium", "subscriptionStatus", "currentPeriodEnd", "planName",
                "fitCheckLimit", "subscriptionTier", "arenaPostsToday",
                "lastArenaPostDate", "peerRatingsGiven", "peerRatingsReceived"
            ]
            for key in backendOnlyKeys { fill[key] = nil }
        }

        guard !fill.isEmpty else {
            print("[AuthService] repaired missing fields? none — doc complete")
            return
        }
        fill["updatedAt"] = FieldValue.serverTimestamp()
        print("[AuthService] repaired missing fields? \(fill.keys.sorted())")
        try? await ref.setData(fill, merge: true)

        // Keep the public mirror safe/fresh for leaderboards.
        let name = (existing["displayName"] as? String) ?? (fill["displayName"] as? String)
        let photo = (existing["photoURL"] as? String) ?? (fill["photoURL"] as? String)
        await PublicProfileService.write(uid: uid, displayName: name, photoURL: photo)
    }

    // MARK: - Apple Sign-In
    func signInWithApple(credential: ASAuthorizationAppleIDCredential) async throws -> AppUser {
        print("[AuthService] Apple auth started")
        guard let identityToken = credential.identityToken,
              let tokenString = String(data: identityToken, encoding: .utf8) else {
            print("[AuthService] Apple Sign In FAILED — identity token missing")
            throw AuthError.unknown("Apple Sign In token unavailable.")
        }

        // Retrieve the raw nonce stored in AuthView before the Apple request.
        // A mismatch/absence means the request and response are out of sync — fail loudly.
        guard let rawNonce = AppleSignInNonceStore.shared.currentNonce else {
            print("[AuthService] Apple Sign In FAILED — nonce missing/mismatch")
            throw AuthError.unknown("Missing nonce for Apple Sign In.")
        }

        let firebaseCredential = OAuthProvider.appleCredential(
            withIDToken: tokenString,
            rawNonce: rawNonce,
            fullName: credential.fullName
        )

        print("[AuthService] Firebase sign-in started (provider=apple.com)")
        let authResult: AuthDataResult
        do {
            authResult = try await signInOrLink(with: firebaseCredential)
        } catch {
            print("[AuthService] Firebase sign-in ERROR: \(error.localizedDescription)")
            throw error
        }
        // Clear the one-shot nonce so a stale value can't leak into a later request.
        AppleSignInNonceStore.shared.currentNonce = nil
        print("[AuthService] Firebase sign-in success uid=\(authResult.user.uid)")

        // Apple only returns the full name on the FIRST authorization for this app.
        // On every later login fullName is nil, so we fall back to the name already
        // saved in Firestore (resolved inside upsertFirestoreUser) rather than wiping it.
        let name = credential.fullName.flatMap {
            [$0.givenName, $0.familyName].compactMap { $0 }.joined(separator: " ")
        }.flatMap { $0.isEmpty ? nil : $0 }

        return try await upsertFirestoreUser(
            firebaseUser: authResult.user,
            provider: "apple",
            overrideName: name
        )
    }

    // MARK: - Google Sign-In
    func signInWithGoogle(presentingVC: UIViewController) async throws -> AppUser {
        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presentingVC)
        guard let idToken = result.user.idToken?.tokenString else {
            throw AuthError.unknown("Google ID token unavailable.")
        }
        let accessToken = result.user.accessToken.tokenString
        let firebaseCredential = GoogleAuthProvider.credential(
            withIDToken: idToken,
            accessToken: accessToken
        )
        let authResult = try await signInOrLink(with: firebaseCredential)
        return try await upsertFirestoreUser(
            firebaseUser: authResult.user,
            provider: "google",
            overrideName: nil
        )
    }

    // MARK: - Sign Out
    func signOut() async {
        try? Auth.auth().signOut()
        GIDSignIn.sharedInstance.signOut()
    }

    // MARK: - Private: Upsert Firestore User
    @discardableResult
    private func upsertFirestoreUser(
        firebaseUser: User,
        provider: String,
        overrideName: String?
    ) async throws -> AppUser {
        let uid = firebaseUser.uid
        let ref = db.collection("users").document(uid)

        let snapshot = try? await ref.getDocument()
        let isNew = !(snapshot?.exists ?? false)

        var data: [String: Any] = [
            "uid": uid,
            "email": firebaseUser.email ?? "",
            "provider": provider,
            "lastLoginAt": FieldValue.serverTimestamp(),
        ]

        if isNew {
            data["createdAt"] = FieldValue.serverTimestamp()
            data["subscriptionTier"] = SubscriptionTier.free.rawValue
            data["dailyChecksUsed"] = 0
            data["dailyChecksResetAt"] = FieldValue.serverTimestamp()
            data["streakCount"] = 0
            data["stylePreferences"] = [String]()
            data["defaultStyleGoal"] = "gen_z"
            data["photoRetentionDays"] = 7
            data["totalFitChecks"] = 0
            data["averageScore"] = 0.0
            data["bestScore"] = 0.0
            data["savedLooksCount"] = 0
            // Premium defaults (the backend flips these after verifying an Apple purchase)
            data["isPremium"] = false
            data["subscriptionStatus"] = "none"
            data["fitCheckLimit"] = Config.freeChecksPerDay
            // Brand-new accounts must complete onboarding (ProfileSetupView).
            data["profileSetupComplete"] = false
        }

        // Display name resolution. The user's own edits live in Firestore and are the
        // source of truth — the auth provider resends its original name on every login,
        // so it must NEVER win over a name the user already saved. The ONE exception is a
        // converting guest: their saved name is an auto-generated nickname, which a real
        // provider name (or Apple's first-sign-in name) SHOULD upgrade.
        // Order: explicit override (Apple first sign-in) → a real saved name → provider
        // name (upgrades a guest nickname) → keep the nickname / generate one.
        let existingName = (snapshot?.data()?["displayName"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
        let existingIsGenerated = existingName == GuestIdentity.nickname(seed: uid)
        let providerName = firebaseUser.displayName
            .flatMap { GuestIdentity.isMaskedAppleEmail($0) ? nil : ($0.isEmpty ? nil : $0) }
        let resolvedName: String
        if let overrideName, !overrideName.isEmpty {
            resolvedName = overrideName
        } else if let existingName, !existingIsGenerated {
            resolvedName = existingName
        } else if let providerName {
            resolvedName = providerName
        } else {
            resolvedName = existingName ?? GuestIdentity.nickname(seed: uid)
        }
        data["displayName"] = resolvedName
        // Generated-avatar fallback fields (seeded once; never clobbers a real photo).
        if (snapshot?.data()?["avatarEmoji"] as? String) == nil {
            data["avatarEmoji"] = GuestIdentity.avatarEmoji(seed: uid)
        }
        if (snapshot?.data()?["avatarColor"] as? String) == nil {
            data["avatarColor"] = GuestIdentity.gradientHex(seed: uid).0
        }

        // Photo URL: only seed from the auth provider when the user has no photo
        // saved yet. A profile photo the user uploaded (stored in Firestore) must
        // survive subsequent logins, so we never overwrite a non-empty value.
        let existingPhoto = snapshot?.data()?["photoURL"] as? String ?? ""
        if existingPhoto.isEmpty, let providerPhoto = firebaseUser.photoURL?.absoluteString {
            data["photoURL"] = providerPhoto
            data["avatarURL"] = providerPhoto
        }

        try await ref.setData(data, merge: true)
        print("[AuthService] Firestore user doc \(isNew ? "created" : "updated") uid=\(uid) resolvedName=\(resolvedName) keptUserPhoto=\(!existingPhoto.isEmpty)")

        // Seed/refresh the public mirror so leaderboards can show this user's
        // current name/photo. Backfills accounts created before publicProfiles.
        let effectivePhoto = existingPhoto.isEmpty ? firebaseUser.photoURL?.absoluteString : existingPhoto
        await PublicProfileService.write(uid: uid, displayName: resolvedName, photoURL: effectivePhoto)

        return await fetchFirestoreUser(uid: uid) ?? AppUser.placeholder
    }

    // MARK: - Private: Fetch Firestore User
    private func fetchFirestoreUser(uid: String) async -> AppUser? {
        guard let snapshot = try? await db.collection("users").document(uid).getDocument(),
              snapshot.exists, let data = snapshot.data() else {
            print("[AuthService] loaded user payload: <no doc> uid=\(uid)")
            return nil
        }
        // Strict decode first; fall back to the lenient builder so a partial/legacy doc
        // still produces a usable user instead of nil (which blanks the whole profile).
        let user = (try? snapshot.data(as: AppUser.self)) ?? AppUser(firestoreData: data, uid: uid)
        print("[AuthService] loaded user payload uid=\(uid) name=\(user.displayName ?? "<nil>") photo=\(user.photoURL ?? "<nil>") totalChecks=\(user.totalFitChecks) premium=\(user.isPremium)")
        return user
    }
}

// MARK: - Nonce Store (Apple Sign-In)
final class AppleSignInNonceStore {
    static let shared = AppleSignInNonceStore()
    private init() {}
    var currentNonce: String?
}

// MARK: - Nonce Helpers
func randomNonceString(length: Int = 32) -> String {
    let count = max(length, 1)
    let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")

    var randomBytes = [UInt8](repeating: 0, count: count)
    let status = SecRandomCopyBytes(kSecRandomDefault, count, &randomBytes)
    if status != errSecSuccess {
        // SecRandomCopyBytes can (very rarely) fail. The Apple Sign-In path must
        // NEVER crash for it — a fatalError here is an App-Review launch/auth crash
        // risk. Fall back to Swift's cryptographically-secure system RNG so sign-in
        // can still proceed with a valid nonce.
        AppLog.crash("randomNonceString: SecRandomCopyBytes failed (\(status)) — using SystemRandomNumberGenerator fallback")
        var rng = SystemRandomNumberGenerator()
        randomBytes = (0..<count).map { _ in UInt8.random(in: 0...255, using: &rng) }
    }
    return String(randomBytes.map { charset[Int($0) % charset.count] })
}

func sha256(_ input: String) -> String {
    let inputData = Data(input.utf8)
    let hashed = SHA256.hash(data: inputData)
    return hashed.compactMap { String(format: "%02x", $0) }.joined()
}

// MARK: - Placeholder
extension AppUser {
    static let placeholder = AppUser(
        email: "", displayName: "User", avatarURL: nil, photoURL: nil,
        avatarEmoji: nil, avatarColor: nil,
        provider: "apple",
        stylePreferences: [], defaultStyleGoal: "gen_z",
        subscriptionTier: .free, subscriptionExpiresAt: nil,
        dailyChecksUsed: 0, dailyChecksResetAt: Date(),
        streakCount: 0, lastCheckDate: nil,
        photoRetentionDays: 7,
        totalFitChecks: 0, averageScore: 0, bestScore: 0, savedLooksCount: 0,
        createdAt: Date(), lastLoginAt: Date(),
        isPremium: false, subscriptionStatus: "none",
        currentPeriodEnd: nil, planName: nil, fitCheckLimit: Config.freeChecksPerDay,
        profileSetupComplete: nil
    )
}
