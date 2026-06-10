import Foundation

enum Config {
    // MARK: - Firebase Cloud Functions base URL
    // Replace YOUR_PROJECT_ID with your Firebase project ID
    static let cloudFunctionsBase = ProcessInfo.processInfo.environment["CLOUD_FUNCTIONS_BASE"]
        ?? "https://us-central1-fitcheck-d3091.cloudfunctions.net"

    // MARK: - Stripe (publishable key only — safe for client)
    static let stripePublishableKey = "pk_live_51TalQYQWcjGCSxB32NvWE67egNU44nFS7ixr6igGmgkQRfbWadC6QoIhTRivoZrhzmsjsvE0m9OOHZc3DyCticG200gLYZ0FEa"

    // MARK: - Gemini AI Studio (on-device image edit provider)
    //
    // ⚠️ SECURITY: unlike the Stripe *publishable* key above, this is a SECRET key
    // that ships inside the app binary and can be extracted. Before a wide release,
    // either (a) lock it down in Google Cloud Console with iOS app + API
    // restrictions, or (b) move the Gemini call behind a Firebase function (like
    // the OpenAI path). It's read from the GEMINI_API_KEY env var first so you can
    // externalize it without code changes.
    enum Gemini {
        // Two independent Gemini API keys back the two carousel slides. Using a
        // separate key (and a different styling bias) per slot makes the two
        // generated looks differ, so the user can compare and pick what suits them.
        static var apiKey: String {
            ProcessInfo.processInfo.environment["GEMINI_API_KEY"]
                ?? "AIzaSyDpurQrLNHyWcFtSI-DFTR7P4HerleczpA"
        }

        /// Second key — drives the alternate look (slot A) so it generates
        /// independently from the primary key's look (slot B).
        static var apiKeyB: String {
            ProcessInfo.processInfo.environment["GEMINI_API_KEY_B"]
                ?? "AIzaSyAEQgiCbP8LFaLgywfnGeLfhJjACMJODWI"
        }

        /// Image generation/editing model ("Nano Banana"). Swap here if needed —
        /// e.g. "gemini-2.5-flash-image-preview" or "gemini-2.0-flash-preview-image-generation".
        static let model = "gemini-2.5-flash-image"

        /// Modalities the model should return. ["IMAGE"] suits gemini-2.5-flash-image;
        /// older preview models may need ["TEXT", "IMAGE"].
        static let responseModalities = ["IMAGE"]

        /// Fail-fast budget so a slow provider never blocks the carousel.
        static let requestTimeout: TimeInterval = 60

        /// Source image is downscaled to this longest-side (px) and JPEG-compressed
        /// before upload — smaller payload = faster edit.
        static let maxSourceDimension: CGFloat = 1024
        static let sourceJPEGQuality: CGFloat = 0.82

        static func generateContentURL(apiKey: String) -> URL {
            URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)")!
        }
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
        static var generationStatus: String { "\(base)/generationStatus" }
        static var saveLook:         String { "\(base)/saveLook" }
        static var likeLook:         String { "\(base)/likeLook" }
        static var deleteOutfit:     String { "\(base)/deleteOutfit" }
        static var rateOutfit:       String { "\(base)/rateOutfit" }
        static var exportUserData:            String { "\(base)/exportUserData" }
        static var deleteAccount:             String { "\(base)/deleteAccount" }
        static var generateTrend:             String { "\(base)/generateWeeklyTrend" }
        static var createCheckoutSession:     String { "\(base)/createCheckoutSession" }
        static var verifyCheckoutSession:     String { "\(base)/verifyCheckoutSession" }
        static var createBillingPortalSession: String { "\(base)/createBillingPortalSession" }
    }
}
