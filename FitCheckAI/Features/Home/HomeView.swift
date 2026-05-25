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

    private let db = Firestore.firestore()

    var body: some View {
        NavigationStack {
            ZStack {
                Color.fcBackground.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        headerSection
                        heroCard
                        if isLoadingOutfits {
                            loadingShimmer
                        } else if recentOutfits.isEmpty {
                            emptyState
                        } else {
                            recentLooksSection
                        }
                        trendCardView
                        Spacer(minLength: 100)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                }
                .refreshable { await loadData() }
            }
            .navigationDestination(isPresented: $showTrends) {
                TrendsView().environmentObject(appState)
            }
        }
        .task { await loadData() }
    }

    // MARK: - Subviews

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(appState.currentUser?.greeting ?? "Hey"), \(appState.currentUser?.firstName ?? "there") 👋")
                    .font(.fcHeading)
                    .foregroundColor(.fcTextPrimary)
                Text("Ready to check today's fit?")
                    .font(.fcCaption)
                    .foregroundColor(.fcTextSecondary)
            }
            Spacer()
            if appState.streakCount > 0 {
                HStack(spacing: 4) {
                    Text("🔥")
                    Text("\(appState.streakCount)")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.fcTextPrimary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.fcSurface)
                .cornerRadius(20)
            }
        }
    }

    private var heroCard: some View {
        ZStack {
            LinearGradient(
                colors: [Color.fcAccent, Color(hex: "#A8D800")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .cornerRadius(20)
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Check today's fit.")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.fcBackground)
                    checksRemainingLabel
                }
                Spacer()
                ZStack {
                    Circle()
                        .fill(Color.black.opacity(0.12))
                        .frame(width: 56, height: 56)
                    Image(systemName: "camera.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.fcBackground)
                }
            }
            .padding(20)
        }
        .shadow(color: Color.fcAccent.opacity(0.4), radius: 16, y: 6)
        .onTapGesture {
            withAnimation(.spring(response: 0.3)) {
                appState.selectedTab = .fitCheck
            }
        }
    }

    @ViewBuilder
    private var checksRemainingLabel: some View {
        if appState.isPremium {
            Label("Unlimited ✦", systemImage: "infinity")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color.fcBackground.opacity(0.7))
        } else {
            Text("\(appState.dailyChecksRemaining) free check\(appState.dailyChecksRemaining == 1 ? "" : "s") remaining")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Color.fcBackground.opacity(0.7))
        }
    }

    private var recentLooksSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Your Recent Looks")
                    .font(.fcTitle)
                    .foregroundColor(.fcTextPrimary)
                Spacer()
                Button("See All") {
                    appState.selectedTab = .saved
                }
                .font(.system(size: 13, weight: .semibold))
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
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.fcSurface)
                    .aspectRatio(3/4, contentMode: .fill)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 50))
                .foregroundColor(.fcTextSecondary.opacity(0.4))
            Text("No looks yet.")
                .font(.fcTitle)
                .foregroundColor(.fcTextPrimary)
            Text("Tap the camera to add your first fit check!")
                .font(.fcBody)
                .foregroundColor(.fcTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    @ViewBuilder
    private var trendCardView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("This Week's Trend")
                .font(.fcTitle)
                .foregroundColor(.fcTextPrimary)

            Button(action: { showTrends = true }) {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(currentTrend?.title ?? "What Gen Z is wearing right now →")
                            .font(.fcBodyBold)
                            .foregroundColor(.fcTextPrimary)
                            .lineLimit(2)
                        if let trend = currentTrend {
                            HStack(spacing: 6) {
                                ForEach(trend.styleTags.prefix(3), id: \.self) { tag in
                                    Text(tag)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(.fcAccent)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
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
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.fcAccent)
                }
                .padding(16)
                .background(Color.fcSurface)
                .cornerRadius(16)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.fcAccent.opacity(0.2), lineWidth: 1)
                )
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
