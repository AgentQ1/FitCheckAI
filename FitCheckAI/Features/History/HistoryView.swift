import SwiftUI
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage

/// Full chronological history of every outfit the user has uploaded.
/// Reached from Home by tapping the stacked Latest Look card.
struct HistoryView: View {
    @EnvironmentObject var appState: AppState
    @State private var items: [HistoryItem] = []
    @State private var isLoading: Bool = true
    @State private var loadError: String?

    private let db = Firestore.firestore()
    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        ZStack {
            Color.fcBackground.ignoresSafeArea()

            if isLoading {
                ProgressView().tint(.fcAccent).scaleEffect(1.2)
            } else if let loadError {
                errorState(loadError)
            } else if items.isEmpty {
                EmptyStateView(
                    icon: "camera.viewfinder",
                    title: "No outfit checks yet",
                    subtitle: "Your uploads will appear here after your first fit check."
                )
                .padding(.bottom, 80)
            } else {
                grid
            }
        }
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.large)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(Color.fcBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task { await load() }
        .refreshable { await load() }
        .onAppear { appState.hideTabBar = true }
        .onDisappear { appState.hideTabBar = false }
    }

    // MARK: - Subviews

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(items) { item in
                    NavigationLink {
                        AnalysisDetailView(analysisId: item.id,
                                           initialThumbnailURL: item.thumbnailURL,
                                           initialScore: item.score)
                            .environmentObject(appState)
                    } label: {
                        HistoryCell(item: item)
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture().onEnded {
                        print("[HistoryView] tapped analysisId=\(item.id)")
                    })
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundColor(.fcWarning)
            Text("Couldn't load history")
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
        guard let uid = Auth.auth().currentUser?.uid else {
            isLoading = false
            return
        }
        isLoading = items.isEmpty // keep grid visible on pull-to-refresh
        loadError = nil
        do {
            // Only the latest N checks are kept — storage stays bounded (older,
            // unsaved analyses are pruned by cleanupUserAnalysisHistory).
            let snapshot = try await db.collection("users/\(uid)/fit_checks")
                .whereField("isDeleted", isEqualTo: false)
                .order(by: "createdAt", descending: true)
                .limit(to: Config.maxHistoryItems)
                .getDocuments()

            let loaded: [HistoryItem] = await withTaskGroup(of: HistoryItem?.self) { group in
                for doc in snapshot.documents {
                    group.addTask {
                        let data = doc.data()
                        let storagePath = data["storagePath"] as? String
                        let cachedThumb = data["thumbnailURL"] as? String
                        let score = data["overall_score"] as? Double ?? data["overallScore"] as? Double
                        let goal = data["styleGoal"] as? String ?? data["style_goal"] as? String
                        let liked = data["liked"] as? Bool ?? false
                        let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()

                        var thumbURL: String? = cachedThumb
                        if thumbURL == nil, let path = storagePath {
                            if let url = try? await Storage.storage().reference(withPath: path).downloadURL() {
                                thumbURL = url.absoluteString
                            }
                        }

                        return HistoryItem(
                            id: doc.documentID,
                            thumbnailURL: thumbURL,
                            score: score,
                            styleGoal: goal,
                            liked: liked,
                            createdAt: createdAt
                        )
                    }
                }
                var out: [(Date, HistoryItem)] = []
                for await item in group { if let item { out.append((item.createdAt, item)) } }
                return out.sorted { $0.0 > $1.0 }.map { $0.1 }
            }
            items = loaded
            isLoading = false
            // Opening History is a good moment to prune old, unsaved history/upgrades.
            Task.detached { await UpgradeHistoryService.cleanupUserAnalysisHistory(uid: uid) }
        } catch {
            loadError = error.localizedDescription
            isLoading = false
        }
    }
}

// MARK: - Models

struct HistoryItem: Identifiable {
    let id: String
    let thumbnailURL: String?
    let score: Double?
    let styleGoal: String?
    let liked: Bool
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

    /// Short qualitative status derived from score; falls back to a neutral label.
    var statusLabel: String {
        guard let score else { return "Awaiting" }
        switch score {
        case 9.0...: return "Excellent"
        case 7.0..<9.0: return "Strong"
        case 5.0..<7.0: return "Decent"
        default: return "Needs work"
        }
    }

    var statusColor: Color {
        guard let score else { return .fcTextSecondary }
        return Color.scoreColor(for: score)
    }
}

// MARK: - Cell

private struct HistoryCell: View {
    let item: HistoryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let url = URL(string: item.thumbnailURL ?? "") {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let img):
                                img.resizable().scaledToFill()
                            case .failure:
                                placeholder
                            default:
                                Color.fcSurface2.overlay(ProgressView().tint(.fcTextSecondary))
                            }
                        }
                    } else {
                        placeholder
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(3.0/4.0, contentMode: .fit)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                if let score = item.score {
                    ScoreBadge(score: score, fontSize: 12)
                        .padding(8)
                }

                if item.liked {
                    HStack(spacing: 3) {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .padding(6)
                    .background(Color.fcError)
                    .clipShape(Circle())
                    .padding(.top, 36) // sit just under the score badge
                    .padding(.trailing, 8)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(item.formattedDate)
                    .font(.fcCaption)
                    .foregroundColor(.fcTextSecondary)
                if let goal = item.styleGoal {
                    Text(StyleGoal(rawValue: goal)?.displayName ?? goal)
                        .font(.fcTag)
                        .foregroundColor(.fcTextPrimary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Circle()
                        .fill(item.statusColor)
                        .frame(width: 6, height: 6)
                    Text(item.statusLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.fcTextSecondary)
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, 2)
        }
    }

    private var placeholder: some View {
        ZStack {
            Color.fcSurface
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 30))
                .foregroundColor(.fcTextSecondary.opacity(0.4))
        }
    }
}
