import SwiftUI

struct ScoreBreakdownView: View {
    let analysis: OutfitAnalysis
    let outfitImage: UIImage?

    @EnvironmentObject var appState: AppState
    @State private var showTips = false

    private let dimensionScores: [(String, String, Double, Double)] = []

    var body: some View {
        ZStack {
            Color.fcBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {
                    // Overall score header
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Score Breakdown")
                                .font(.fcHeading)
                                .foregroundColor(.fcTextPrimary)
                            Text("What makes up your score")
                                .font(.fcBody)
                                .foregroundColor(.fcTextSecondary)
                        }
                        Spacer()
                        ScoreBadge(score: analysis.overallScore, fontSize: 18)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                    // Dimension scores
                    VStack(spacing: 10) {
                        ScoreBarView(label: "Color Harmony",      icon: "🎨", score: analysis.colorScore,            delay: 0)
                        ScoreBarView(label: "Fit & Proportion",   icon: "📐", score: analysis.fitScore,              delay: 0.05)
                        ScoreBarView(label: "Trend Alignment",    icon: "📈", score: analysis.trendScore,            delay: 0.10)
                        ScoreBarView(label: "Occasion Match",     icon: "🎯", score: analysis.occasionScore,         delay: 0.15)
                        ScoreBarView(label: "Shoes & Accessories",icon: "👟", score: analysis.shoesAccessoriesScore, delay: 0.20)
                        ScoreBarView(label: "Photo Quality",      icon: "📸", score: analysis.photoQualityScore,     delay: 0.25)
                    }
                    .padding(.horizontal, 20)

                    Divider()
                        .background(Color.white.opacity(0.08))
                        .padding(.horizontal, 20)

                    // Style lens scores
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Style Lens Scores")
                            .font(.fcBodyBold)
                            .foregroundColor(.fcTextPrimary)
                            .padding(.horizontal, 20)

                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                            ForEach(StyleGoal.allCases, id: \.self) { goal in
                                let isLocked = !appState.isPremium && goal != .genZ
                                LensScoreCard(
                                    goal: goal,
                                    score: isLocked ? nil : analysis.score(for: goal),
                                    isSelected: false,
                                    isLocked: isLocked,
                                    onUnlock: { appState.showPremiumSheet = true }
                                )
                            }
                        }
                        .padding(.horizontal, 20)
                    }

                    // Premium banner for free users
                    if !appState.isPremium {
                        PremiumUpsellBanner(
                            message: "Unlock all 8 lens scores + AI outfit upgrades"
                        ) {
                            appState.showPremiumSheet = true
                        }
                        .padding(.horizontal, 20)
                    }

                    // Detected items card
                    detectedItemsCard

                    // Color analysis card
                    colorAnalysisCard

                    // CTA
                    Button("See Improvement Tips →") {
                        showTips = true
                    }
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.fcBackground)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.fcAccent)
                    .cornerRadius(16)
                    .buttonStyle(HapticButtonStyle())
                    .padding(.horizontal, 20)
                    .padding(.bottom, 50)
                }
                .padding(.top, 8)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showTips) {
            ImprovementTipsView(analysis: analysis, outfitImage: outfitImage)
                .environmentObject(appState)
        }
    }

    private var detectedItemsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Outfit Detected")
                .font(.fcBodyBold)
                .foregroundColor(.fcTextPrimary)

            let items = analysis.detectedItems
            VStack(alignment: .leading, spacing: 8) {
                if let top = items.top {
                    detectedRow(label: "Top", value: top)
                }
                if let bottom = items.bottom {
                    detectedRow(label: "Bottom", value: bottom)
                }
                if let outerwear = items.outerwear {
                    detectedRow(label: "Outerwear", value: outerwear)
                }
                if let shoes = items.shoes {
                    detectedRow(label: "Shoes", value: shoes)
                }
                if !items.accessories.isEmpty {
                    detectedRow(label: "Accessories", value: items.accessories.joined(separator: ", "))
                }
                detectedRow(label: "Silhouette", value: items.overallSilhouette.capitalized)
            }
        }
        .padding(16)
        .background(Color.fcSurface)
        .cornerRadius(16)
        .padding(.horizontal, 20)
    }

    private func detectedRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label + ":")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.fcTextSecondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.system(size: 13))
                .foregroundColor(.fcTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var colorAnalysisCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Color Analysis")
                .font(.fcBodyBold)
                .foregroundColor(.fcTextPrimary)

            Text(analysis.colorAnalysis.paletteDescription)
                .font(.fcBody)
                .foregroundColor(.fcTextPrimary)

            HStack(spacing: 8) {
                ForEach(analysis.colorAnalysis.dominantColors, id: \.self) { color in
                    Text(color)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.fcTextPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.fcSurface2)
                        .cornerRadius(8)
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "circle.hexagongrid.fill")
                    .foregroundColor(.fcAccent)
                    .font(.system(size: 12))
                Text("Harmony: ")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.fcTextSecondary)
                + Text(analysis.colorAnalysis.harmonyType.capitalized)
                    .font(.system(size: 13))
                    .foregroundColor(.fcTextPrimary)
            }

            if let issue = analysis.colorAnalysis.colorIssues {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.fcWarning)
                        .font(.system(size: 12))
                    Text(issue)
                        .font(.system(size: 13))
                        .foregroundColor(.fcTextPrimary)
                }
            }
        }
        .padding(16)
        .background(Color.fcSurface)
        .cornerRadius(16)
        .padding(.horizontal, 20)
    }
}
