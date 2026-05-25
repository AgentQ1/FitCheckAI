import SwiftUI

struct BeforeAfterView: View {
    let outfitImage: UIImage?
    let analysis: OutfitAnalysis
    let bestLookURL: String?

    @State private var dividerPosition: CGFloat = 0.5
    @State private var showShareSheet = false
    @EnvironmentObject var appState: AppState

    var body: some View {
        ZStack {
            Color.fcBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Comparison area
                GeometryReader { geo in
                    ZStack {
                        // After (full width, behind)
                        if let url = bestLookURL.flatMap({ URL(string: $0) }) {
                            AsyncImage(url: url) { phase in
                                if case .success(let img) = phase {
                                    img.resizable().scaledToFill()
                                } else {
                                    Color.fcSurface2
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                        } else {
                            Color.fcSurface2.frame(maxWidth: .infinity, maxHeight: .infinity)
                        }

                        // Before (clipped to left side)
                        if let img = outfitImage {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFill()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .clipped()
                                .mask(
                                    HStack(spacing: 0) {
                                        Color.white.frame(width: geo.size.width * dividerPosition)
                                        Color.clear
                                    }
                                )
                        }

                        // Divider line
                        Rectangle()
                            .fill(Color.white)
                            .frame(width: 2)
                            .offset(x: geo.size.width * dividerPosition - geo.size.width / 2)
                            .overlay(
                                ZStack {
                                    Circle()
                                        .fill(Color.white)
                                        .frame(width: 36, height: 36)
                                        .shadow(radius: 4)
                                    HStack(spacing: 2) {
                                        Image(systemName: "chevron.left")
                                        Image(systemName: "chevron.right")
                                    }
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.fcBackground)
                                }
                            )
                            .offset(x: geo.size.width * dividerPosition - geo.size.width / 2)

                        // Labels
                        HStack {
                            VStack {
                                Spacer()
                                label(text: "Before", score: analysis.overallScore)
                                    .padding(.leading, 12)
                                    .padding(.bottom, 16)
                            }
                            Spacer()
                            VStack {
                                Spacer()
                                label(text: "After", score: analysis.improvedLooks.last?.expectedScore ?? analysis.overallScore)
                                    .padding(.trailing, 12)
                                    .padding(.bottom, 16)
                            }
                        }
                    }
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let newPos = value.location.x / geo.size.width
                                dividerPosition = max(0.05, min(0.95, newPos))
                            }
                    )
                }
                .frame(maxHeight: UIScreen.main.bounds.height * 0.6)

                // Bottom panel
                VStack(spacing: 16) {
                    if let bestLook = analysis.improvedLooks.last {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Score Improvement")
                                    .font(.fcCaption)
                                    .foregroundColor(.fcTextSecondary)
                                Text(String(format: "+%.1f points with this upgrade", bestLook.expectedScore - analysis.overallScore))
                                    .font(.system(size: 18, weight: .bold, design: .rounded))
                                    .foregroundColor(.fcSuccess)
                            }
                            Spacer()
                            ScoreBadge(score: bestLook.expectedScore, fontSize: 18)
                        }
                        .padding(16)
                        .background(Color.fcSurface)
                        .cornerRadius(16)
                    }

                    HStack(spacing: 12) {
                        Button("Share This Glow-Up →") {
                            showShareSheet = true
                            appState.analyticsService.track(.shareTapped, properties: ["type": "before_after"])
                        }
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.fcBackground)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.fcAccent)
                        .cornerRadius(14)
                        .buttonStyle(HapticButtonStyle())

                        Button {
                            // Save both
                        } label: {
                            Image(systemName: "bookmark.fill")
                                .font(.system(size: 18))
                                .foregroundColor(.fcTextPrimary)
                                .frame(width: 50, height: 50)
                                .background(Color.fcSurface)
                                .cornerRadius(14)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 20)

                Spacer(minLength: 20)
            }
        }
        .navigationTitle("Before & After")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            appState.analyticsService.track(.beforeAfterViewed)
        }
    }

    private func label(text: String, score: Double) -> some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
            ScoreBadge(score: score, fontSize: 12)
        }
        .padding(8)
        .background(Color.black.opacity(0.5))
        .cornerRadius(10)
    }
}
