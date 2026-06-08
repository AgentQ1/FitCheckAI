import SwiftUI

struct ResultView: View {
    let analysis: OutfitAnalysis
    let outfitImage: UIImage?

    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var showBreakdown = false
    @State private var showTips = false
    @State private var showPremiumLocal = false
    @State private var isSaved = false
    @State private var isLiked = false
    @State private var showShareSheet = false

    // Rating state
    @State private var ratingThumb: String?
    @State private var ratingStars: Int = 0
    @State private var ratingFeedback: String = ""
    @State private var ratingSubmitted = false
    @State private var isSubmittingRating = false
    @State private var actionError: String?

    // AI Outfit Upgrade Preview — multi-provider parallel carousel (OpenAI + Gemini)
    @StateObject private var upgradeStore = OutfitUpgradeService()
    @State private var carouselIndex = 0
    /// Tapped generated image, shown full-screen. nil = no preview open.
    @State private var previewItem: UpgradePreviewItem?

    // Fixed photo header height — capped so it never stretches on tall devices
    // and never collapses on small ones. Tuned for ~iPhone 12/14/15 hero feel.
    private var photoHeight: CGFloat {
        let h = UIScreen.main.bounds.height
        return min(max(h * 0.42, 300), 380)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.fcBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        photoHeader

                        scoreCard
                            .padding(.horizontal, 20)
                            .offset(y: -44)

                        lensScoreTeaser
                            .padding(.horizontal, 20)
                            .padding(.top, -24)

                        Button(action: {
                            showBreakdown = true
                            appState.analyticsService.track(.scoreBreakdownViewed)
                        }) {
                            HStack(spacing: 6) {
                                Text("See Full Breakdown")
                                    .font(.system(size: 16, weight: .bold))
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 13, weight: .bold))
                            }
                            .foregroundColor(Color.fcAccentCream)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.fcAccent)
                            .cornerRadius(16)
                        }
                        .buttonStyle(HapticButtonStyle())
                        .padding(.horizontal, 20)
                        .padding(.top, 20)

                        Button(action: {
                            showTips = true
                            appState.analyticsService.track(.tipsViewed)
                        }) {
                            HStack(spacing: 6) {
                                Text("See Improvement Tips")
                                    .font(.system(size: 16, weight: .bold))
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 13, weight: .bold))
                            }
                            .foregroundColor(Color.fcAccentCream)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.fcAccent)
                            .cornerRadius(16)
                        }
                        .buttonStyle(HapticButtonStyle())
                        .padding(.horizontal, 20)
                        .padding(.top, 12)

                        outfitUpgradePreviewCard
                            .padding(.horizontal, 20)
                            .padding(.top, 12)
                            .task(id: analysis.id) { startUpgradeGeneration() }

                        ratingCard
                            .padding(.horizontal, 20)
                            .padding(.top, 20)
                            .padding(.bottom, 32)
                    }
                }
                .ignoresSafeArea(edges: .top)

                stickyActionBar
            }

            floatingTopBar
        }
        .navigationBarHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: $showBreakdown) {
            ScoreBreakdownView(analysis: analysis, outfitImage: outfitImage)
                .environmentObject(appState)
        }
        .navigationDestination(isPresented: $showTips) {
            ImprovementTipsView(analysis: analysis, outfitImage: outfitImage)
                .environmentObject(appState)
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: [buildShareText()])
        }
        .fullScreenCover(isPresented: $showPremiumLocal) {
            PremiumView()
                .environmentObject(appState)
        }
        .fullScreenCover(item: $previewItem) { item in
            UpgradePreviewViewer(source: item.source) { previewItem = nil }
        }
        .onAppear {
            appState.analyticsService.track(.resultViewed)
        }
    }

    // MARK: - Floating top bar

    private var floatingTopBar: some View {
        HStack {
            circleIconButton(systemName: "xmark") {
                dismiss()
                appState.showCheckFlow = false
            }
            Spacer()
            Button(action: openHistory) {
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.stack.fill")
                        .font(.system(size: 13, weight: .bold))
                    Text("History")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundColor(.fcTextPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .overlay(Capsule().stroke(Color.fcTextSecondary.opacity(0.15), lineWidth: 0.5))
                )
            }
            .buttonStyle(HapticButtonStyle(style: .light))
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func circleIconButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.fcTextPrimary)
                .frame(width: 38, height: 38)
                .background(
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(Circle().stroke(Color.fcTextSecondary.opacity(0.15), lineWidth: 0.5))
                )
        }
        .buttonStyle(HapticButtonStyle(style: .light))
    }

    private func openHistory() {
        // Dismiss the CheckFlow first; HomeView's onChange will push HistoryView
        // once the cover finishes animating away.
        appState.pendingHistoryNav = true
        appState.selectedTab = .home
        dismiss()
        appState.showCheckFlow = false
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
            .frame(maxWidth: .infinity)
            .frame(height: photoHeight)
            .clipped()

            // Gradient fade to background so the score card blends in cleanly.
            LinearGradient(
                colors: [.clear, .fcBackground],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 110)
        }
        .frame(height: photoHeight)
    }

    private var scoreCard: some View {
        VStack(spacing: 18) {
            ScoreRingView(score: analysis.overallScore, size: 124)

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

            Text("\"\(analysis.whatWorks.first ?? "")\"")
                .font(.system(size: 14, weight: .medium, design: .serif))
                .foregroundStyle(.secondary)
                .italic()
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(Color.fcSurface)
        .cornerRadius(24)
        .shadow(color: Color.fcShadow, radius: 20, y: 8)
    }

    // MARK: - AI Outfit Upgrade Preview Card (multi-provider carousel)

    /// TWO AI-upgraded looks generated in parallel — one from OpenAI (server-side
    /// gpt-image-1 edit) and one from Gemini (on-device edit) — shown in an
    /// Instagram-style horizontal swipe. Each provider gets a stable slide that
    /// fills in as its engine finishes: the first finisher appears immediately and
    /// the second appends without interrupting the user. Free for everyone — no
    /// paywall. Per-slide Retry on failure, plus Regenerate for fresh variations.
    private var outfitUpgradePreviewCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            upgradePreviewHeader
            upgradePreviewCarousel
            upgradePreviewFooter
        }
        .padding(16)
        .background(Color.fcSurface)
        .cornerRadius(20)
        .shadow(color: Color.fcShadow, radius: 16, y: 6)
    }

    /// Title + dynamic subtitle + AI badge row.
    private var upgradePreviewHeader: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("AI Outfit Upgrade Preview")
                    .font(.fcBodyBold)
                    .foregroundColor(.fcTextPrimary)
                Text(upgradeSubtitle)
                    .font(.fcCaption)
                    .foregroundColor(.fcTextSecondary)
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .bold))
                Text("AI Upgrade")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(.fcGold)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.fcGold.opacity(0.12))
            .cornerRadius(8)
        }
    }

    private var upgradeSubtitle: String {
        let ready = upgradeStore.results.filter { $0.status == .success }.count
        switch upgradeStore.phase {
        case .idle, .loading: return "Creating two upgraded looks from your outfit…"
        case .partial:        return "Your first look is ready — finishing the second…"
        case .complete:       return ready > 1 ? "Two upgraded looks — swipe to compare" : "Your upgraded look"
        case .allFailed:      return "Couldn't generate your upgrade — tap retry"
        }
    }

    /// Horizontal, paged swipe carousel shown in COMPLETION ORDER — the provider
    /// that finishes first is slide 0 (visible immediately) and the other look is a
    /// swipeable slide that shows a loading tile while it's still generating, then
    /// its image. If everything fails we show one error tile. Slide identity is the
    /// provider, so a slide keeps its place as it fills in. `scaledToFit` keeps the
    /// full body (head→shoes) visible with no aggressive crop.
    @ViewBuilder
    private var upgradePreviewCarousel: some View {
        if upgradeStore.showAllFailedTile {
            upgradeSlideTile { upgradeAllFailedTile }
        } else {
            let slides = upgradeStore.slides
            if slides.isEmpty {
                upgradeSlideTile { upgradeGeneratingTile() }
            } else {
                TabView(selection: $carouselIndex) {
                    ForEach(Array(slides.enumerated()), id: \.element.provider) { index, slide in
                        upgradeSlideTile { slideContent(slide) }
                            .tag(index)
                    }
                }
                .frame(height: 460)
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
        }
    }

    /// Shared framing/border so loading, image, and error tiles line up perfectly
    /// in the pager.
    private func upgradeSlideTile<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .frame(height: 460)
            .background(Color.fcSurface2)
            .clipped()
            .cornerRadius(18)
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.fcGold.opacity(0.25), lineWidth: 1)
            )
    }

    @ViewBuilder
    private func slideContent(_ slide: OutfitUpgradeResult) -> some View {
        switch slide.status {
        case .success:
            upgradeImage(slide.image)
                .contentShape(Rectangle())
                .onTapGesture {
                    if let image = slide.image {
                        previewItem = UpgradePreviewItem(source: image)
                    }
                }
                .overlay(alignment: .bottomTrailing) { tapToExpandHint }
        case .generating:
            upgradeGeneratingTile()
        case .failed:
            upgradeErrorTile(slide: slide)
        }
    }

    /// Renders either a remote (OpenAI → Storage) URL or in-memory (Gemini) bytes.
    /// Note: `UIImage(data:)` is decoded inline; for 2 small (~1024px) images this is
    /// cheap, so we skip a decode cache to keep the view simple.
    @ViewBuilder
    private func upgradeImage(_ source: UpgradeImageSource?) -> some View {
        switch source {
        case .remote(let url):
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFit()
                case .empty:            upgradeGeneratingTile()
                default:                upgradeImageBroken
                }
            }
        case .data(let data):
            if let ui = UIImage(data: data) {
                Image(uiImage: ui).resizable().scaledToFit()
            } else {
                upgradeImageBroken
            }
        case nil:
            upgradeImageBroken
        }
    }

    private var upgradeImageBroken: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo")
                .font(.system(size: 32))
                .foregroundColor(.fcTextSecondary.opacity(0.6))
            Text("Image unavailable")
                .font(.fcCaption)
                .foregroundColor(.fcTextSecondary)
        }
    }

    /// Small affordance so users know a generated image can be tapped to expand.
    private var tapToExpandHint: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(.white)
            .padding(7)
            .background(Circle().fill(Color.black.opacity(0.45)))
            .padding(10)
    }

    /// Single error tile shown only when EVERY provider failed. Retry regenerates all.
    private var upgradeAllFailedTile: some View {
        ZStack {
            LinearGradient(
                colors: [Color.fcSurface2, Color.fcAccent2.opacity(0.35)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(spacing: 12) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 40))
                    .foregroundColor(.fcGold.opacity(0.7))
                Text("Couldn't generate your upgrade preview")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.fcTextPrimary)
                    .multilineTextAlignment(.center)
                Button(action: {
                    carouselIndex = 0
                    upgradeStore.rerollAll()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .bold))
                        Text("Retry Upgrade Preview")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .foregroundColor(.fcAccentCream)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(Color.fcAccent)
                    .cornerRadius(10)
                }
                .buttonStyle(HapticButtonStyle(style: .light))
            }
            .padding(.horizontal, 24)
        }
    }

    /// Loading placeholder shown while an upgrade is generating.
    private func upgradeGeneratingTile() -> some View {
        ZStack {
            LinearGradient(
                colors: [Color.fcSurface2, Color.fcAccent2.opacity(0.55)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(spacing: 12) {
                ProgressView()
                    .tint(.fcGold)
                    .scaleEffect(1.2)
                Text("Generating your upgraded look…")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.fcTextPrimary)
                    .multilineTextAlignment(.center)
                if let theme = analysis.improvedLooks.first?.theme {
                    Text(theme)
                        .font(.fcCaption)
                        .foregroundColor(.fcTextSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 24)
        }
    }

    /// Error placeholder for a SINGLE failed provider. Retry re-runs only that
    /// provider, so a successful sibling slide is never disturbed.
    private func upgradeErrorTile(slide: OutfitUpgradeResult) -> some View {
        ZStack {
            LinearGradient(
                colors: [Color.fcSurface2, Color.fcAccent2.opacity(0.35)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(spacing: 12) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 40))
                    .foregroundColor(.fcGold.opacity(0.7))
                Text("Couldn't generate this look")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.fcTextPrimary)
                    .multilineTextAlignment(.center)
                Button(action: { upgradeStore.reroll(provider: slide.provider) }) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .bold))
                        Text("Retry")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .foregroundColor(.fcAccentCream)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(Color.fcAccent)
                    .cornerRadius(10)
                }
                .buttonStyle(HapticButtonStyle(style: .light))
            }
            .padding(.horizontal, 24)
        }
    }

    /// Page dots + counter + Regenerate.
    @ViewBuilder
    private var upgradePreviewFooter: some View {
        let slides = upgradeStore.slides
        let count = slides.count
        let showCarousel = !upgradeStore.showAllFailedTile && !slides.isEmpty
        VStack(spacing: 12) {
            if showCarousel && count > 1 {
                HStack(spacing: 6) {
                    ForEach(Array(slides.enumerated()), id: \.element.provider) { i, _ in
                        Circle()
                            .fill(i == carouselIndex ? Color.fcGold : Color.fcTextSecondary.opacity(0.3))
                            .frame(width: 7, height: 7)
                    }
                    Text("\(min(carouselIndex + 1, count))/\(count)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.fcTextSecondary)
                        .padding(.leading, 6)
                }
            }
            // Regenerate only once everything has settled — don't interrupt a second
            // look that's still on its way. The all-failed tile has its own retry.
            if upgradeStore.allProvidersReturned && !upgradeStore.showAllFailedTile {
                Button(action: {
                    // Reroll ONLY the slide currently on screen (via Gemini).
                    let current = upgradeStore.slides
                    if current.indices.contains(carouselIndex) {
                        upgradeStore.reroll(provider: current[carouselIndex].provider)
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 12, weight: .bold))
                        Text("Regenerate This Look")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .foregroundColor(.fcTextPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.fcSurface2)
                    .cornerRadius(10)
                }
                .buttonStyle(HapticButtonStyle(style: .light))
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Kicks off the parallel multi-provider generation. OpenAI runs server-side
    /// (key stays on the backend, proven gpt-image-1 edit); Gemini runs on-device
    /// from the resized photo. Both preserve the original person / pose / background
    /// and only upgrade the outfit. The coordinator caches per session, so this is
    /// safe to call again on re-view (it restores instead of regenerating).
    private func startUpgradeGeneration(force: Bool = false) {
        // Build targeted change lines from the analysis (drives the Gemini edit).
        let changeLines: [String] = (analysis.improvedLooks.first?.changes ?? []).compactMap { c in
            let item = c.item.trimmingCharacters(in: .whitespaces)
            let change = c.change.trimmingCharacters(in: .whitespaces)
            guard !change.isEmpty else { return nil }
            return item.isEmpty ? "- \(change)" : "- \(item): \(change)"
        }
        // Reuse an already-generated OpenAI preview if the analysis carries one.
        let precomputed = (analysis.previewUpgradeURL?.isEmpty == false)
            ? analysis.previewUpgradeURL
            : analysis.improvedLooks.first?.generatedImageURL

        let providers: [any OutfitUpgradeProvider] = [
            OpenAIOutfitUpgradeProvider(aiService: appState.aiService),
            GeminiOutfitUpgradeProvider()
        ]

        upgradeStore.start(
            fitCheckID: analysis.id,
            sourceImage: outfitImage,
            changeLines: changeLines,
            bestOneChange: analysis.bestOneChange,
            themeTitle: analysis.improvedLooks.first?.theme,
            precomputedOpenAIURL: precomputed,
            providers: providers,
            forceRegenerate: force
        )
    }

    // MARK: - Sticky bottom action bar

    private var stickyActionBar: some View {
        VStack(spacing: 0) {
            if let err = actionError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.fcWarning)
                    Text(err)
                        .font(.fcCaption)
                        .foregroundColor(.fcTextPrimary)
                    Spacer()
                    Button(action: { actionError = nil }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.fcTextSecondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.fcWarning.opacity(0.15))
                .cornerRadius(10)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            HStack(spacing: 0) {
                actionButton(icon: isLiked ? "heart.fill" : "heart",
                            label: "Like",
                            color: isLiked ? .fcAccent2 : .fcTextPrimary) {
                    let previous = isLiked
                    isLiked.toggle()
                    appState.analyticsService.track(.lookLiked)
                    Task {
                        do {
                            try await appState.aiService.likeLook(fitCheckID: analysis.outfitID, liked: isLiked)
                        } catch {
                            print("[ResultView] likeLook failed: \(error.localizedDescription)")
                            await MainActor.run {
                                isLiked = previous
                                actionError = "Couldn't update like. Try again."
                            }
                        }
                    }
                }

                actionButton(icon: isSaved ? "bookmark.fill" : "bookmark",
                            label: "Save",
                            color: isSaved ? .fcAccent : .fcTextPrimary) {
                    let previous = isSaved
                    isSaved.toggle()
                    appState.analyticsService.track(.lookSaved)
                    Task {
                        do {
                            try await appState.aiService.saveLook(fitCheckID: analysis.outfitID)
                        } catch {
                            print("[ResultView] saveLook failed: \(error.localizedDescription)")
                            await MainActor.run {
                                isSaved = previous
                                actionError = "Couldn't save. Try again."
                            }
                        }
                    }
                }

                actionButton(icon: "square.and.arrow.up", label: "Share", color: .fcTextPrimary) {
                    showShareSheet = true
                    appState.analyticsService.track(.shareTapped, properties: ["type": "result"])
                }
            }
            .padding(.top, 10)
            .padding(.bottom, safeAreaBottom() + 6)
            .background(
                Color.fcSurface
                    .overlay(
                        Rectangle()
                            .fill(Color.fcTextSecondary.opacity(0.12))
                            .frame(height: 0.5),
                        alignment: .top
                    )
                    .ignoresSafeArea(edges: .bottom)
            )
        }
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
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(HapticButtonStyle(style: .light))
    }

    private func safeAreaBottom() -> CGFloat {
        let scenes = UIApplication.shared.connectedScenes
        let windowScene = scenes.first as? UIWindowScene
        return windowScene?.windows.first?.safeAreaInsets.bottom ?? 0
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

                HStack(spacing: 12) {
                    thumbButton(type: "up")
                    thumbButton(type: "down")
                    Spacer()
                    Text("Was this accurate?")
                        .font(.fcCaption)
                        .foregroundColor(.fcTextSecondary)
                }

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
        do {
            try await appState.aiService.rateOutfit(body: body)
            await MainActor.run {
                ratingSubmitted = true
                isSubmittingRating = false
            }
        } catch {
            print("[ResultView] rateOutfit failed: \(error.localizedDescription)")
            await MainActor.run {
                isSubmittingRating = false
                actionError = "Couldn't submit feedback. Try again."
            }
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
                    lensChip(goal: appState.currentUser.map { StyleGoal(rawValue: $0.defaultStyleGoal) ?? .genZ } ?? .genZ,
                             score: analysis.genZScore,
                             isSelected: true)

                    lensChip(goal: .genZ, score: analysis.genZScore, isSelected: false)

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
        Button(action: { showPremiumLocal = true }) {
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

// MARK: - Full-screen Upgrade Preview

/// Identifiable wrapper so the tapped image can drive `.fullScreenCover(item:)`.
private struct UpgradePreviewItem: Identifiable {
    let id = UUID()
    let source: UpgradeImageSource
}

/// Full-screen viewer for a tapped generated look: black backdrop, pinch- and
/// double-tap-to-zoom, drag-to-pan when zoomed, and a close button. Renders either
/// a remote (OpenAI/Storage) URL or in-memory (Gemini) image bytes.
private struct UpgradePreviewViewer: View {
    let source: UpgradeImageSource
    let onClose: () -> Void

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            imageView
                .scaleEffect(scale)
                .offset(offset)
                .gesture(magnification)
                .simultaneousGesture(panWhenZoomed)
                .onTapGesture(count: 2) { toggleZoom() }

            VStack {
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(Color.black.opacity(0.45)))
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
    }

    @ViewBuilder
    private var imageView: some View {
        switch source {
        case .remote(let url):
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFit()
                case .empty:            ProgressView().tint(.white)
                default:                Image(systemName: "photo").font(.largeTitle).foregroundColor(.white.opacity(0.6))
                }
            }
        case .data(let data):
            if let ui = UIImage(data: data) {
                Image(uiImage: ui).resizable().scaledToFit()
            } else {
                Image(systemName: "photo").font(.largeTitle).foregroundColor(.white.opacity(0.6))
            }
        }
    }

    private var magnification: some Gesture {
        MagnificationGesture()
            .onChanged { value in scale = min(max(lastScale * value, 1), 4) }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1 {
                    withAnimation(.spring(response: 0.3)) { offset = .zero; lastOffset = .zero }
                }
            }
    }

    private var panWhenZoomed: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                offset = CGSize(width: lastOffset.width + value.translation.width,
                                height: lastOffset.height + value.translation.height)
            }
            .onEnded { _ in lastOffset = offset }
    }

    private func toggleZoom() {
        withAnimation(.spring(response: 0.3)) {
            if scale > 1 {
                scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero
            } else {
                scale = 2; lastScale = 2
            }
        }
    }
}
