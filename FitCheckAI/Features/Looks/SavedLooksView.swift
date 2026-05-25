import SwiftUI
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage

struct SavedLooksView: View {
    @EnvironmentObject var appState: AppState
    @State private var filter: LooksFilter = .all
    @State private var allSaved: [OutfitSummary] = []
    @State private var allLiked: [OutfitSummary] = []
    @State private var isLoading = true
    @State private var searchText = ""
    @State private var showSearch = false

    private let db = Firestore.firestore()

    enum LooksFilter: String, CaseIterable {
        case all = "All"
        case saved = "Saved"
        case liked = "Liked"
        case thisWeek = "This Week"
    }

    var displayedLooks: [OutfitSummary] {
        var result: [OutfitSummary]
        switch filter {
        case .all:      result = (allSaved + allLiked).uniqued()
        case .saved:    result = allSaved
        case .liked:    result = allLiked
        case .thisWeek:
            let weekStart = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
            result = (allSaved + allLiked).uniqued().filter { $0.createdAt >= weekStart }
        }
        if !searchText.isEmpty {
            result = result.filter {
                ($0.styleGoal ?? "").localizedCaseInsensitiveContains(searchText)
            }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.fcBackground.ignoresSafeArea()
                VStack(spacing: 0) {
                    headerView
                    if showSearch {
                        searchBar
                            .padding(.horizontal, 20)
                            .padding(.bottom, 12)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    filterChips
                    if isLoading {
                        loadingView
                    } else if displayedLooks.isEmpty {
                        emptyState
                    } else {
                        looksGrid
                    }
                }
            }
        }
        .task { await loadAll() }
        .refreshable { await loadAll() }
    }

    // MARK: - Subviews

    private var headerView: some View {
        HStack {
            Text("My Looks")
                .font(.fcHeading)
                .foregroundColor(.fcTextPrimary)
            Spacer()
            Button(action: {
                withAnimation(.spring(response: 0.3)) { showSearch.toggle() }
            }) {
                Image(systemName: showSearch ? "xmark" : "magnifyingglass")
                    .font(.system(size: 18))
                    .foregroundColor(.fcTextPrimary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.fcTextSecondary)
            TextField("Search by style...", text: $searchText)
                .font(.fcBody)
                .foregroundColor(.fcTextPrimary)
                .tint(.fcAccent)
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.fcTextSecondary)
                }
            }
        }
        .padding(12)
        .background(Color.fcSurface)
        .cornerRadius(12)
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(LooksFilter.allCases, id: \.self) { f in
                    Button(f.rawValue) {
                        withAnimation(.spring(response: 0.3)) { filter = f }
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(filter == f ? .fcBackground : .fcTextSecondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(filter == f ? Color.fcAccent : Color.fcSurface)
                    .cornerRadius(20)
                }
            }
            .padding(.horizontal, 20)
        }
        .padding(.bottom, 16)
    }

    private var looksGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(displayedLooks) { look in
                    OutfitCard(outfit: look)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 100)
        }
    }

    private var loadingView: some View {
        VStack {
            Spacer()
            ProgressView().tint(.fcAccent).scaleEffect(1.2)
            Spacer()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "photo.stack")
                .font(.system(size: 60))
                .foregroundColor(.fcTextSecondary.opacity(0.3))
            Text(emptyTitle)
                .font(.fcTitle)
                .foregroundColor(.fcTextPrimary)
            Text(emptySubtitle)
                .font(.fcBody)
                .foregroundColor(.fcTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
    }

    private var emptyTitle: String {
        switch filter {
        case .all:      return "No saved looks yet."
        case .saved:    return "Nothing saved yet."
        case .liked:    return "No liked looks yet."
        case .thisWeek: return "Nothing this week."
        }
    }

    private var emptySubtitle: String {
        switch filter {
        case .all, .saved: return "Save outfit checks to revisit them here."
        case .liked:       return "Tap the heart on a fit check result to like it."
        case .thisWeek:    return "No outfits saved in the last 7 days."
        }
    }

    // MARK: - Data Loading

    func loadAll() async {
        guard let uid = Auth.auth().currentUser?.uid else {
            await MainActor.run { isLoading = false }
            return
        }
        async let savedTask: Void = loadSaved(uid: uid)
        async let likedTask: Void = loadLiked(uid: uid)
        _ = await (savedTask, likedTask)
        await MainActor.run { isLoading = false }
    }

    private func loadSaved(uid: String) async {
        do {
            let snap = try await db.collection("users/\(uid)/saved_looks")
                .order(by: "savedAt", descending: true)
                .getDocuments()
            var results: [OutfitSummary] = []
            for doc in snap.documents {
                let data = doc.data()
                let fitCheckId = data["fitCheckId"] as? String ?? doc.documentID
                let score = data["overallScore"] as? Double ?? data["overall_score"] as? Double
                let goal = data["styleGoal"] as? String ?? data["style_goal"] as? String
                let date = (data["savedAt"] as? Timestamp)?.dateValue() ?? Date()
                let thumbURL = await getThumbURL(uid: uid, fitCheckId: fitCheckId)
                results.append(OutfitSummary(id: fitCheckId, thumbnailURL: thumbURL, overallScore: score, styleGoal: goal, createdAt: date))
            }
            await MainActor.run { allSaved = results }
        } catch {
            await MainActor.run { allSaved = [] }
        }
    }

    private func loadLiked(uid: String) async {
        do {
            let snap = try await db.collection("users/\(uid)/fit_checks")
                .whereField("liked", isEqualTo: true)
                .whereField("isDeleted", isEqualTo: false)
                .order(by: "createdAt", descending: true)
                .getDocuments()
            var results: [OutfitSummary] = []
            for doc in snap.documents {
                let data = doc.data()
                let score = data["overall_score"] as? Double ?? data["overallScore"] as? Double
                let goal = data["styleGoal"] as? String ?? data["style_goal"] as? String
                let date = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
                let path = data["storagePath"] as? String
                var thumbURL: String?
                if let p = path, let url = try? await Storage.storage().reference(withPath: p).downloadURL() {
                    thumbURL = url.absoluteString
                }
                results.append(OutfitSummary(id: doc.documentID, thumbnailURL: thumbURL, overallScore: score, styleGoal: goal, createdAt: date))
            }
            await MainActor.run { allLiked = results }
        } catch {
            await MainActor.run { allLiked = [] }
        }
    }

    private func getThumbURL(uid: String, fitCheckId: String) async -> String? {
        let path = "users/\(uid)/fit-checks/\(fitCheckId)/original"
        return try? await Storage.storage().reference(withPath: path).downloadURL().absoluteString
    }
}

// MARK: - Array unique helper

extension Array where Element: Identifiable {
    func uniqued() -> [Element] {
        var seen = Set<AnyHashable>()
        return filter { element in
            guard let id = element.id as? AnyHashable else { return true }
            return seen.insert(id).inserted
        }
    }
}
