import Foundation

enum Config {
    // MARK: - Firebase Cloud Functions base URL
    // Replace YOUR_PROJECT_ID with your Firebase project ID
    static let cloudFunctionsBase = ProcessInfo.processInfo.environment["CLOUD_FUNCTIONS_BASE"]
        ?? "https://us-central1-fitcheck-d3091.cloudfunctions.net"

    // MARK: - In-App Purchase (StoreKit 2)
    //
    // Premium is sold through Apple In-App Purchase — the only App-Store-compliant
    // way to sell in-app digital subscriptions (Guideline 3.1.1). Prices are read
    // from the App Store product at runtime, never hardcoded here.
    //
    // ⚠️ APP STORE CONNECT SETUP REQUIRED: create two auto-renewable subscriptions
    // in ONE subscription group with EXACTLY these product IDs. If you choose
    // different IDs in App Store Connect, update them here (and in FitCheck.storekit).
    enum IAP {
        static let monthlyProductID = "com.fitcheckai.premium.monthly"
        static let yearlyProductID  = "com.fitcheckai.premium.yearly"

        /// All product IDs the paywall loads, best (yearly value) first.
        static let productIDs: [String] = [yearlyProductID, monthlyProductID]

        static func isPremiumProduct(_ id: String) -> Bool { productIDs.contains(id) }
    }

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
        // Gemini outfit-upgrade carousel — server holds the Gemini key; the client
        // sends only the fit-check id + prompt (image is read from Storage server-side).
        static var generateGeminiUpgrade: String { "\(base)/generateGeminiUpgrade" }
        static var saveLook:         String { "\(base)/saveLook" }
        static var deleteOutfit:     String { "\(base)/deleteOutfit" }
        static var rateOutfit:       String { "\(base)/rateOutfit" }
        static var exportUserData:            String { "\(base)/exportUserData" }
        static var deleteAccount:             String { "\(base)/deleteAccount" }
        static var generateTrend:             String { "\(base)/generateWeeklyTrend" }
        // Apple In-App Purchase: client posts the signed StoreKit transaction (JWS)
        // here after a purchase/restore so the backend can verify it with Apple and
        // mirror entitlement into Firestore (server-side rate limits read `isPremium`).
        static var syncAppleSubscription:     String { "\(base)/syncAppleSubscription" }
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
