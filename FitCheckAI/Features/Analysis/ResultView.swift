import SwiftUI

struct ResultView: View {
    let analysis: OutfitAnalysis
    let outfitImage: UIImage?

    @EnvironmentObject var appState: AppState
    @State private var showBreakdown = false
    @State private var isSaved = false
    @State private var isLiked = false
    @State private var showShareSheet = false

    // Rating state
    @State private var ratingThumb: String?
    @State private var ratingStars: Int = 0
    @State private var ratingFeedback: String = ""
    @State private var ratingSubmitted = false
    @State private var isSubmittingRating = false

    private let shareMessage = "Just checked my fit with FitCheck AI and scored \(0)/10! 🔥 Download the app to rate yours."

    var body: some View {
        ZStack {
            Color.fcBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    photoHeader

                    scoreCard
                        .padding(.horizontal, 20)
                        .offset(y: -40)

                    actionRow
                        .padding(.horizontal, 24)
                        .padding(.top, -20)

                    lensScoreTeaser
                        .padding(.horizontal, 20)
                        .padding(.top, 20)

                    Button("See Full Breakdown →") {
                        showBreakdown = true
                        appState.analyticsService.track(.scoreBreakdownViewed)
                    }
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(Color.fcAccentCream)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.fcAccent)
                    .cornerRadius(16)
                    .buttonStyle(HapticButtonStyle())
                    .padding(.horizontal, 24)
                    .padding(.top, 24)

                    // Rating card
                    ratingCard
                        .padding(.horizontal, 20)
                        .padding(.top, 20)
                        .padding(.bottom, 50)
                }
            }
        }
        .navigationDestination(isPresented: $showBreakdown) {
            ScoreBreakdownView(analysis: analysis, outfitImage: outfitImage)
                .environmentObject(appState)
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: [buildShareText()])
        }
        .onAppear {
            appState.analyticsService.track(.resultViewed)
        }
    }

    // MARK: - Subviews

    private var photoHeader: some View {
        ZStack(alignment: .bottom) {
            Group {
                if let img = outfitImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.fcSurface2
                }
            }
            .frame(height: UIScreen.main.bounds.height * 0.45)
            .clipped()

            // Gradient fade to background
            LinearGradient(
                colors: [.clear, .fcBackground],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 100)
        }
        .frame(height: UIScreen.main.bounds.height * 0.45)
    }

    private var scoreCard: some View {
        VStack(spacing: 20) {
            ScoreRingView(score: analysis.overallScore, size: 130)

            VerdictBadge(verdict: analysis.verdict)

            Text("You're giving: \(analysis.stylePersonality)")
                .font(.fcBodyBold)
                .foregroundColor(.fcTextPrimary)
                .multilineTextAlignment(.center)

            if analysis.confidenceLevel == "Low" {
                Label("Medium confidence — limited by photo quality", systemImage: "exclamationmark.triangle")
                    .font(.fcCaption)
                    .foregroundColor(.fcWarning)
            }

            // One-liner from best_one_change as a teaser
            Text("\"\(analysis.whatWorks.first ?? "")\"")
                .font(.system(size: 14, weight: .medium, design: .serif))
                .foregroundStyle(.secondary)
                .italic()
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
        }
        .padding(24)
        .background(Color.fcSurface)
        .cornerRadius(24)
        .shadow(color: Color.fcShadow, radius: 20, y: 8)
    }

    private var actionRow: some View {
        HStack(spacing: 20) {
            actionButton(icon: isLiked ? "heart.fill" : "heart",
                        label: "Like",
                        color: isLiked ? .fcAccent2 : .fcTextSecondary) {
                isLiked.toggle()
                Task { try? await appState.aiService.likeLook(fitCheckID: analysis.outfitID, liked: isLiked) }
                appState.analyticsService.track(.lookLiked)
            }

            actionButton(icon: isSaved ? "bookmark.fill" : "bookmark",
                        label: "Save",
                        color: isSaved ? .fcAccent : .fcTextSecondary) {
                isSaved.toggle()
                Task { try? await appState.aiService.saveLook(fitCheckID: analysis.outfitID) }
                appState.analyticsService.track(.lookSaved)
            }

            actionButton(icon: "square.and.arrow.up", label: "Share", color: .fcTextSecondary) {
                showShareSheet = true
                appState.analyticsService.track(.shareTapped, properties: ["type": "result"])
            }
        }
        .padding(16)
        .background(Color.fcSurface)
        .cornerRadius(20)
    }

    private func actionButton(icon: String, label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundColor(color)
                Text(label)
                    .font(.fcCaption)
                    .foregroundColor(.fcTextSecondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(HapticButtonStyle(style: .light))
    }

    // MARK: - Rating Card

    @ViewBuilder
    private var ratingCard: some View {
        if ratingSubmitted {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.fcSuccess)
                Text("Thanks for your feedback! 🙏")
                    .font(.fcBodyBold)
                    .foregroundColor(.fcTextPrimary)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(Color.fcSuccess.opacity(0.1))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.fcSuccess.opacity(0.3), lineWidth: 1))
            .cornerRadius(16)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                Text("Rate This Analysis")
                    .font(.fcBodyBold)
                    .foregroundColor(.fcTextPrimary)

                // Thumbs
                HStack(spacing: 12) {
                    thumbButton(type: "up")
                    thumbButton(type: "down")
                    Spacer()
                    Text("Was this accurate?")
                        .font(.fcCaption)
                        .foregroundColor(.fcTextSecondary)
                }

                // Stars
                HStack(spacing: 8) {
                    ForEach(1...5, id: \.self) { star in
                        Button(action: { ratingStars = star }) {
                            Image(systemName: star <= ratingStars ? "star.fill" : "star")
                                .font(.system(size: 26))
                                .foregroundColor(star <= ratingStars ? .fcGold : .fcTextSecondary.opacity(0.4))
                        }
                        .buttonStyle(HapticButtonStyle(style: .light))
                    }
                }

                // Feedback
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $ratingFeedback)
                        .font(.fcBody)
                        .foregroundColor(.fcTextPrimary)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .frame(minHeight: 60, maxHeight: 100)
                    if ratingFeedback.isEmpty {
                        Text("Optional feedback...")
                            .font(.fcBody)
                            .foregroundColor(.fcTextSecondary.opacity(0.5))
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                }
                .padding(12)
                .background(Color.fcSurface2)
                .cornerRadius(12)

                // Submit
                Button(action: { Task { await submitRating() } }) {
                    HStack(spacing: 8) {
                        if isSubmittingRating {
                            ProgressView().tint(Color.fcAccentCream).scaleEffect(0.8)
                        }
                        Text(isSubmittingRating ? "Submitting..." : "Submit Feedback")
                            .font(.system(size: 15, weight: .bold))
                    }
                    .foregroundColor((ratingThumb != nil || ratingStars > 0) ? Color.fcAccentCream : Color.fcTextSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background((ratingThumb != nil || ratingStars > 0) ? Color.fcAccent : Color.fcSurface2)
                    .cornerRadius(12)
                }
                .disabled((ratingThumb == nil && ratingStars == 0) || isSubmittingRating)
                .buttonStyle(HapticButtonStyle())
            }
            .padding(16)
            .background(Color.fcSurface)
            .cornerRadius(16)
        }
    }

    private func thumbButton(type: String) -> some View {
        Button(action: { ratingThumb = ratingThumb == type ? nil : type }) {
            VStack(spacing: 4) {
                Image(systemName: type == "up" ? "hand.thumbsup.fill" : "hand.thumbsdown.fill")
                    .font(.system(size: 22))
                    .foregroundColor(ratingThumb == type ? (type == "up" ? .fcAccent : .fcError) : .fcTextSecondary)
                Text(type == "up" ? "Accurate" : "Off")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.fcTextSecondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(ratingThumb == type ? (type == "up" ? Color.fcAccent.opacity(0.12) : Color.fcError.opacity(0.12)) : Color.fcSurface2)
            .cornerRadius(12)
        }
        .buttonStyle(HapticButtonStyle(style: .light))
    }

    private func submitRating() async {
        isSubmittingRating = true
        let body: [String: Any] = [
            "fit_check_id": analysis.outfitID,
            "thumbs": ratingThumb ?? "none",
            "stars": ratingStars,
            "feedback": ratingFeedback
        ]
        try? await appState.aiService.rateOutfit(body: body)
        await MainActor.run {
            ratingSubmitted = true
            isSubmittingRating = false
        }
    }

    private func buildShareText() -> String {
        let score = String(format: "%.1f", analysis.overallScore)
        return "Just got a \(score)/10 fit score on FitCheck AI! 🔥 The AI said: \"\(analysis.whatWorks.first ?? "looking clean!")\" Download the app to rate your own outfit."
    }

    private var lensScoreTeaser: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Style Lens Preview")
                .font(.fcBodyBold)
                .foregroundColor(.fcTextPrimary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    // Selected goal (always shown)
                    lensChip(goal: appState.currentUser.map { StyleGoal(rawValue: $0.defaultStyleGoal) ?? .genZ } ?? .genZ,
                             score: analysis.genZScore,
                             isSelected: true)

                    // Gen Z always shown for free
                    lensChip(goal: .genZ, score: analysis.genZScore, isSelected: false)

                    // Rest locked for free
                    if !appState.isPremium {
                        ForEach([StyleGoal.professional, .dateNight, .luxury, .streetwear], id: \.self) { goal in
                            lockedLensChip(goal: goal)
                        }
                    } else {
                        ForEach(StyleGoal.allCases, id: \.self) { goal in
                            lensChip(goal: goal, score: analysis.score(for: goal), isSelected: false)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Color.fcSurface)
        .cornerRadius(16)
    }

    private func lensChip(goal: StyleGoal, score: Double, isSelected: Bool) -> some View {
        VStack(spacing: 4) {
            Text(goal.emoji).font(.system(size: 22))
            Text(goal.shortName).font(.system(size: 11, weight: .medium)).foregroundColor(.fcTextSecondary)
            Text(String(format: "%.1f", score))
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor(Color.scoreColor(for: score))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(isSelected ? Color.fcAccent.opacity(0.12) : Color.fcSurface2)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? Color.fcAccent : Color.clear, lineWidth: 1.5)
        )
        .cornerRadius(12)
    }

    private func lockedLensChip(goal: StyleGoal) -> some View {
        Button(action: { appState.showPremiumSheet = true }) {
            VStack(spacing: 4) {
                Text(goal.emoji).font(.system(size: 22)).opacity(0.4)
                Text(goal.shortName).font(.system(size: 11, weight: .medium)).foregroundColor(.fcTextSecondary.opacity(0.4))
                Image(systemName: "lock.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.fcGold)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.fcSurface2)
            .cornerRadius(12)
        }
    }
}
