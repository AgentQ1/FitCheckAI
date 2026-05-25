import Foundation

enum Config {
    // MARK: - Firebase Cloud Functions base URL
    // Replace YOUR_PROJECT_ID with your Firebase project ID
    static let cloudFunctionsBase = ProcessInfo.processInfo.environment["CLOUD_FUNCTIONS_BASE"]
        ?? "https://us-central1-fitcheck-d3091.cloudfunctions.net"

    // MARK: - Stripe (publishable key only — safe for client)
    static let stripePublishableKey = "pk_live_51TalQYQWcjGCSxB32NvWE67egNU44nFS7ixr6igGmgkQRfbWadC6QoIhTRivoZrhzmsjsvE0m9OOHZc3DyCticG200gLYZ0FEa"

    // MARK: - RevenueCat
    static let revenueCatPublicKey = "appl_YOUR_REVENUECAT_KEY"

    // MARK: - PostHog
    static let posthogAPIKey = "phc_YOUR_POSTHOG_KEY"
    static let posthogHost   = "https://app.posthog.com"

    // MARK: - Rate Limits
    static let freeChecksPerDay    = 3
    static let freeSavedLooksLimit = 10

    // MARK: - Feature Flags
    static let fitBattleEnabled           = false
    static let campusLeaderboardEnabled   = false
    static let shoppingLinksEnabled       = false

    // MARK: - RevenueCat Product IDs
    enum ProductID {
        static let monthlyPremium  = "fitcheck_premium_monthly"
        static let yearlyPremium   = "fitcheck_premium_yearly"
        static let studentPremium  = "fitcheck_student_monthly"
        static let trialMonthly    = "fitcheck_trial_monthly"
    }

    // MARK: - Cloud Function URLs
    enum API {
        static var base: String { cloudFunctionsBase }
        static var uploadOutfit:     String { "\(base)/uploadOutfit" }
        static var analyzeOutfit:    String { "\(base)/analyzeOutfit" }
        static var generateLooks:    String { "\(base)/generateLookOptions" }
        static var generationStatus: String { "\(base)/generationStatus" }
        static var saveLook:         String { "\(base)/saveLook" }
        static var likeLook:         String { "\(base)/likeLook" }
        static var deleteOutfit:     String { "\(base)/deleteOutfit" }
        static var rateOutfit:       String { "\(base)/rateOutfit" }
        static var exportUserData:            String { "\(base)/exportUserData" }
        static var deleteAccount:             String { "\(base)/deleteAccount" }
        static var generateTrend:             String { "\(base)/generateWeeklyTrend" }
        static var createCheckoutSession:     String { "\(base)/createCheckoutSession" }
        static var createBillingPortalSession: String { "\(base)/createBillingPortalSession" }
    }
}
