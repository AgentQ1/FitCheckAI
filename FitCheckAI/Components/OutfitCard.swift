import SwiftUI

struct OutfitCard: View {
    let outfit: OutfitSummary
    var onTap: (() -> Void)?

    var body: some View {
        Button(action: { onTap?() }) {
            ZStack(alignment: .topTrailing) {
                // Photo
                Group {
                    if let url = URL(string: outfit.thumbnailURL ?? "") {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let img):
                                img.resizable().scaledToFill()
                            case .failure:
                                placeholderView
                            default:
                                Color.fcSurface2
                                    .overlay(ProgressView().tint(.fcTextSecondary))
                            }
                        }
                    } else {
                        placeholderView
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(3/4, contentMode: .fill)
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

    private var placeholderView: some View {
        ZStack {
            Color.fcSurface
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 40))
                .foregroundColor(.fcTextSecondary.opacity(0.4))
        }
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
