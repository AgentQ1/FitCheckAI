import SwiftUI
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage

// MARK: - Navigation Reference
//
// Lightweight, Identifiable handle used to push AnalysisDetailView via
// `.navigationDestination(item:)`. Carries the analysisId plus any already-loaded
// thumbnail/score so the detail header can render instantly while the full document
// loads. (analysisId == fitCheckID — the app's analyses ARE its fit_checks docs.)
struct AnalysisRef: Identifiable, Hashable {
    let id: String
    var thumbnailURL: String?
    var score: Double?
}

// MARK: - Analysis Detail

/// Full analysis detail for one exact outfit check: original photo, score, style
/// category, feedback breakdown, and the AI Upgrade History tied to THIS analysis.
/// Reached by tapping the Home Latest Look card or any History grid item.
struct AnalysisDetailView: View {
    let analysisId: String
    var initialThumbnailURL: String?
    var initialScore: Double?

    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var detail: AnalysisDetail?
    @State private var upgrades: [GeneratedUpgrade] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var actionError: String?

    @State private var carouselIndex = 0
    @State private var fullScreenImage: ImageURLItem?

    private var uid: String? { Auth.auth().currentUser?.uid }
    private let db = Firestore.firestore()

    var body: some View {
        ZStack {
            Color.fcBackground.ignoresSafeArea()

            if isLoading && detail == nil {
                ProgressView().tint(.fcAccent).scaleEffect(1.2)
            } else if let loadError, detail == nil {
                errorState(loadError)
            } else {
                content
            }
        }
        .navigationTitle("Analysis")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.fcBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task { await load() }
        .onAppear { appState.hideTabBar = true }
        .onDisappear { appState.hideTabBar = false }
        .fullScreenCover(item: $fullScreenImage) { item in
            FullScreenImageViewer(urlString: item.urlString) { fullScreenImage = nil }
        }
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                photoHeader
                scoreSection
                feedbackSection
                ArenaCTACard(fitID: analysisId)
                    .environmentObject(appState)
                upgradeHistorySection
                if let actionError {
                    inlineError(actionError)
                }
                Spacer(minLength: 40)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
        }
    }

    // MARK: Photo header

    private var photoHeader: some View {
        let urlString = detail?.originalImageURL ?? initialThumbnailURL
        let source: OutfitImageSource? = urlString.flatMap(URL.init).map { .remote($0) }
        return ZStack(alignment: .topTrailing) {
            PortraitOutfitImage(source: source)
                .frame(maxWidth: .infinity)
                .frame(height: photoHeight)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture {
                    if let urlString { fullScreenImage = ImageURLItem(urlString: urlString) }
                }
                .overlay(alignment: .bottomTrailing) {
                    if source != nil { expandHint.padding(10) }
                }

            if let score = detail?.overallScore ?? initialScore {
                ScoreBadge(score: score, fontSize: 15)
                    .padding(14)
            }
        }
    }

    /// Fixed, screen-proportional header height. Capped at 430 so wide/landscape/group
    /// photos never balloon the layout; the full outfit is fit (not cropped) inside.
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

    // MARK: Score + verdict + style category

    @ViewBuilder
    private var scoreSection: some View {
        if let detail {
            VStack(spacing: 14) {
                if let score = detail.overallScore {
                    ScoreRingView(score: score, size: 110)
                }
                if let verdict = detail.verdict, !verdict.isEmpty {
                    VerdictBadge(verdict: verdict)
                }
                if let style = detail.styleCategory, !style.isEmpty {
                    Text("You're giving: \(style)")
                        .font(.fcBodyBold)
                        .foregroundColor(.fcTextPrimary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(20)
            .background(Color.fcSurface)
            .cornerRadius(20)
            .shadow(color: Color.fcShadow, radius: 16, y: 6)
        }
    }

    // MARK: Feedback breakdown

    @ViewBuilder
    private var feedbackSection: some View {
        if let detail, !(detail.whatWorks.isEmpty && detail.whatToImprove.isEmpty && (detail.bestOneChange ?? "").isEmpty) {
            VStack(alignment: .leading, spacing: 16) {
                FCSectionTitle(text: "Feedback")

                if !detail.whatWorks.isEmpty {
                    feedbackList(title: "What works", items: detail.whatWorks,
                                 icon: "checkmark.circle.fill", color: .fcSuccess)
                }
                if !detail.whatToImprove.isEmpty {
                    feedbackList(title: "What to improve", items: detail.whatToImprove,
                                 icon: "arrow.up.circle.fill", color: .fcWarning)
                }
                if let best = detail.bestOneChange, !best.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Biggest win")
                            .font(.fcTag)
                            .foregroundColor(.fcAccent)
                        Text(best)
                            .font(.fcBody)
                            .foregroundColor(.fcTextPrimary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color.fcAccent.opacity(0.08))
                    .cornerRadius(12)
                }
            }
            .padding(16)
            .background(Color.fcSurface)
            .cornerRadius(20)
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

    // MARK: AI Upgrade History

    private var upgradeHistorySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                FCSectionTitle(text: "AI Upgrade History")
                Spacer()
                if !upgrades.isEmpty {
                    Text("\(upgrades.count)")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.fcTextSecondary)
                }
            }

            if upgrades.isEmpty {
                upgradeEmptyState
            } else {
                upgradeCarousel
            }
        }
        .padding(16)
        .background(Color.fcSurface)
        .cornerRadius(20)
        .shadow(color: Color.fcShadow, radius: 16, y: 6)
    }

    private var upgradeEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 40))
                .foregroundColor(.fcGold.opacity(0.7))
            Text("No AI upgrade history for this look yet.")
                .font(.fcBody)
                .foregroundColor(.fcTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background(Color.fcSurface2)
        .cornerRadius(16)
    }

    private var upgradeCarousel: some View {
        VStack(spacing: 10) {
            TabView(selection: $carouselIndex) {
                ForEach(Array(upgrades.enumerated()), id: \.element.id) { index, upgrade in
                    upgradeSlide(upgrade)
                        .tag(index)
                }
            }
            .frame(height: 460)
            .tabViewStyle(.page(indexDisplayMode: .never))

            if upgrades.count > 1 {
                HStack(spacing: 6) {
                    ForEach(Array(upgrades.enumerated()), id: \.offset) { i, _ in
                        Circle()
                            .fill(i == carouselIndex ? Color.fcGold : Color.fcTextSecondary.opacity(0.3))
                            .frame(width: 7, height: 7)
                    }
                    Text("\(min(carouselIndex + 1, upgrades.count))/\(upgrades.count)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.fcTextSecondary)
                        .padding(.leading, 6)
                }
            }
        }
    }

    private func upgradeSlide(_ upgrade: GeneratedUpgrade) -> some View {
        ZStack(alignment: .topLeading) {
            Color.fcSurface2
            if let url = URL(string: upgrade.imageURL) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFit()  // aspectFit — full image, no aggressive crop
                    case .failure:
                        slideBroken
                    default:
                        ProgressView().tint(.fcGold)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                slideBroken
            }

            // Small timestamp label for this generated look.
            Text(upgrade.formattedCreatedAt)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.black.opacity(0.45)))
                .padding(10)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 460)
        .background(Color.fcSurface2)
        .clipped()
        .cornerRadius(18)
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.fcGold.opacity(0.25), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { fullScreenImage = ImageURLItem(urlString: upgrade.imageURL) }
    }

    private var slideBroken: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo")
                .font(.system(size: 32))
                .foregroundColor(.fcTextSecondary.opacity(0.6))
            Text("Image unavailable")
                .font(.fcCaption)
                .foregroundColor(.fcTextSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Misc UI

    private func inlineError(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.fcWarning)
            Text(message).font(.fcCaption).foregroundColor(.fcTextPrimary)
            Spacer()
            Button(action: { actionError = nil }) {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundColor(.fcTextSecondary)
            }
        }
        .padding(12)
        .background(Color.fcWarning.opacity(0.15))
        .cornerRadius(10)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundColor(.fcWarning)
            Text("Couldn't load this look")
                .font(.fcTitle)
                .foregroundColor(.fcTextPrimary)
            Text(message)
                .font(.fcCaption)
                .foregroundColor(.fcTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Retry") { Task { await load() } }
                .buttonStyle(SecondaryButtonStyle())
                .padding(.top, 8)
        }
    }

    // MARK: - Data

    @MainActor
    private func load() async {
        guard let uid else { isLoading = false; loadError = "Not signed in."; return }
        print("[AnalysisDetail] opened AnalysisDetailView with analysisId=\(analysisId)")
        isLoading = true
        loadError = nil
        do {
            let snap = try await db.collection("users").document(uid)
                .collection("fit_checks").document(analysisId).getDocuments_orGet()
            guard let data = snap, !(data["isDeleted"] as? Bool ?? false) else {
                print("[AnalysisDetail] fetched analysis FAILURE — not found analysisId=\(analysisId)")
                loadError = "This look is no longer available."
                isLoading = false
                return
            }
            var built = AnalysisDetail(id: analysisId, data: data)
            // thumbnailURL can be an expired signed URL; resolve a fresh one from the
            // private storage path when we have no usable image URL.
            if built.originalImageURL == nil, let path = built.storagePath {
                built.originalImageURL = try? await Storage.storage().reference(withPath: path).downloadURL().absoluteString
            }
            detail = built
            print("[AnalysisDetail] fetched analysis SUCCESS analysisId=\(analysisId) score=\(built.overallScore.map { String($0) } ?? "nil")")
            isLoading = false

            await reloadUpgrades(uid: uid)
        } catch {
            print("[AnalysisDetail] fetched analysis FAILURE analysisId=\(analysisId): \(error.localizedDescription)")
            loadError = error.localizedDescription
            isLoading = false
        }
    }

    @MainActor
    private func reloadUpgrades(uid: String) async {
        do {
            let items = try await UpgradeHistoryService.fetchGeneratedUpgrades(uid: uid, analysisId: analysisId)
            upgrades = items
            if carouselIndex >= items.count { carouselIndex = max(0, items.count - 1) }
        } catch {
            print("[AnalysisDetail] fetch upgrades failed: \(error.localizedDescription)")
            actionError = "Couldn't load upgrade history."
        }
    }

}

