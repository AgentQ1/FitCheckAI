import SwiftUI
import FirebaseAuth
import FirebaseFirestore

// MARK: - View Model

@MainActor
final class MyArenaResultsViewModel: ObservableObject {
    struct Item: Identifiable {
        let fitID: String
        let imageURL: String?
        let aiScore: Double?
        let hotFitCount: Int
        let commentCount: Int
        let isTodayFinalist: Bool
        let todayRank: Int?
        let isWeekFinalist: Bool
        let weekRank: Int?
        let status: String
        var id: String { fitID }

        /// A short badge describing the fit's current standing, if any.
        var finalistBadge: String? {
            if isTodayFinalist, let r = todayRank { return "#\(r) Today" }
            if isWeekFinalist, let r = weekRank { return "#\(r) This Week" }
            return nil
        }
    }

    @Published var items: [Item] = []
    @Published var isLoading = true
    @Published var errorMessage: String?

    private let db = Firestore.firestore()

    func load() async {
        guard let uid = Auth.auth().currentUser?.uid else { isLoading = false; return }
        isLoading = true
        errorMessage = nil
        do {
            // Single-field equality on ownerUid (no composite index); sort in memory.
            let snap = try await db.collection("rateArena")
                .whereField("ownerUid", isEqualTo: uid)
                .getDocuments()

            items = snap.documents
                .map { d -> Item in
                    let x = d.data()
                    return Item(
                        fitID: d.documentID,
                        imageURL: x["imageURL"] as? String,
                        aiScore: x["aiScore"] as? Double,
                        hotFitCount: x["hotFitCount"] as? Int ?? 0,
                        commentCount: x["commentCount"] as? Int ?? 0,
                        isTodayFinalist: x["isTodayFinalist"] as? Bool ?? false,
                        todayRank: x["todayRank"] as? Int,
                        isWeekFinalist: x["isWeekFinalist"] as? Bool ?? false,
                        weekRank: x["weekRank"] as? Int,
                        status: x["status"] as? String ?? "live"
                    )
                }
                .filter { $0.status != "removed" }
                .sorted { ($0.hotFitCount, $0.aiScore ?? 0) > ($1.hotFitCount, $1.aiScore ?? 0) }
            isLoading = false
        } catch {
            errorMessage = "Couldn't load your Arena fits."
            isLoading = false
        }
    }
}

// MARK: - View

/// "My Arena Fits" — every fit the user has posted to the Arena, with its live
/// public standing: Hot Fit count, comments, and whether it's currently a Top 3
/// finalist for today or the week. Reachable from Profile.
struct MyArenaResultsView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = MyArenaResultsViewModel()

    var body: some View {
        ZStack {
            Color.fcBackground.ignoresSafeArea()

            if vm.isLoading {
                ProgressView().tint(.fcAccent).scaleEffect(1.2)
            } else if vm.items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        if let err = vm.errorMessage {
                            Text(err).font(.fcCaption).foregroundColor(.fcError)
                        }
                        ForEach(vm.items) { item in
                            NavigationLink {
                                AnalysisDetailView(analysisId: item.fitID,
                                                   initialThumbnailURL: item.imageURL,
                                                   initialScore: item.aiScore)
                                    .environmentObject(appState)
                            } label: {
                                row(item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 100)
                }
            }
        }
        .navigationTitle("My Arena Fits")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.fcBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .onAppear { appState.hideTabBar = true }
        .onDisappear { appState.hideTabBar = false }
        .task { await vm.load() }
    }

    private func row(_ item: MyArenaResultsViewModel.Item) -> some View {
        HStack(spacing: 14) {
            thumbnail(item.imageURL)
                .frame(width: 64, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("In the Arena ⚔️").font(.fcBodyBold).foregroundColor(.fcTextPrimary)
                    if let badge = item.finalistBadge {
                        Text(badge)
                            .font(.system(size: 11, weight: .bold)).foregroundColor(.white)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.fcAccent, in: Capsule())
                    }
                }
                HStack(spacing: 12) {
                    statLabel(icon: "flame.fill", tint: .fcAccent, text: "\(item.hotFitCount) Hot Fits")
                    statLabel(icon: "bubble.left", tint: .fcTextSecondary, text: "\(item.commentCount)")
                }
                if let ai = item.aiScore {
                    Text("AI \(String(format: "%.1f", ai))")
                        .font(.system(size: 11, weight: .semibold)).foregroundColor(.fcTextSecondary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold)).foregroundColor(.fcTextSecondary)
        }
        .padding(12)
        .background(Color.fcSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Color.fcShadow, radius: 8, y: 3)
    }

    private func statLabel(icon: String, tint: Color, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 12)).foregroundColor(tint)
            Text(text).font(.fcCaption).foregroundColor(.fcTextSecondary)
        }
    }

    @ViewBuilder
    private func thumbnail(_ urlString: String?) -> some View {
        if let urlString, let url = URL(string: urlString) {
            SmartOutfitImageView(source: .remote(url))
        } else {
            PortraitOutfitPlaceholder()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "flame")
                .font(.system(size: 48)).foregroundColor(.fcAccent)
            Text("No Arena fits yet")
                .font(.fcTitle).foregroundColor(.fcTextPrimary)
            Text("Score 6.5+ on a fit and it automatically enters the Arena to compete for the community Top 3.")
                .font(.fcBody).foregroundColor(.fcTextSecondary)
                .multilineTextAlignment(.center)
            Button {
                appState.showCheckFlow = true
            } label: {
                Label("Check today's fit", systemImage: "camera.fill")
                    .font(.fcBodyBold).foregroundColor(.white)
                    .padding(.horizontal, 22).padding(.vertical, 14)
                    .background(Color.fcAccent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(HapticButtonStyle(style: .medium))
            .padding(.top, 4)
        }
        .padding(.horizontal, 36)
    }
}
