import SwiftUI

struct OutfitOptionsView: View {
    let analysis: OutfitAnalysis
    let outfitImage: UIImage?

    @EnvironmentObject var appState: AppState
    @StateObject private var vm: OutfitOptionsViewModel

    @State private var selectedLook: ImprovedLook?
    @State private var showBeforeAfter = false
    @State private var showDetail = false

    init(analysis: OutfitAnalysis, outfitImage: UIImage?) {
        self.analysis = analysis
        self.outfitImage = outfitImage
        _vm = StateObject(wrappedValue: OutfitOptionsViewModel(analysis: analysis))
    }

    var body: some View {
        ZStack {
            Color.fcBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    // Header
                    VStack(spacing: 6) {
                        HStack {
                            Text("Your 3 Upgrades")
                                .font(.fcHeading)
                                .foregroundColor(.fcTextPrimary)
                            Spacer()
                            // AI badge
                            HStack(spacing: 4) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 11))
                                Text("AI Generated")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundColor(.fcTextSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.fcSurface)
                            .cornerRadius(8)
                        }
                        Text("Same vibe, better execution.")
                            .font(.fcBody)
                            .foregroundColor(.fcTextSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                    // Generating state
                    if vm.isGenerating {
                        generatingState
                    } else if let error = vm.error {
                        errorState(error)
                    } else {
                        // Look cards
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16) {
                                ForEach(analysis.improvedLooks) { look in
                                    LookOptionCard(
                                        look: look,
                                        generatedImageURL: vm.generatedLooks[look.title],
                                        isGenerating: vm.isGenerating,
                                        originalScore: analysis.overallScore
                                    ) {
                                        selectedLook = look
                                        showDetail = true
                                    }
                                }
                            }
                            .padding(.horizontal, 20)
                        }

                        // Before / After CTA
                        if vm.generatedLooks.count > 0 {
                            Button("Compare Before & After →") {
                                showBeforeAfter = true
                                appState.analyticsService.track(.beforeAfterViewed)
                            }
                            .font(.system(size: 17, weight: .bold))
                            .foregroundColor(.fcBackground)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.fcAccent)
                            .cornerRadius(16)
                            .buttonStyle(HapticButtonStyle())
                            .padding(.horizontal, 20)
                        }

                        // Regenerate
                        Button("Regenerate Options") {
                            vm.regenerate()
                        }
                        .font(.fcBody)
                        .foregroundColor(.fcTextSecondary)
                    }

                    Spacer(minLength: 50)
                }
            }
        }
        .navigationTitle("")
        .navigationDestination(isPresented: $showBeforeAfter) {
            BeforeAfterView(
                outfitImage: outfitImage,
                analysis: analysis,
                bestLookURL: vm.generatedLooks[analysis.improvedLooks.last?.title ?? ""]
            )
        }
        .navigationDestination(isPresented: $showDetail) {
            if let look = selectedLook {
                LookDetailSheet(look: look, imageURL: vm.generatedLooks[look.title])
            }
        }
        .task { await vm.loadGenerations() }
    }

    private var generatingState: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(.fcAccent)
            Text("Generating your upgrades...")
                .font(.fcBodyBold)
                .foregroundColor(.fcTextPrimary)
            Text("This takes about 20–30 seconds. Hang tight.")
                .font(.fcBody)
                .foregroundColor(.fcTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private func errorState(_ msg: String) -> some View {
        VStack(spacing: 16) {
            Text("😵")
                .font(.system(size: 50))
            Text(msg)
                .font(.fcBody)
                .foregroundColor(.fcTextSecondary)
                .multilineTextAlignment(.center)
            Button("Try Again") { vm.regenerate() }
                .font(.fcBodyBold)
                .foregroundColor(.fcBackground)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Color.fcAccent)
                .cornerRadius(12)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 40)
    }
}

// MARK: - ViewModel
@MainActor
final class OutfitOptionsViewModel: ObservableObject {
    @Published var isGenerating = false
    @Published var generatedLooks: [String: String] = [:]  // title -> imageURL
    @Published var error: String?

    private let analysis: OutfitAnalysis
    private let aiService = AIService()

    init(analysis: OutfitAnalysis) {
        self.analysis = analysis
    }

    func loadGenerations() async {
        isGenerating = true
        error = nil
        do {
            let jobResp = try await aiService.requestLookGeneration(analysisID: analysis.id)
            // Poll until done
            try await pollUntilComplete(jobID: jobResp.generationJobID)
        } catch {
            self.error = "Generation failed. Tap to try again."
        }
        isGenerating = false
    }

