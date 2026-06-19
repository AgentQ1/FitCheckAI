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

    // MARK: - Session Restoration
    func restoreSession() async {
        // Firebase Auth automatically restores sessions — no manual action needed.
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

        // Seed displayName from the provider, or the email prefix, ONLY when absent.
        let hasName = (existing["displayName"] as? String)?.isEmpty == false
        if !hasName {
            if let n = firebaseUser.displayName, !n.isEmpty {
                fill["displayName"] = n
            } else if let email = firebaseUser.email, !email.isEmpty {
                fill["displayName"] = String(email.prefix(while: { $0 != "@" }))
            }
        }
        // Seed photo from the provider only when absent (never clobber an uploaded one).
        let hasPhoto = (existing["photoURL"] as? String)?.isEmpty == false
        if !hasPhoto, let p = firebaseUser.photoURL?.absoluteString {
            fill["photoURL"] = p
            fill["avatarURL"] = p
        }
        // Missing onboarding flag: a brand-new doc must onboard; an existing one is
        // treated as already set up so returning users aren't sent back through it.
        if existing["profileSetupComplete"] == nil {
            fill["profileSetupComplete"] = exists ? true : false
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
            authResult = try await Auth.auth().signIn(with: firebaseCredential)
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
        let authResult = try await Auth.auth().signIn(with: firebaseCredential)
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

        // Display name resolution. The user's own edits live in Firestore and are
        // the source of truth — the auth provider resends its original name on
        // every login, so it must NEVER win over a name the user already saved.
        // Order: explicit override (Apple only hands the name back on first
        // sign-in) → the name already saved in Firestore → the provider's name
        // (seeds it for brand-new users).
        let existingName = (snapshot?.data()?["displayName"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
        let resolvedName = overrideName ?? existingName ?? firebaseUser.displayName
        if let name = resolvedName, !name.isEmpty {
            data["displayName"] = name
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
        print("[AuthService] Firestore user doc \(isNew ? "created" : "updated") uid=\(uid) resolvedName=\(resolvedName ?? "<nil>") keptUserPhoto=\(!existingPhoto.isEmpty)")

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
    precondition(length > 0)
    var randomBytes = [UInt8](repeating: 0, count: length)
    let errorCode = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
    if errorCode != errSecSuccess {
        fatalError("Unable to generate nonce: \(errorCode)")
    }
    let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
    return String(randomBytes.map { byte in charset[Int(byte) % charset.count] })
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
