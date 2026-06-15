import SwiftUI
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage

struct HomeView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var statsVM = HomeStatsViewModel()
    @State private var showHistory = false
    @State private var recentOutfits: [OutfitSummary] = []
    @State private var isLoadingOutfits: Bool = true

    private let db = Firestore.firestore()

    var body: some View {
        NavigationStack {
            ZStack {
                Color.fcBackground.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        headerSection
                        heroCard
                        StyleProgressCard()
                        latestLookSection
                        WeeklyTrendPreviewView()
                        // Clears the floating tab bar AND the FAB, which pokes ~40pt
                        // above the bar (offset -20 + half its 64pt circle). 120 left
                        // the last leaderboard row tucked under the "+" button.
                        Spacer(minLength: 160)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                }
                .refreshable {
                    await loadData()
                    // Also reload "This Week's Trend" — the preview observes this
                    // token. Lets a manual pull recover the leaderboard after a
                    // transient read failure (e.g. an index still building).
                    appState.weeklyTrendRefreshToken += 1
                }
            }
            .navigationDestination(isPresented: $showHistory) {
                HistoryView().environmentObject(appState)
            }
        }
        .task { await loadData() }
        .onChange(of: appState.weeklyTrendRefreshToken) { _, _ in
            // A finished check bumps this; refresh streak + best-this-week so the
            // CTA footer updates without a manual pull-to-refresh.
            Task { await statsVM.load(displayName: appState.currentUser?.displayName) }
        }
        .onChange(of: appState.pendingHistoryNav) { _, shouldNav in
            // ResultView sets pendingHistoryNav before dismissing the CheckFlow
            // fullScreenCover. Wait briefly for that dismissal to complete before
            // pushing HistoryView so the transitions stack cleanly.
            guard shouldNav else { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                showHistory = true
                appState.pendingHistoryNav = false
            }
        }
    }

    // MARK: - Subviews

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(greetingText)
                .font(.fcHeading)
                .foregroundColor(.fcTextPrimary)
            Text("Ready to beat yesterday's fit?")
                .font(.fcBody)
                .foregroundColor(.fcTextSecondary)
        }
    }

    /// "Hey, {firstName} 👋" when we have a name, else "Hey, there 👋". Reads the
    /// live display name from app state so a just-edited profile updates instantly.
    private var greetingText: String {
        if let first = HomeStatsViewModel.firstName(from: appState.currentUser?.displayName) {
            return "Hey, \(first) 👋"
        }
        return "Hey, there 👋"
    }

    private var heroCard: some View {
        Button(action: { appState.showCheckFlow = true }) {
            VStack(alignment: .leading, spacing: 18) {
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
                heroStatsRow
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 22)
            .background(Color.fcAccent2)
            .cornerRadius(26)
            .shadow(color: Color.fcShadow, radius: 18, x: 0, y: 8)
        }
        .buttonStyle(HapticButtonStyle(style: .medium))
    }

    /// Footer inside the CTA card: streak on the left, best-this-week on the right,
    /// separated by a subtle divider. Sits full-width below the subtitle so it
    /// never collides with the plus button.
    private var heroStatsRow: some View {
        HStack(spacing: 14) {
            // Streak
            HStack(spacing: 6) {
                Text("🔥")
                    .font(.system(size: 14))
                Text(streakText)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.fcTextPrimary)
            }

            Rectangle()
                .fill(Color.fcTextPrimary.opacity(0.18))
                .frame(width: 1, height: 16)

            // Best this week
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.fcAccent)
                Text("Best this week: \(bestThisWeekText)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.fcTextPrimary)
            }

            Spacer(minLength: 0)
        }
    }

    private var streakText: String {
        let n = statsVM.currentStreak
        return n > 0 ? "\(n)-day streak" : "Start your streak"
    }

    private var bestThisWeekText: String {
        guard let best = statsVM.bestScoreThisWeek else { return "—" }
        return String(format: "%.1f", best)
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

    @ViewBuilder
    private var latestLookSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                showHistory = true
            } label: {
                HStack {
                    FCSectionTitle(text: "Latest Look")
                    Spacer()
                    if !recentOutfits.isEmpty {
                        Text("View History")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.fcAccent)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isLoadingOutfits {
                loadingPlaceholder
            } else if recentOutfits.isEmpty {
                EmptyStateView(
                    icon: "camera.viewfinder",
                    title: "No outfit checks yet",
                    subtitle: "Tap the camera to add your first fit check."
                )
            } else if let top = recentOutfits.first {
                // Demoted to a compact row now that the Arena card is the hero. Still
                // opens the full analysis detail for that exact analysisId on tap.
                compactLatestLook(top)
            }
        }
    }

    private func compactLatestLook(_ outfit: OutfitSummary) -> some View {
        Button {
            print("[HomeView] Latest Look tapped → History")
            showHistory = true
        } label: {
            HStack(spacing: 14) {
                SmartOutfitImageView(source: outfit.thumbnailURL.flatMap(URL.init).map { .remote($0) })
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    if let goal = outfit.styleGoal {
                        Text(StyleGoal(rawValue: goal)?.displayName ?? goal)
                            .font(.fcBodyBold)
                            .foregroundColor(.fcTextPrimary)
                    }
                    Text(outfit.formattedDate)
                        .font(.fcCaption)
                        .foregroundColor(.fcTextSecondary)
                }
                Spacer()
                if let score = outfit.overallScore {
                    ScoreBadge(score: score, fontSize: 14)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.fcTextSecondary)
            }
            .padding(14)
            .background(Color.fcSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(HapticButtonStyle(style: .light))
    }

    private var loadingPlaceholder: some View {
        RoundedRectangle(cornerRadius: 18)
            .fill(Color.fcSurface)
            .frame(height: 92)
            .overlay(ProgressView().tint(.fcTextSecondary))
    }

    // MARK: - Data Loading

    @MainActor
    func loadData() async {
        // Stats footer loads for everyone (guest → neutral defaults), so do it
        // before the uid guard.
        await statsVM.load(displayName: appState.currentUser?.displayName)
        guard let uid = Auth.auth().currentUser?.uid else {
            isLoadingOutfits = false
            return
        }
        await loadOutfits(uid: uid)
        // Prune old history/upgrades in the background after a check lands here (Home
        // reloads post-analysis). Keeps storage bounded without blocking the UI.
        Task.detached { await UpgradeHistoryService.cleanupUserAnalysisHistory(uid: uid) }
    }

    private func loadOutfits(uid: String) async {
        do {
            // Only need enough to render the stack (top + 2 peeking behind).
            let snapshot = try await db.collection("users/\(uid)/fit_checks")
                .whereField("isDeleted", isEqualTo: false)
                .order(by: "createdAt", descending: true)
                .limit(to: 3)
                .getDocuments()

            let summaries: [OutfitSummary] = await withTaskGroup(of: OutfitSummary?.self) { group in
                for doc in snapshot.documents {
                    group.addTask {
                        let data = doc.data()
                        let storagePath = data["storagePath"] as? String
                        let cachedThumb = data["thumbnailURL"] as? String
                        let score = data["overall_score"] as? Double ?? data["overallScore"] as? Double
                        let goal = data["styleGoal"] as? String ?? data["style_goal"] as? String
                        let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()

                        var thumbURL: String? = cachedThumb
                        if thumbURL == nil, let path = storagePath {
                            if let url = try? await Storage.storage().reference(withPath: path).downloadURL() {
                                thumbURL = url.absoluteString
                            }
                        }

                        return OutfitSummary(
                            id: doc.documentID,
                            thumbnailURL: thumbURL,
                            overallScore: score,
                            styleGoal: goal,
                            createdAt: createdAt
                        )
                    }
                }
                var out: [(Date, OutfitSummary)] = []
                for await s in group { if let s { out.append((s.createdAt, s)) } }
                return out.sorted { $0.0 > $1.0 }.map { $0.1 }
            }

            await MainActor.run { recentOutfits = summaries; isLoadingOutfits = false }
        } catch {
            print("[HomeView] loadOutfits failed: \(error.localizedDescription)")
            await MainActor.run { isLoadingOutfits = false }
        }
    }
}