// MARK: - Display Model

/// Read-side projection of a `fit_checks` document. Parsed manually (not Codable)
/// because Firestore stores camelCase top-level fields while nested objects keep the
/// AI's snake_case keys — a single Codable shape can't cleanly cover both.
private struct AnalysisDetail {
    let id: String
    var originalImageURL: String?
    let storagePath: String?
    let overallScore: Double?
    let styleCategory: String?
    let verdict: String?
    let whatWorks: [String]
    let whatToImprove: [String]
    let bestOneChange: String?

    init(id: String, data: [String: Any]) {
        self.id = id
        self.storagePath = data["storagePath"] as? String
        self.originalImageURL = data["thumbnailURL"] as? String
        self.overallScore = data["overallScore"] as? Double ?? data["overall_score"] as? Double
        self.styleCategory = data["stylePersonality"] as? String ?? data["style_personality"] as? String
        self.verdict = data["verdict"] as? String
        self.whatWorks = data["whatWorks"] as? [String] ?? data["what_works"] as? [String] ?? []
        self.whatToImprove = data["whatToImprove"] as? [String] ?? data["what_to_improve"] as? [String] ?? []
        self.bestOneChange = data["bestOneChange"] as? String ?? data["best_one_change"] as? String
    }
}

// MARK: - Identifiable wrappers

