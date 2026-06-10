import SwiftUI

struct OutfitCard: View {
    let outfit: OutfitSummary
    var onTap: (() -> Void)?

    var body: some View {
        Button(action: { onTap?() }) {
            ZStack(alignment: .topTrailing) {
                // Photo — Vision smart crop keeps the face/head + upper body in frame
                // while the thumbnail fills the cell edge-to-edge.
                SmartOutfitImageView(source: (outfit.thumbnailURL.flatMap(URL.init)).map { .remote($0) })
                    .frame(maxWidth: .infinity)
                    .aspectRatio(3.0/4.0, contentMode: .fit)
                    .clipped()
                    .cornerRadius(20)

                // Score badge
                if let score = outfit.overallScore {
                    ScoreBadge(score: score, fontSize: 13)
                        .padding(8)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(outfit.formattedDate)
                    .font(.fcCaption)
                    .foregroundColor(.fcTextSecondary)
                if let goal = outfit.styleGoal {
                    Text(StyleGoal(rawValue: goal)?.displayName ?? goal)
                        .font(.fcTag)
                        .foregroundColor(.fcTextPrimary)
                }
            }
            .padding(.top, 6)
            .padding(.horizontal, 2)
        }
        .buttonStyle(HapticButtonStyle(style: .light))
    }
}

struct OutfitSummary: Identifiable {
    let id: String
    let thumbnailURL: String?
    let overallScore: Double?
    let styleGoal: String?
    let createdAt: Date

    var formattedDate: String {
        let cal = Calendar.current
        if cal.isDateInToday(createdAt) {
            return "Today, " + createdAt.formatted(date: .omitted, time: .shortened)
        } else if cal.isDateInYesterday(createdAt) {
            return "Yesterday"
        } else {
            return createdAt.formatted(date: .abbreviated, time: .omitted)
        }
    }
}