// MARK: - Stacked Look Card

/// Latest uploaded look with up to two earlier looks peeking behind it.
/// Tapping anywhere opens the full History screen.
private struct StackedLookCard: View {
    let outfits: [OutfitSummary]
    var onTap: () -> Void

    private let cardHeight: CGFloat = 360
    private let peekOffset: CGFloat = 30 // extra vertical room for back cards

    var body: some View {
        Button(action: onTap) {
            ZStack {
                if outfits.count >= 3 {
                    cardFace(for: outfits[2], isTop: false)
                        .scaleEffect(0.88)
                        .offset(y: 28)
                        .opacity(0.55)
                }
                if outfits.count >= 2 {
                    cardFace(for: outfits[1], isTop: false)
                        .scaleEffect(0.94)
                        .offset(y: 14)
                        .opacity(0.8)
                }
                cardFace(for: outfits[0], isTop: true)
            }
            .frame(maxWidth: .infinity)
            .frame(height: cardHeight + peekOffset, alignment: .top)
        }
        .buttonStyle(HapticButtonStyle(style: .light))
    }

    private func cardFace(for outfit: OutfitSummary, isTop: Bool) -> some View {
        let source: OutfitImageSource? = (outfit.thumbnailURL.flatMap(URL.init)).map { .remote($0) }
        return ZStack(alignment: .topTrailing) {
            // Photo — Vision smart crop: fills the card edge-to-edge while keeping the
            // face/head high and the shoulders/chest visible (no wall-heavy center
            // crop, no blur). The detail view shows the full original image.
            SmartOutfitImageView(source: source)
                .frame(maxWidth: .infinity)
                .frame(height: cardHeight)
                .clipped()

            // Score badge — only on the top (latest) card to avoid visual noise.
            if isTop, let score = outfit.overallScore {
                ScoreBadge(score: score, fontSize: 14)
                    .padding(14)
            }

            // Bottom overlay with date + style + CTA, top card only.
            if isTop {
                bottomOverlay(for: outfit)
            }
        }
        .frame(height: cardHeight)
        .background(Color.fcSurface)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Color.fcShadow, radius: 14, x: 0, y: 8)
    }

    private func bottomOverlay(for outfit: OutfitSummary) -> some View {
        VStack {
            Spacer()
            ZStack(alignment: .bottom) {
                LinearGradient(
                    colors: [Color.black.opacity(0.0), Color.black.opacity(0.55)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 110)

                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(outfit.formattedDate)
                            .font(.fcCaption)
                            .foregroundColor(Color.white.opacity(0.85))
                        if let goal = outfit.styleGoal {
                            Text(StyleGoal(rawValue: goal)?.displayName ?? goal)
                                .font(.fcBodyBold)
                                .foregroundColor(.white)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    HStack(spacing: 4) {
                        Text("Details")
                            .font(.fcTag)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.35))
                    .clipShape(Capsule())
                }
                .padding(14)
            }
        }
    }
}
