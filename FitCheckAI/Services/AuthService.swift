import Foundation
import AuthenticationServices
import CryptoKit
import FirebaseAuth
import FirebaseFirestore
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
        return await fetchFirestoreUser(uid: firebaseUser.uid)
    }

    // MARK: - Apple Sign-In
    func signInWithApple(credential: ASAuthorizationAppleIDCredential) async throws -> AppUser {
        guard let identityToken = credential.identityToken,
              let tokenString = String(data: identityToken, encoding: .utf8) else {
            throw AuthError.unknown("Apple Sign In token unavailable.")
        }

        // Retrieve the raw nonce stored in AuthView before the Apple request
        guard let rawNonce = AppleSignInNonceStore.shared.currentNonce else {
            throw AuthError.unknown("Missing nonce for Apple Sign In.")
        }

        let firebaseCredential = OAuthProvider.appleCredential(
            withIDToken: tokenString,
            rawNonce: rawNonce,
            fullName: credential.fullName
        )

        let authResult = try await Auth.auth().signIn(with: firebaseCredential)
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
        }

        // Display name: Apple may provide it only on first sign-in
        let resolvedName = overrideName
            ?? firebaseUser.displayName
            ?? snapshot?.data()?["displayName"] as? String
        if let name = resolvedName, !name.isEmpty {
            data["displayName"] = name
        }

        // Photo URL
        if let photoURL = firebaseUser.photoURL?.absoluteString {
            data["photoURL"] = photoURL
            data["avatarURL"] = photoURL
        }

        try await ref.setData(data, merge: true)
        return await fetchFirestoreUser(uid: uid) ?? AppUser.placeholder
    }

    // MARK: - Private: Fetch Firestore User
    private func fetchFirestoreUser(uid: String) async -> AppUser? {
        guard let snapshot = try? await db.collection("users").document(uid).getDocument() else {
            return nil
        }
        let decoder = Firestore.Decoder()
        decoder.dateDecodingStrategy = .timestamp
        return try? snapshot.data(as: AppUser.self)
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
        createdAt: Date(), lastLoginAt: Date()
    )
}
