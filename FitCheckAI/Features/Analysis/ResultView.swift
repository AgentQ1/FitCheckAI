import SwiftUI
import FirebaseAuth

struct ResultView: View {
    let analysis: OutfitAnalysis
    let outfitImage: UIImage?

    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var isFeedbackExpanded = false
    @State private var isSaved = false
    @State private var showShareSheet = false
    @State private var actionError: String?

    // AI Outfit Upgrade Preview — two-slot Gemini carousel. The store is OWNED by the
    // scan flow (CheckFlowViewModel) and injected here, so the generation pre-warmed
    // during analysis is consumed directly — ResultView never starts it from zero.
    @ObservedObject private var upgradeStore: OutfitUpgradeService
    @State private var carouselIndex = 0
    /// Tapped generated image, shown full-screen. nil = no preview open.
    @State private var previewItem: UpgradePreviewItem?
    /// Tapped ORIGINAL outfit photo, shown full-screen. nil = no viewer open.
    @State private var fullScreenPhoto: OutfitImageItem?

    init(analysis: OutfitAnalysis, outfitImage: UIImage?, upgradeStore: OutfitUpgradeService) {
        self.analysis = analysis
        self.outfitImage = outfitImage
        self._upgradeStore = ObservedObject(wrappedValue: upgradeStore)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.fcBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        if showReviewBanner {
                            reviewBanner
                                .padding(.horizontal, 20)
                                .padding(.bottom, 12)
                        }

                        photoCard
                            .padding(.horizontal, 20)

                        scoreCard
                            .padding(.horizontal, 20)
                            .padding(.top, 24)

                        lensScoreTeaser
                            .padding(.horizontal, 20)
                            .padding(.top, 20)

                        feedbackToggleCard
                            .padding(.horizontal, 20)
                            .padding(.top, 12)

                        outfitUpgradePreviewCard
                            .padding(.horizontal, 20)
                            .padding(.top, 12)
                            .padding(.bottom, 24)
                            // Auto-start (or adopt the already-prewarmed run) so the
                            // upgrade preview generates and shows on its own alongside the
                            // score — no "Generate" tap. Idempotent: deduped by analysis.id,
                            // so the scan flow's pre-warm isn't restarted.
                            .onAppear { startUpgradeGeneration() }
                    }
                    .padding(.top, 4)
                }

                stickyActionBar
            }
        }
        .navigationBarHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: [buildShareText()])
        }
        .fullScreenCover(item: $previewItem) { item in
            UpgradePreviewViewer(source: item.source) { previewItem = nil }
        }
        .fullScreenCover(item: $fullScreenPhoto) { item in
            OutfitImageViewer(source: item.source) { fullScreenPhoto = nil }
        }
        .onAppear {
            appState.analyticsService.track(.resultViewed)
        }
    }

    // MARK: - Top bar

    /// Navigation row matching AnalysisDetailView: circular close button on the
    /// left, centered "Analysis" title, sitting on the beige background below the
    /// status bar (no safe-area overlap).
    private var topBar: some View {
        ZStack {
            Text("Analysis")
                .font(.fcBodyBold)
                .foregroundColor(.fcTextPrimary)

            HStack {
                circleIconButton(systemName: "chevron.left") {
                    dismiss()
                    appState.showCheckFlow = false
                }
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private func circleIconButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.fcTextPrimary)
                .frame(width: 34, height: 34)
                .background(
                    Circle()
                        .fill(Color.fcSurface)
                        .overlay(Circle().stroke(Color.fcTextSecondary.opacity(0.15), lineWidth: 0.5))
                )
        }
        .buttonStyle(HapticButtonStyle(style: .light))
    }

    // MARK: - Subviews

    /// Show the "being reviewed before it appears publicly" notice only to a user who
    /// has opted into the public Arena AND whose fit hasn't been positively approved by
    /// moderation yet (pending/rejected). Private users never see it — their fit was
    /// never going public. (Apple Guideline 1.2: fail-closed public visibility.)
    private var showReviewBanner: Bool {
        (appState.currentUser?.isArenaPublic ?? false) && analysis.isAwaitingPublicReview
    }

    /// Friendly, non-accusatory banner: the fit is held back from public feeds until it
    /// passes review. Deliberately the same copy for pending and rejected so a false
    /// positive never accuses the user.
    private var reviewBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "clock.badge.checkmark")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.fcAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Your fit is being reviewed before it appears publicly.")
                    .font(.fcCaption)
                    .foregroundColor(.fcTextPrimary)
                Text("It’s saved to your history and only you can see it for now.")
                    .font(.fcCaption)
                    .foregroundColor(.fcTextSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.fcAccent.opacity(0.10))
        .cornerRadius(14)
    }

    /// Outfit photo in a rounded card with the score badge pinned to the top-right
    /// corner — matching AnalysisDetailView. Portrait-safe: the full body (head →
    /// shoes) is shown with `.scaledToFit()` over a blurred fill of the same photo,
    /// so nothing important is cropped. Tap to open the full-screen viewer.
    private var photoCard: some View {
        ZStack(alignment: .topTrailing) {
            PortraitOutfitImage(source: outfitImage.map { .uiImage($0) })
                .frame(maxWidth: .infinity)
                .frame(height: photoHeight)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture {
                    if let img = outfitImage {
                        fullScreenPhoto = OutfitImageItem(source: .uiImage(img))
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if outfitImage != nil { expandHint.padding(10) }
                }

            ScoreBadge(score: analysis.overallScore, fontSize: 15)
                .padding(14)
        }
    }

    /// Fixed, screen-proportional header height. Capped at 430 so wide/landscape/group
    /// photos never balloon the layout and the score ring below stays visible without
    /// massive scrolling. The image is fit (not cropped) inside this container.
    private var photoHeight: CGFloat {
        min(UIScreen.main.bounds.height * 0.42, 430)
    }

    /// Small affordance that the photo can be tapped to view full-screen.
    private var expandHint: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(.white)
            .padding(7)
            .background(Circle().fill(Color.black.opacity(0.45)))
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

    // MARK: - Feedback card (collapsible)

    /// Collapsed-by-default feedback. Only a compact toggle row ("Feedback" +
    /// hint + chevron) shows on load, keeping the AI Outfit Upgrade Preview within
    /// reach. Tapping expands the full feedback inline — "What works", "What to
    /// improve", and the "Biggest win" box — with a smooth spring animation, and
    /// tapping again collapses it. Same analysis data as before; UI-only.
    @ViewBuilder
    private var feedbackToggleCard: some View {
        if !(analysis.whatWorks.isEmpty && analysis.whatToImprove.isEmpty && analysis.bestOneChange.isEmpty) {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        isFeedbackExpanded.toggle()
                    }
                } label: {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Feedback")
                                .font(.fcTitle)
                                .foregroundColor(.fcTextPrimary)
                            Text(isFeedbackExpanded
                                 ? "Tap to hide feedback"
                                 : "Tap to check what works and what to improve")
                                .font(.fcCaption)
                                .foregroundColor(.fcTextSecondary)
                        }

                        Spacer(minLength: 0)

                        Image(systemName: isFeedbackExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.fcTextSecondary)
                    }
                    .padding(20)
                    .contentShape(Rectangle())
                }
                .buttonStyle(HapticButtonStyle(style: .light))

                if isFeedbackExpanded {
                    feedbackContent
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.fcSurface)
            .cornerRadius(20)
            .shadow(color: Color.fcShadow, radius: 16, y: 6)
        }
    }

    /// Expanded feedback body. Mirrors the History AnalysisDetailView feedback
    /// section: "What works" with green checks, "What to improve" with gold
    /// up-arrows, and a rounded "Biggest win" box. The "Feedback" title lives in
    /// the toggle header above, so it isn't repeated here.
    private var feedbackContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !analysis.whatWorks.isEmpty {
                feedbackList(title: "What works", items: analysis.whatWorks,
                             icon: "checkmark.circle.fill", color: .fcSuccess)
            }
            if !analysis.whatToImprove.isEmpty {
                feedbackList(title: "What to improve", items: analysis.whatToImprove,
                             icon: "arrow.up.circle.fill", color: .fcWarning)
            }
            if !analysis.bestOneChange.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Biggest win")
                        .font(.fcTag)
                        .foregroundColor(.fcAccent)
                    Text(analysis.bestOneChange)
                        .font(.fcBody)
                        .foregroundColor(.fcTextPrimary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color.fcAccent.opacity(0.08))
                .cornerRadius(12)
            }
        }
    }

    private func feedbackList(title: String, items: [String], icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.fcBodyBold)
                .foregroundColor(.fcTextPrimary)
            ForEach(Array(items.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 14))
                        .foregroundColor(color)
                        .padding(.top, 2)
                    Text(line)
                        .font(.fcBody)
                        .foregroundColor(.fcTextSecondary)
                }
            }
        }
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

    /// Resumes (or, only if the scan flow didn't pre-warm, starts) the two-slot
    /// Gemini generation. Generation is normally kicked off the instant analysis
    /// returns (CheckFlowViewModel.runAnalysis), so this `.task` call is an
    /// idempotent no-op that simply adopts the in-flight/finished run. It still
    /// works as a fallback if ResultView is shown without a pre-warm. Each generated
    /// look is persisted under this analysis's upgrade history (analysis.id ==
    /// the fit_checks doc id == AnalysisDetailView's analysisId) so it survives
    /// re-opening from History/Latest Look.
    private func startUpgradeGeneration(force: Bool = false) {
        upgradeStore.startForAnalysis(
            analysis,
            persistUID: Auth.auth().currentUser?.uid,
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
            .padding(.top, 6)
            .padding(.bottom, max(safeAreaBottom(), 8))
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
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(HapticButtonStyle(style: .light))
    }

    private func safeAreaBottom() -> CGFloat {
        let scenes = UIApplication.shared.connectedScenes
        let windowScene = scenes.first as? UIWindowScene
        return windowScene?.windows.first?.safeAreaInsets.bottom ?? 0
    }

    private func buildShareText() -> String {
        let score = String(format: "%.1f", analysis.overallScore)
        return "Just got a \(score)/10 fit score on FitCheck AI! 🔥 The AI said: \"\(analysis.whatWorks.first ?? "looking clean!")\" Download the app to rate your own outfit."
    }

    private var lensScoreTeaser: some View {
        // The user's chosen lens leads the row; every other lens appears exactly
        // once after it (no duplicate Gen Z chip). Each chip shows the score that
        // actually matches its goal via `score(for:)` — never a hardcoded
        // genZScore — so the rating under each label is always logical.
        let selectedGoal = appState.currentUser
            .map { StyleGoal(rawValue: $0.defaultStyleGoal) ?? .genZ } ?? .genZ
        let otherGoals = StyleGoal.allCases.filter { $0 != selectedGoal }

        return VStack(alignment: .leading, spacing: 12) {
            Text("Style Lens Preview")
                .font(.fcBodyBold)
                .foregroundColor(.fcTextPrimary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    // The selected lens is always unlocked with its real score.
                    lensChip(goal: selectedGoal,
                             score: analysis.score(for: selectedGoal),
                             isSelected: true)

                    // Free users see the remaining lenses locked behind premium;
                    // premium users see each with its real score.
                    ForEach(otherGoals, id: \.self) { goal in
                        if appState.isPremium {
                            lensChip(goal: goal, score: analysis.score(for: goal), isSelected: false)
                        } else {
                            lockedLensChip(goal: goal)
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
