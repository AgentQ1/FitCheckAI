import Foundation

// MARK: - Full Analysis Response
struct OutfitAnalysis: Codable, Identifiable {
    let id: String
    let outfitID: String

    // Core scores
    let overallScore: Double
    let colorScore: Double
    let fitScore: Double
    let trendScore: Double
    let occasionScore: Double
    let shoesAccessoriesScore: Double
    let photoQualityScore: Double

    // Lens scores
    let genZScore: Double
    let professionalScore: Double
    let dateNightScore: Double
    let luxuryScore: Double
    let streetwearScore: Double
    let campusScore: Double
    let gymScore: Double
    let interviewScore: Double

    // Text
    let verdict: String
    let stylePersonality: String
    let confidenceLevel: String
    let whatWorks: [String]
    let whatToImprove: [String]
    let bestOneChange: String

    // Rich data
    let colorAnalysis: ColorAnalysis
    let detectedItems: DetectedItems
    let improvedLooks: [ImprovedLook]

    /// A single AI-generated "upgraded outfit" image cached on the fit-check doc.
    /// Powers the AI Outfit Upgrade Preview card. Absent on a fresh analyze
    /// response (the image is generated lazily by `generatePreviewUpgrade`).
    let previewUpgradeURL: String?

    let processingTimeMs: Int?
    let createdAt: Date

    func score(for goal: StyleGoal) -> Double {
        switch goal {
        case .genZ:         return genZScore
        case .professional: return professionalScore
        case .dateNight:    return dateNightScore
        case .luxury:       return luxuryScore
        case .streetwear:   return streetwearScore
        case .campus:       return campusScore
        case .gym:          return gymScore
        case .interview:    return interviewScore
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case outfitID = "outfit_id"
        case overallScore = "overall_score"
        case colorScore = "color_score"
        case fitScore = "fit_score"
        case trendScore = "trend_score"
        case occasionScore = "occasion_score"
        case shoesAccessoriesScore = "shoes_accessories_score"
        case photoQualityScore = "photo_quality_score"
        case genZScore = "gen_z_score"
        case professionalScore = "professional_score"
        case dateNightScore = "date_night_score"
        case luxuryScore = "luxury_score"
        case streetwearScore = "streetwear_score"
        case campusScore = "campus_score"
        case gymScore = "gym_score"
        case interviewScore = "interview_score"
        case verdict
        case stylePersonality = "style_personality"
        case confidenceLevel = "confidence_level"
        case whatWorks = "what_works"
        case whatToImprove = "what_to_improve"
        case bestOneChange = "best_one_change"
        case colorAnalysis = "color_analysis"
        case detectedItems = "detected_items"
        case improvedLooks = "improved_looks"
        case previewUpgradeURL = "preview_upgrade_url"
        case processingTimeMs = "processing_time_ms"
        case createdAt = "created_at"
    }
}

// MARK: - Sub-Models
struct ColorAnalysis: Codable {
    let paletteDescription: String
    let harmonyType: String
    let dominantColors: [String]
    let colorIssues: String?

    enum CodingKeys: String, CodingKey {
        case paletteDescription = "palette_description"
        case harmonyType = "harmony_type"
        case dominantColors = "dominant_colors"
        case colorIssues = "color_issues"
    }
}

struct DetectedItems: Codable {
    let top: String?
    let bottom: String?
    let outerwear: String?
    let shoes: String?
    let accessories: [String]
    let overallSilhouette: String

    enum CodingKeys: String, CodingKey {
        case top, bottom, outerwear, shoes, accessories
        case overallSilhouette = "overall_silhouette"
    }
}

struct ImprovedLook: Codable, Identifiable {
    var id: String { title }
    let title: String
    let theme: String
    let expectedScore: Double
    let changes: [OutfitChange]
    let imageGenerationPrompt: String
    var generatedImageURL: String?
    var generationStatus: String?

    enum CodingKeys: String, CodingKey {
        case title, theme, changes
        case expectedScore = "expected_score"
        case imageGenerationPrompt = "image_generation_prompt"
        case generatedImageURL = "generated_image_url"
        case generationStatus = "generation_status"
    }
}

struct OutfitChange: Codable, Identifiable {
    var id: String { item }
    let item: String
    let change: String
    let reason: String
}

// MARK: - Upload Response
struct UploadOutfitResponse: Codable {
    let fitCheckID: String
    let storagePath: String
    let checksRemaining: Int?

    enum CodingKeys: String, CodingKey {
        case fitCheckID = "fit_check_id"
        case storagePath = "storage_path"
        case checksRemaining = "checks_remaining"
    }
}

// MARK: - Generation Response
struct GenerationJobResponse: Codable {
    let generationJobID: String
    let status: String
    let estimatedSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case generationJobID = "generation_job_id"
        case status
        case estimatedSeconds = "estimated_seconds"
    }
}

// MARK: - Preview Upgrade Response
struct PreviewUpgradeResponse: Codable {
    let imageURL: String
    let title: String?
    let status: String?

    enum CodingKeys: String, CodingKey {
        case imageURL = "image_url"
        case title, status
    }
}

struct GenerationStatusResponse: Codable {
    let status: String
    let generatedLooks: [GeneratedLookResult]?

    enum CodingKeys: String, CodingKey {
        case status
        case generatedLooks = "generated_looks"
    }
}

struct GeneratedLookResult: Codable, Identifiable {
    let id: String
    let lookType: String
    let title: String
    let imageURL: String
    let expectedScore: Double
    let changes: [OutfitChange]

    enum CodingKeys: String, CodingKey {
        case id, title, changes
        case lookType = "look_type"
        case imageURL = "image_url"
        case expectedScore = "expected_score"
    }
}
