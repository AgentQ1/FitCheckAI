import Foundation
import FirebaseFirestore

struct AppUser: Codable, Identifiable {
    @DocumentID var id: String?
    var email: String
    var displayName: String?
    var avatarURL: String?
    var photoURL: String?
    var provider: String
    var stylePreferences: [String]
    var defaultStyleGoal: String
    var subscriptionTier: SubscriptionTier
    var subscriptionExpiresAt: Date?
    var dailyChecksUsed: Int
    var dailyChecksResetAt: Date
    var streakCount: Int
    var lastCheckDate: String?
    var photoRetentionDays: Int
    var totalFitChecks: Int
    var averageScore: Double
    var bestScore: Double
    var savedLooksCount: Int
    var createdAt: Date
    var lastLoginAt: Date

    // Stripe subscription fields — written only by backend webhook
    var isPremium: Bool
    var subscriptionStatus: String
    var stripeCustomerId: String?
    var stripeSubscriptionId: String?
    var currentPeriodEnd: Date?
    var planName: String?
    var fitCheckLimit: Int

    /// Whether this user's top-scoring fits may appear in the public Arena and the
    /// public Today/Week leaderboards (display name, avatar, outfit photo + AI score
    /// become visible to other users). The backend treats `isPublic != false` as
    /// public, so `nil` (legacy docs) defaults to public; set `false` to opt out.
    var isPublic: Bool?

    /// Convenience: true when the user participates in public Arena/leaderboards.
    var isArenaPublic: Bool { isPublic ?? true }

    /// Onboarding gate. `false` is written for brand-new accounts at signup and
    /// flipped to `true` once the user finishes ProfileSetupView. `nil` means the
    /// account predates this flag — those users are treated as already set up so
    /// they are never re-onboarded.
    var profileSetupComplete: Bool?

    /// True only while a new account still needs to complete onboarding.
    var requiresProfileSetup: Bool { profileSetupComplete == false }

    var checksRemaining: Int {
        guard !isPremium else { return Int.max }
        let limit = fitCheckLimit > 0 ? fitCheckLimit : Config.freeChecksPerDay
        return max(0, limit - dailyChecksUsed)
    }

    var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12:  return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<21: return "Good evening"
        default:      return "Hey"
        }
    }

    var firstName: String {
        displayName?.components(separatedBy: " ").first ?? "there"
    }
}

extension AppUser {
    /// Best-effort construction from a raw Firestore dict, used when strict `Codable`
    /// decoding fails — e.g. a legacy or partially-written `users/{uid}` doc missing a
    /// required field. Without this, one missing field makes `data(as:)` return nil and
    /// the whole profile goes blank. Every field here has a safe default, so Profile and
    /// Edit Profile always have something valid to show.
    init(firestoreData data: [String: Any], uid: String) {
        func num(_ key: String) -> NSNumber? { data[key] as? NSNumber }
        func date(_ key: String) -> Date? { (data[key] as? Timestamp)?.dateValue() }

        self.id = uid
        self.email = data["email"] as? String ?? ""
        self.displayName = (data["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.avatarURL = data["avatarURL"] as? String
        self.photoURL = data["photoURL"] as? String
        self.provider = data["provider"] as? String ?? "unknown"
        self.stylePreferences = data["stylePreferences"] as? [String] ?? []
        self.defaultStyleGoal = data["defaultStyleGoal"] as? String ?? "gen_z"
        self.subscriptionTier = SubscriptionTier(rawValue: data["subscriptionTier"] as? String ?? "free") ?? .free
        self.subscriptionExpiresAt = date("subscriptionExpiresAt")
        self.dailyChecksUsed = num("dailyChecksUsed")?.intValue ?? 0
        self.dailyChecksResetAt = date("dailyChecksResetAt") ?? Date()
        self.streakCount = num("streakCount")?.intValue ?? 0
        self.lastCheckDate = data["lastCheckDate"] as? String
        self.photoRetentionDays = num("photoRetentionDays")?.intValue ?? 7
        self.totalFitChecks = num("totalFitChecks")?.intValue ?? 0
        self.averageScore = num("averageScore")?.doubleValue ?? 0
        self.bestScore = num("bestScore")?.doubleValue ?? 0
        self.savedLooksCount = num("savedLooksCount")?.intValue ?? 0
        self.createdAt = date("createdAt") ?? Date()
        self.lastLoginAt = date("lastLoginAt") ?? Date()
        self.isPremium = data["isPremium"] as? Bool ?? false
        self.subscriptionStatus = data["subscriptionStatus"] as? String ?? "none"
        self.stripeCustomerId = data["stripeCustomerId"] as? String
        self.stripeSubscriptionId = data["stripeSubscriptionId"] as? String
        self.currentPeriodEnd = date("currentPeriodEnd")
        self.planName = data["planName"] as? String
        self.fitCheckLimit = num("fitCheckLimit")?.intValue ?? Config.freeChecksPerDay
        self.isPublic = data["isPublic"] as? Bool
        self.profileSetupComplete = data["profileSetupComplete"] as? Bool
    }
}
