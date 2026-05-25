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
