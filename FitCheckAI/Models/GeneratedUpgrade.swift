import Foundation
import FirebaseFirestore

// MARK: - Generated Upgrade
//
// One AI-generated outfit upgrade, tied to a SPECIFIC outfit analysis and persisted at
//   users/{uid}/fit_checks/{analysisId}/generatedUpgrades/{upgradeId}
//
// IMPORTANT mapping: this app's "analyses" ARE its `fit_checks` documents, so
// `analysisId == fitCheckID` everywhere. The subcollection name `generatedUpgrades`
// is new (alongside the existing `ratings` / `generated_looks`).
//
// Both providers end up here as a remote URL: Gemini's in-memory bytes are uploaded
// to Storage first; OpenAI's image already lives in Storage (server-uploaded).
struct GeneratedUpgrade: Identifiable, Equatable {
    /// upgradeId — also the Firestore document id.
    let id: String
    let imageURL: String
    /// Storage object path for the image, when WE uploaded it (Gemini). nil for the
    /// server-managed OpenAI preview, whose lifecycle the backend owns.
    let imageStoragePath: String?
    /// "openai" | "gemini".
    let providerName: String
    let promptUsed: String
    let createdAt: Date
    let variationIndex: Int
    let sourceAnalysisId: String
    let sourceImageURL: String?
    let isSaved: Bool
    let generationTimeMs: Int?
    let status: String

    var formattedCreatedAt: String {
        let cal = Calendar.current
        if cal.isDateInToday(createdAt) {
            return createdAt.formatted(date: .omitted, time: .shortened)
        }
        return createdAt.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: Firestore decoding

    /// Builds a model from a Firestore document. Returns nil only if the image URL is
    /// missing (an upgrade with no image is unusable).
    init?(documentID: String, data: [String: Any]) {
        guard let imageURL = data["imageURL"] as? String, !imageURL.isEmpty else { return nil }
        self.id = documentID
        self.imageURL = imageURL
        self.imageStoragePath = data["imageStoragePath"] as? String
        self.providerName = data["providerName"] as? String ?? "openai"
        self.promptUsed = data["promptUsed"] as? String ?? ""
        self.createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
        self.variationIndex = data["variationIndex"] as? Int ?? 0
        self.sourceAnalysisId = data["sourceAnalysisId"] as? String ?? ""
        self.sourceImageURL = data["sourceImageURL"] as? String
        self.isSaved = data["isSaved"] as? Bool ?? false
        self.generationTimeMs = data["generationTimeMs"] as? Int
        self.status = data["status"] as? String ?? "success"
    }

    /// Direct initializer for an optimistic in-memory model (e.g. right after a save).
    init(id: String,
         imageURL: String,
         imageStoragePath: String?,
         providerName: String,
         promptUsed: String,
         createdAt: Date,
         variationIndex: Int,
         sourceAnalysisId: String,
         sourceImageURL: String?,
         isSaved: Bool,
         generationTimeMs: Int?,
         status: String) {
        self.id = id
        self.imageURL = imageURL
        self.imageStoragePath = imageStoragePath
        self.providerName = providerName
        self.promptUsed = promptUsed
        self.createdAt = createdAt
        self.variationIndex = variationIndex
        self.sourceAnalysisId = sourceAnalysisId
        self.sourceImageURL = sourceImageURL
        self.isSaved = isSaved
        self.generationTimeMs = generationTimeMs
        self.status = status
    }

    /// Returns a copy with `isSaved` flipped — used to reflect a Save tap instantly
    /// in the UI before the Firestore write returns.
    func markingSaved(_ saved: Bool) -> GeneratedUpgrade {
        GeneratedUpgrade(id: id,
                         imageURL: imageURL,
                         imageStoragePath: imageStoragePath,
                         providerName: providerName,
                         promptUsed: promptUsed,
                         createdAt: createdAt,
                         variationIndex: variationIndex,
                         sourceAnalysisId: sourceAnalysisId,
                         sourceImageURL: sourceImageURL,
                         isSaved: saved,
                         generationTimeMs: generationTimeMs,
                         status: status)
    }
}
