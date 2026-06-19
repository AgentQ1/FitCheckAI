import Foundation

enum Config {
    // MARK: - Firebase Cloud Functions base URL
    // Replace YOUR_PROJECT_ID with your Firebase project ID
    static let cloudFunctionsBase = ProcessInfo.processInfo.environment["CLOUD_FUNCTIONS_BASE"]
        ?? "https://us-central1-fitcheck-d3091.cloudfunctions.net"

    // MARK: - Stripe (publishable key only — safe for client)
    //
    // Premium is sold through Stripe Checkout opened in an in-app Safari sheet.
    // The publishable key below is safe to ship; the secret key, price IDs, and
    // webhook secret all live server-side in the Cloud Functions env. The native
    // checkout/verify/billing-portal endpoints are listed under `API` below.
    static let stripePublishableKey = "pk_live_51TalQYQWcjGCSxB32NvWE67egNU44nFS7ixr6igGmgkQRfbWadC6QoIhTRivoZrhzmsjsvE0m9OOHZc3DyCticG200gLYZ0FEa"

    // MARK: - App Store links
    //
    // ⚠️ Placeholder App Store ID until the app is live — replace `0000000000`
    // with the real numeric Apple ID from App Store Connect. Until then Share /
    // Rate open the search page so there are no broken links.
    static let appStoreID = "0000000000"
    static var appStoreURL: String {
        appStoreID == "0000000000"
            ? "https://apps.apple.com/app/fitcheck"
            : "https://apps.apple.com/app/id\(appStoreID)"
    }
    static var writeReviewURL: String {
        appStoreID == "0000000000"
            ? appStoreURL
            : "https://apps.apple.com/app/id\(appStoreID)?action=write-review"
    }

    // MARK: - Support / Privacy contact
    static let supportEmail = "moomolab@gmail.com"
    static let privacyEmail = "moomolab@gmail.com"

    // MARK: - Gemini outfit-upgrade (client-side knobs only)
    //
    // The Gemini API key NO LONGER ships in the app — the upgrade call goes through
    // the `generateGeminiUpgrade` Cloud Function, which holds the secret key
    // (process.env.GEMINI_API_KEY) and the model name server-side, exactly like the
    // OpenAI path. Only the client-side image-prep / timeout knobs remain here.
    enum Gemini {
        /// Fail-fast budget so a slow generation never blocks the carousel.
        static let requestTimeout: TimeInterval = 60
    }

    // MARK: - Rate Limits
    static let freeChecksPerDay    = 3
    static let freeSavedLooksLimit = 10

    // MARK: - History / Upgrade Storage Caps
    //
    // Storage shouldn't grow forever, so history is capped. Cleanup keeps only the
    // newest items per user/analysis and prunes the rest (saved upgrades excluded).
    /// Keep only the latest N outfit-check analyses per user.
    static let maxHistoryItems = 10
    /// Keep only the latest N generated upgrades per analysis.
    static let maxGeneratedUpgrades = 10
    /// Analyses older than this (in days) are also eligible for cleanup. Saved
    /// upgrades persist separately under `savedUpgrades` and are never pruned.
    static let historyMaxAgeDays = 7

    // MARK: - Cloud Function URLs
    enum API {
        static var base: String { cloudFunctionsBase }
        static var uploadOutfit:     String { "\(base)/uploadOutfit" }
        static var analyzeOutfit:    String { "\(base)/analyzeOutfit" }
        static var generateLooks:    String { "\(base)/generateLookOptions" }
        static var generatePreviewUpgrade: String { "\(base)/generatePreviewUpgrade" }
        // Gemini outfit-upgrade carousel — server holds the Gemini key; the client
        // sends only the fit-check id + prompt (image is read from Storage server-side).
        static var generateGeminiUpgrade: String { "\(base)/generateGeminiUpgrade" }
        static var generationStatus: String { "\(base)/generationStatus" }
        static var saveLook:         String { "\(base)/saveLook" }
        static var likeLook:         String { "\(base)/likeLook" }
        static var deleteOutfit:     String { "\(base)/deleteOutfit" }
        static var rateOutfit:       String { "\(base)/rateOutfit" }
        static var exportUserData:            String { "\(base)/exportUserData" }
        static var deleteAccount:             String { "\(base)/deleteAccount" }
        static var generateTrend:             String { "\(base)/generateWeeklyTrend" }
        // Stripe subscriptions: open Checkout, verify a returned session, and open
        // the customer billing portal. Prices/secrets live server-side.
        static var createCheckoutSession:      String { "\(base)/createCheckoutSession" }
        static var verifyCheckoutSession:      String { "\(base)/verifyCheckoutSession" }
        static var createBillingPortalSession: String { "\(base)/createBillingPortalSession" }
        // Arena — Top 3 finalist voting (automatic, trend-pool entry)
        static var getArenaFinalists: String { "\(base)/getArenaFinalists" }
        static var ensureArenaEntry:  String { "\(base)/ensureArenaEntry" }
        static var voteHotFit:        String { "\(base)/voteHotFit" }
        static var postArenaComment:  String { "\(base)/postArenaComment" }
        static var getArenaComments:  String { "\(base)/getArenaComments" }
        static var reportFit:         String { "\(base)/reportFit" }
    }

    // MARK: - Arena tunables — mirror functions/src/arena.ts
    enum Arena {
        /// A fit must score at least this to enter the Arena.
        static let minScore = 6.5
        /// Outfit-focused quick chips shown in the comment sheet (must match the
        /// backend's ALLOWED_COMMENT_TAGS set in arena.ts).
        static let commentTags = [
            "Clean fit",
            "Good colors",
            "Would wear this",
            "Needs better shoes",
            "Too basic",
            "Fit issue",
        ]
        static let commentMaxLength = 120
    }
}