private struct ImageURLItem: Identifiable {
    let id = UUID()
    let urlString: String
}

// MARK: - Full-screen viewer

/// Black-backdrop full-screen viewer with pinch / double-tap zoom for a tapped
/// remote upgrade image.
private struct FullScreenImageViewer: View {
    let urlString: String
    let onClose: () -> Void

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFit()
                            .scaleEffect(scale)
                            .gesture(
                                MagnificationGesture()
                                    .onChanged { scale = min(max(lastScale * $0, 1), 4) }
                                    .onEnded { _ in lastScale = scale }
                            )
                            .onTapGesture(count: 2) {
                                withAnimation(.spring(response: 0.3)) {
                                    if scale > 1 { scale = 1; lastScale = 1 } else { scale = 2; lastScale = 2 }
                                }
                            }
                    case .empty:
                        ProgressView().tint(.white)
                    default:
                        Image(systemName: "photo").font(.largeTitle).foregroundColor(.white.opacity(0.6))
                    }
                }
            }
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
}

// MARK: - Firestore convenience

private extension DocumentReference {
    /// Fetches a document and returns its data dictionary (nil if it doesn't exist).
    /// Named to avoid colliding with the SDK's `getDocument`.
    func getDocuments_orGet() async throws -> [String: Any]? {
        let snap = try await getDocument()
        return snap.exists ? snap.data() : nil
    }
}
