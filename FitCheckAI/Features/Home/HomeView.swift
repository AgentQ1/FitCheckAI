import SwiftUI
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage

struct HomeView: View {
    @EnvironmentObject var appState: AppState
    @State private var recentOutfits: [OutfitSummary] = []
    @State private var isLoadingOutfits = true
    @State private var currentTrend: WeeklyTrend?
    @State private var showTrends = false
    @State private var showCheckFlow = false

    private let db = Firestore.firestore()

    var body: some View {
        NavigationStack {
            ZStack {
                Color.fcBackground.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        headerSection
                        heroCard
                        if isLoadingOutfits {
                            loadingShimmer
                        } else if recentOutfits.isEmpty {
                            EmptyStateView(
                                icon: "camera.viewfinder",
                                title: "No looks yet.",
                                subtitle: "Add your first fit check!"
                            )
                        } else {
                            recentLooksSection
                        }
                        trendCardView
                        Spacer(minLength: 110)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                }
                .refreshable { await loadData() }
            }
            .navigationDestination(isPresented: $showTrends) {
                TrendsView().environmentObject(appState)
            }
        }
        .fullScreenCover(isPresented: $showCheckFlow) {
            CheckFlowView().environmentObject(appState)
        }
        .task { await loadData() }
    }

    // MARK: - Subviews

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Hey, there 👋")
                .font(.fcHeading)
                .foregroundColor(.fcTextPrimary)
            Text("Ready to check today's fit?")
                .font(.fcBody)
                .foregroundColor(.fcTextSecondary)
        }
    }

    private var heroCard: some View {
        Button(action: { showCheckFlow = true }) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Check today's fit.")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundColor(.fcTextPrimary)
                    checksRemainingLabel
                }
                Spacer()
                ZStack {
                    Circle()
                        .fill(Color.fcAccentCream)
                        .frame(width: 56, height: 56)
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.fcAccent)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 24)
            .background(Color.fcAccent2)
            .cornerRadius(26)
            .shadow(color: Color.fcShadow, radius: 18, x: 0, y: 8)
        }
        .buttonStyle(HapticButtonStyle(style: .medium))
    }

    @ViewBuilder
    private var checksRemainingLabel: some View {
        if appState.isPremium {
            Label("Unlimited ✦", systemImage: "infinity")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Color.fcTextSecondary)
        } else {
            Text("\(appState.dailyChecksRemaining) free check\(appState.dailyChecksRemaining == 1 ? "" : "s") remaining today")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Color.fcTextSecondary)
        }
    }

    private var recentLooksSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                FCSectionTitle(text: "Your Recent Looks")
                Spacer()
                Button("See All") {
                    withAnimation(.spring(response: 0.3)) {
                        appState.selectedTab = .saved
                    }
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.fcAccent)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(recentOutfits.prefix(6)) { outfit in
                    OutfitCard(outfit: outfit)
                }
            }
        }
    }

    private var loadingShimmer: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            ForEach(0..<4, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.fcSurface)
                    .aspectRatio(3/4, contentMode: .fill)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private var trendCardView: some View {
        VStack(alignment: .leading, spacing: 12) {
            FCSectionTitle(text: "This Week's Trend")

            Button(action: { showTrends = true }) {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(currentTrend?.title ?? "What Gen Z is wearing right now →")
                            .font(.fcBodyBold)
                            .foregroundColor(.fcTextPrimary)
                            .lineLimit(2)
                        if let trend = currentTrend {
                            HStack(spacing: 6) {
                                ForEach(trend.styleTags.prefix(3), id: \.self) { tag in
                                    Text(tag)
                                        .font(.fcTag)
                                        .foregroundColor(.fcAccent)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(Color.fcAccent.opacity(0.12))
                                        .cornerRadius(8)
                                }
                            }
                        } else {
                            Text("Clean minimalism meets streetwear. Navy, cream, and chrome.")
                                .font(.fcCaption)
                                .foregroundColor(.fcTextSecondary)
                        }
                    }
                    Spacer()
                    ZStack {
                        Circle()
                            .fill(Color.fcAccent)
                            .frame(width: 40, height: 40)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Color.fcAccentCream)
                    }
                }
                .padding(18)
                .appCard()
            }
            .buttonStyle(HapticButtonStyle(style: .light))
        }
    }

    // MARK: - Data Loading

    @MainActor
    func loadData() async {
        guard let uid = Auth.auth().currentUser?.uid else {
            isLoadingOutfits = false
            return
        }
        async let outfitsTask: Void = loadOutfits(uid: uid)
        async let trendTask: Void = loadCurrentTrend()
        _ = await (outfitsTask, trendTask)
    }

    private func loadOutfits(uid: String) async {
        do {
            let snapshot = try await db.collection("users/\(uid)/fit_checks")
                .whereField("isDeleted", isEqualTo: false)
                .order(by: "createdAt", descending: true)
                .limit(to: 6)
                .getDocuments()

            var summaries: [OutfitSummary] = []
            for doc in snapshot.documents {
                let data = doc.data()
                let storagePath = data["storagePath"] as? String
                let score = data["overall_score"] as? Double ?? data["overallScore"] as? Double
                let goal = data["styleGoal"] as? String ?? data["style_goal"] as? String
                let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()

                var thumbURL: String?
                if let path = storagePath {
                    if let url = try? await Storage.storage().reference(withPath: path).downloadURL() {
                        thumbURL = url.absoluteString
                    }
                }

                summaries.append(OutfitSummary(
                    id: doc.documentID,
                    thumbnailURL: thumbURL,
                    overallScore: score,
                    styleGoal: goal,
                    createdAt: createdAt
                ))
            }
            await MainActor.run { recentOutfits = summaries; isLoadingOutfits = false }
        } catch {
            await MainActor.run { isLoadingOutfits = false }
        }
    }

    private func loadCurrentTrend() async {
        do {
            let snapshot = try await db.collection("weekly_trends")
                .order(by: "weekStartDate", descending: true)
                .limit(to: 1)
                .getDocuments()
            if let doc = snapshot.documents.first {
                let decoder = Firestore.Decoder()
                decoder.dateDecodingStrategy = .timestamp
                let trend = try doc.data(as: WeeklyTrend.self)
                await MainActor.run { currentTrend = trend }
            }
        } catch {
            // Trend card shows placeholder if no trend exists
        }
    }
}