    private func pollUntilComplete(jobID: String) async throws {
        var attempts = 0
        while attempts < 20 {
            try await Task.sleep(nanoseconds: 3_000_000_000)  // 3s
            let status = try await aiService.pollGenerationStatus(jobID: jobID)
            if status.status == "done", let looks = status.generatedLooks {
                for look in looks {
                    generatedLooks[look.title] = look.imageURL
                }
                return
            }
            if status.status == "failed" { throw NSError(domain: "gen", code: 0) }
            attempts += 1
        }
        throw NSError(domain: "timeout", code: 0)
    }

    func regenerate() {
        Task { await loadGenerations() }
    }
}

// MARK: - Look Option Card
struct LookOptionCard: View {
    let look: ImprovedLook
    let generatedImageURL: String?
    let isGenerating: Bool
    let originalScore: Double
    let onTap: () -> Void

    var scoreDiff: Double { look.expectedScore - originalScore }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 12) {
                // Image
                ZStack {
                    if let url = generatedImageURL.flatMap({ URL(string: $0) }) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let img):
                                img.resizable().scaledToFill()
                            default:
                                loadingPlaceholder
                            }
                        }
                    } else {
                        loadingPlaceholder
                    }
                }
                .frame(width: 220, height: 300)
                .clipped()
                .cornerRadius(18)
                .overlay(alignment: .topLeading) {
                    Text(look.title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.fcBackground)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.white)
                        .cornerRadius(8)
                        .padding(10)
                }
                .overlay(alignment: .topTrailing) {
                    ScoreBadge(score: look.expectedScore)
                        .padding(10)
                }

                // Score improvement
                HStack(spacing: 6) {
                    Text(String(format: "+%.1f", scoreDiff))
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundColor(.fcSuccess)
                    Text("pts with this upgrade")
                        .font(.system(size: 12))
                        .foregroundColor(.fcTextSecondary)
                }

                // Change chips
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(look.changes.prefix(3)) { change in
                            Text(change.item)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.fcTextPrimary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color.fcSurface2)
                                .cornerRadius(8)
                        }
                    }
                }

                Text(look.theme)
                    .font(.fcCaption)
                    .foregroundColor(.fcTextSecondary)
                    .lineLimit(2)
            }
        }
        .buttonStyle(HapticButtonStyle(style: .light))
        .frame(width: 220)
    }

    private var loadingPlaceholder: some View {
        ZStack {
            Color.fcSurface2
            if isGenerating {
                VStack(spacing: 12) {
                    ProgressView().tint(.fcAccent)
                    Text("Generating...").font(.fcCaption).foregroundColor(.fcTextSecondary)
                }
            } else {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 40))
                    .foregroundColor(.fcTextSecondary.opacity(0.3))
            }
        }
    }
}

// MARK: - Look Detail Sheet
struct LookDetailSheet: View {
    let look: ImprovedLook
    let imageURL: String?
    @Environment(\.dismiss) var dismiss

    var body: some View {
        ZStack {
            Color.fcBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Image
                    if let url = imageURL.flatMap({ URL(string: $0) }) {
                        AsyncImage(url: url) { phase in
                            if case .success(let img) = phase {
                                img.resizable().scaledToFit()
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .cornerRadius(20)
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        Text(look.title)
                            .font(.fcHeading)
                            .foregroundColor(.fcTextPrimary)

                        ScoreBadge(score: look.expectedScore, fontSize: 16)

                        Text("Changes Made")
                            .font(.fcBodyBold)
                            .foregroundColor(.fcTextPrimary)

                        VStack(spacing: 12) {
                            ForEach(look.changes) { change in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(change.item)
                                            .font(.system(size: 14, weight: .bold))
                                            .foregroundColor(.fcTextSecondary)
                                        Image(systemName: "arrow.right")
                                            .font(.system(size: 12))
                                            .foregroundColor(.fcTextSecondary)
                                        Text(change.change)
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(.fcTextPrimary)
                                    }
                                    Text(change.reason)
                                        .font(.fcCaption)
                                        .foregroundColor(.fcTextSecondary)
                                }
                                .padding(12)
                                .background(Color.fcSurface)
                                .cornerRadius(12)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 40)
                }
            }
        }
    }
}
