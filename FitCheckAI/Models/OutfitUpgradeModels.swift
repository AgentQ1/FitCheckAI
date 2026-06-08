import Foundation

// MARK: - Outfit Upgrade Preview — Data Model
//
// These types back the multi-provider "AI Outfit Upgrade Preview" carousel.
// The feature now produces TWO upgraded previews (one per provider) generated in
// parallel and shown in an Instagram-style horizontal swipe. Everything here is
// `Sendable` so a result can be produced inside a detached child task and handed
// back to the @MainActor coordinator without data-race warnings.

/// Which engine produced a given preview. The raw value doubles as the small,
/// subtle on-image label used for internal testing ("OpenAI" / "Gemini").
// Raw values are used only for internal logging/slot-matching — never shown in the UI.
enum UpgradeProviderKind: String, Sendable, CaseIterable {
    case openAI = "OpenAI"
    case gemini = "Gemini"
}

/// Where the upgraded image bytes live. OpenAI runs server-side and returns a
/// tokenized Firebase Storage URL (load with `AsyncImage`); Gemini runs on-device
/// and returns raw image bytes in memory (load with `UIImage(data:)`). Keeping
/// both in one enum lets the carousel render either kind uniformly.
enum UpgradeImageSource: Sendable, Equatable {
    case remote(URL)
    case data(Data)
}

/// Lifecycle of a single provider's slide. The carousel always shows a stable
/// slot per provider so pages never reorder: a slot moves generating → success
/// or generating → failed in place.
enum OutfitUpgradeStatus: Sendable, Equatable {
    case generating
    case success
    case failed
}

/// One upgraded preview (one carousel slide / one provider's output).
struct OutfitUpgradeResult: Identifiable, Sendable, Equatable {
    let id: UUID
    let provider: UpgradeProviderKind
    var image: UpgradeImageSource?
    /// The exact prompt sent to the provider (for debugging / logging).
    var promptUsed: String
    var createdAt: Date
    /// Wall-clock seconds the provider took. nil while generating.
    var generationTime: TimeInterval?
    var status: OutfitUpgradeStatus
    /// Human-readable failure reason (only when `status == .failed`).
    var errorMessage: String?

    init(provider: UpgradeProviderKind,
         image: UpgradeImageSource? = nil,
         promptUsed: String = "",
         createdAt: Date = Date(),
         generationTime: TimeInterval? = nil,
         status: OutfitUpgradeStatus,
         errorMessage: String? = nil) {
        self.id = UUID()
        self.provider = provider
        self.image = image
        self.promptUsed = promptUsed
        self.createdAt = createdAt
        self.generationTime = generationTime
        self.status = status
        self.errorMessage = errorMessage
    }

    // Convenience factories for the common states.
    static func generating(provider: UpgradeProviderKind) -> OutfitUpgradeResult {
        OutfitUpgradeResult(provider: provider, status: .generating)
    }

    static func failed(provider: UpgradeProviderKind, message: String, elapsed: TimeInterval?) -> OutfitUpgradeResult {
        OutfitUpgradeResult(provider: provider, generationTime: elapsed, status: .failed, errorMessage: message)
    }
}

/// Everything a provider needs to produce one upgrade. Deliberately holds the
/// pre-resized JPEG `Data` (not a `UIImage`) so it is `Sendable` and can cross
/// into child tasks, and so the input is compressed exactly once up front.
struct OutfitUpgradeRequest: Sendable {
    let fitCheckID: String

    /// The user's uploaded outfit photo, already downscaled + JPEG-compressed for
    /// fast upload. nil only if the source photo wasn't available (Gemini will
    /// fail fast; OpenAI can still run because the server has the original).
    let sourceImageData: Data?
    let sourcePixelWidth: Int
    let sourcePixelHeight: Int

    /// Concrete, targeted outfit improvements from the analysis ("- Shoes: swap to
    /// white leather sneakers"). Drives the on-device Gemini edit prompt.
    let changeLines: [String]
    /// The single highest-impact tweak from the analysis.
    let bestOneChange: String
    /// Theme/title of the improved look (for logs + loading copy).
    let themeTitle: String?

    /// A previously-generated OpenAI preview URL (from the analyze response or a
    /// prior session). When present the OpenAI provider returns it immediately
    /// instead of paying for a fresh server generation. Latency win on re-view.
    let precomputedOpenAIURL: String?
}
