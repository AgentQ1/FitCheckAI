import Foundation
import FirebaseFirestore

struct WeeklyTrend: Codable, Identifiable {
    @DocumentID var id: String?
    var weekStartDate: Date
    var title: String
    var shortDescription: String
    var styleTags: [String]
    var colors: [String]
    var outfitExamples: [String]
    var dos: [String]
    var donts: [String]
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case weekStartDate = "weekStartDate"
        case title
        case shortDescription = "shortDescription"
        case styleTags = "styleTags"
        case colors
        case outfitExamples = "outfitExamples"
        case dos
        case donts
        case createdAt
    }
}
