import SwiftUI

// MARK: - Mode

/// Which leaderboard the Home card is showing.
enum LeaderboardMode: CaseIterable {
    case week
    case today

    /// Pill label.
    var title: String {
        switch self {
        case .week:  return "Week"
        case .today: return "Today"
        }
    }

    /// Section header above the card.
    var header: String {
        switch self {
        case .week:  return "This Week's Trend"
        case .today: return "Today's Best"
        }
    }

    /// Empty-state copy.
    var emptyMessage: String {
        switch self {
        case .week:  return "No weekly trend yet. Upload your fit to enter the leaderboard."
        case .today: return "No fits checked today yet. Upload your fit to top today's board."
        }
    }
}

// MARK: - Avatar

/// Circular profile photo with an initials fallback, matching the app's
/// beige/olive palette.
struct LeaderboardAvatar: View {
    let photoURL: String?
    let name: String
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.fcAccent.opacity(0.15))

            if let urlString = photoURL, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .empty:
                        ProgressView().tint(.fcTextSecondary)
                    default:
                        initials
                    }
                }
            } else {
                initials
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var initials: some View {
        Text(String(name.prefix(1).uppercased()))
            .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
            .foregroundColor(.fcAccent)
    }
}

// MARK: - Rank Badge

/// Rank number, gold-tinted for the top three.
private struct RankBadge: View {
    let rank: Int

    var body: some View {
        Text("#\(rank)")
            .font(.system(size: 15, weight: .heavy, design: .rounded))
            .foregroundColor(rank <= 3 ? .fcGold : .fcTextSecondary)
            .frame(minWidth: 30, alignment: .leading)
    }
}

// MARK: - Leaderboard Row

/// One user's row. `detailed` adds the "best score" stat for the full weekly
/// page. `mode` switches between weekly (average + confidence) and today
/// (highest single score) presentation.
struct LeaderboardRow: View {
    @EnvironmentObject var appState: AppState
    let rank: Int
    let entry: WeeklyLeaderboardEntry
    var mode: LeaderboardMode = .week
    var detailed: Bool = false
    /// Today-only subtext explaining a best-score tie (e.g. "Same best · more
    /// fits wins"). Computed by the parent from the full ranked list.
    var tieNote: String? = nil

    /// The signed-in user's own row reads name/photo from live app state, so a
    /// just-edited profile shows instantly without waiting for a refetch. Other
    /// rows use the values hydrated from publicProfiles at load time.
    private var isCurrentUser: Bool {
        entry.id != nil && entry.id == appState.currentUser?.id
    }
    private var displayedName: String {
        if isCurrentUser, let n = appState.currentUser?.displayName,
           !n.trimmingCharacters(in: .whitespaces).isEmpty { return n }
        return entry.name
    }
    private var displayedPhotoURL: String? {
        if isCurrentUser, let p = appState.currentUser?.photoURL, !p.isEmpty { return p }
        return entry.photoURL
    }

    var body: some View {
        HStack(spacing: 12) {
            RankBadge(rank: rank)
            LeaderboardAvatar(photoURL: displayedPhotoURL, name: displayedName, size: detailed ? 48 : 40)

            VStack(alignment: .leading, spacing: 3) {
                Text(displayedName)
                    .font(.fcBodyBold)
                    .foregroundColor(.fcTextPrimary)
                    .lineLimit(1)

                subtitle

                // Confidence nudge is weekly-only — Today ranks on a single score.
                if mode == .week, let hint = entry.confidenceHint {
                    Text(hint)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.fcTextSecondary.opacity(0.6))
                        .lineLimit(1)
                }

                // Today: explain the tie-break so equal best scores never feel random.
                if mode == .today, let tieNote {
                    Text(tieNote)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(isCurrentUser ? .fcAccent : .fcTextSecondary.opacity(0.7))
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(mode == .today ? entry.todayBestLabel : entry.averageLabel)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(.fcAccent)
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        HStack(spacing: 8) {
            switch mode {
            case .week:
                Text(entry.fitsLabel)
                if detailed {
                    Text("•")
                    Text(String(format: "best %.1f", entry.bestScore))
                }
            case .today:
                Text(entry.todayFitsLabel)
            }
        }
        .font(.fcCaption)
        .foregroundColor(.fcTextSecondary)
    }
}

// MARK: - Mode Toggle

/// Minimal rounded-pill segmented toggle (Week / Today) in the beige/olive
/// theme. Selected segment gets the olive fill + cream text; the highlight
/// slides between segments with a spring.
struct LeaderboardModeToggle: View {
    @Binding var mode: LeaderboardMode
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 4) {
            ForEach(LeaderboardMode.allCases, id: \.self) { option in
                segment(option)
            }
        }
        .padding(4)
        .background(
            Capsule().fill(Color.fcAccentCream.opacity(0.6))
        )
        .overlay(
            Capsule().stroke(Color.fcAccent.opacity(0.12), lineWidth: 1)
        )
    }

    private func segment(_ option: LeaderboardMode) -> some View {
        let isSelected = mode == option
        return Text(option.title)
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundColor(isSelected ? .fcAccentCream : .fcAccent)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(
                ZStack {
                    if isSelected {
                        Capsule()
                            .fill(Color.fcAccent)
                            .matchedGeometryEffect(id: "selectedSegment", in: highlight)
                    }
                }
            )
            .contentShape(Capsule())
            .onTapGesture {
                guard mode != option else { return }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    mode = option
                }
            }
    }
}


// MARK: - Home Preview

/// Compact public Top 3 shown on Home, sourced from the SAME `getArenaFinalists`
/// the Arena tab uses — so Home's Top 3 always matches the Arena Top 3. A Week /
/// Today toggle switches boards; "View All" opens the full leaderboard list.
/// Ranking is by community Hot Fit votes (AI score tie-break), not raw AI score.
struct WeeklyTrendPreviewView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedLeaderboardMode: LeaderboardMode = .today
    @State private var weekTop: [ArenaFinalist] = []
    @State private var todayTop: [ArenaFinalist] = []
    @State private var weekLoaded = false
    @State private var todayLoaded = false
    @State private var isLoading = true
    @State private var showLeaderboard = false

    private let service = ArenaService()

    /// Finalists for whichever mode is selected (same source as the Arena tab).
    private var top: [ArenaFinalist] {
        selectedLeaderboardMode == .week ? weekTop : todayTop
    }

    private var caption: String {
        selectedLeaderboardMode == .week
            ? "Community votes decide this week's Top Fit"
            : "Community votes decide today's Top Fit"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LeaderboardModeToggle(mode: $selectedLeaderboardMode)
                .frame(maxWidth: 220)

            HStack {
                FCSectionTitle(text: selectedLeaderboardMode.header)
                Spacer()
                if !top.isEmpty {
                    Button(action: { showLeaderboard = true }) {
                        HStack(spacing: 4) {
                            Text("View All")
                            Image(systemName: "arrow.right")
                                .font(.system(size: 12, weight: .bold))
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.fcAccent)
                    }
                    .buttonStyle(HapticButtonStyle(style: .light))
                }
            }

            Text(caption)
                .font(.fcCaption)
                .foregroundColor(.fcTextSecondary)

            content
                .animation(.easeInOut(duration: 0.25), value: selectedLeaderboardMode)
        }
        .navigationDestination(isPresented: $showLeaderboard) {
            WeeklyTrendLeaderboardView(mode: selectedLeaderboardMode)
        }
        .task { await load(.today); await load(.week) }
        // Reload when a new check finishes so a freshly-pooled fit shows up.
        .onChange(of: appState.weeklyTrendRefreshToken) { _, _ in
            Task { await load(.today); await load(.week) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && top.isEmpty {
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.fcSurface)
                .frame(height: 150)
                .overlay(ProgressView().tint(.fcTextSecondary))
        } else if top.isEmpty {
            emptyState
        } else {
            // Tap the board → jump into the Arena showcase.
            Button(action: { appState.selectedTab = .arena }) {
                VStack(spacing: 0) {
                    let shown = Array(top.prefix(3))
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, f in
                        finalistRow(f)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 14)
                        if index < shown.count - 1 {
                            Divider().background(Color.fcTextSecondary.opacity(0.12))
                                .padding(.leading, 18)
                        }
                    }
                }
                .padding(.vertical, 4)
                .appCard()
            }
            .buttonStyle(HapticButtonStyle(style: .light))
        }
    }

    private func finalistRow(_ f: ArenaFinalist) -> some View {
        HStack(spacing: 12) {
            Text("#\(f.rank)")
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundColor(f.rank <= 3 ? .fcGold : .fcTextSecondary)
                .frame(minWidth: 30, alignment: .leading)
            LeaderboardAvatar(photoURL: f.ownerPhotoUrl, name: f.displayName, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(f.displayName)
                    .font(.fcBodyBold).foregroundColor(.fcTextPrimary).lineLimit(1)
                HStack(spacing: 10) {
                    HStack(spacing: 3) {
                        Image(systemName: "flame.fill").font(.system(size: 11)).foregroundColor(.fcAccent)
                        Text("\(f.hotFitCount) Hot Fits").font(.fcCaption).foregroundColor(.fcTextSecondary)
                    }
                    if let s = f.aiScore {
                        Text(String(format: "AI %.1f", s)).font(.fcCaption).foregroundColor(.fcTextSecondary)
                    }
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold)).foregroundColor(.fcTextSecondary)
        }
    }

    private var emptyState: some View {
        HStack(spacing: 14) {
            Image(systemName: "flame")
                .font(.system(size: 26))
                .foregroundColor(.fcTextSecondary.opacity(0.5))
            Text("No Top Fits yet. Score 6.5+ and get Hot Fits to climb the ranking.")
                .font(.fcBody)
                .foregroundColor(.fcTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(18)
        .appCard()
    }

    @MainActor
    private func load(_ tab: ArenaTab) async {
        do {
            let items = try await service.fetchFinalists(tab: tab)
            if tab == .week { weekTop = items; weekLoaded = true }
            else { todayTop = items; todayLoaded = true }
        } catch {
            print("[WeeklyTrendPreview] \(tab.rawValue) load failed: \(error.localizedDescription)")
        }
        if todayLoaded || weekLoaded { isLoading = false }
    }
}

// MARK: - Full Leaderboard Page

/// Full weekly leaderboard, ranked by the confidence-weighted weekly trend
/// score (weekly average × 5-fit confidence), displaying each user's average.
struct WeeklyTrendLeaderboardView: View {
    private let pageLimit = 50
    var mode: LeaderboardMode = .week

    @EnvironmentObject var appState: AppState
    @State private var entries: [WeeklyLeaderboardEntry] = []
    @State private var isLoading = true

    var body: some View {
        ZStack {
            Color.fcBackground.ignoresSafeArea()

            if isLoading {
                ProgressView().tint(.fcAccent).scaleEffect(1.4)
            } else if entries.isEmpty {
                EmptyStateView(
                    icon: "trophy",
                    title: mode == .today ? "No fits checked today" : "No weekly trend yet",
                    subtitle: mode == .today
                        ? "Upload your fit to top today's board."
                        : "Upload your fit to enter the leaderboard."
                )
                .padding(.horizontal, 20)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            LeaderboardRow(
                                rank: index + 1,
                                entry: entry,
                                mode: mode,
                                detailed: mode == .week,
                                tieNote: mode == .today
                                    ? WeeklyLeaderboardEntry.todayTieNote(entries: entries, index: index)
                                    : nil
                            )
                            .padding(16)
                            .appCard()
                        }
                        Spacer(minLength: 100)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                }
                .refreshable { await load() }
            }
        }
        .navigationTitle(mode.header)
        .navigationBarTitleDisplayMode(.large)
        .task { await load() }
        // A finished check bumps this; reload so the board (and the nudge) reflect
        // the new score without a manual pull-to-refresh.
        .onChange(of: appState.weeklyTrendRefreshToken) { _, _ in
            Task { await load() }
        }
    }

    @MainActor
    private func load() async {
        isLoading = true
        do {
            let fetched = mode == .today
                ? try await DailyLeaderboardService.fetchTopEntries(limit: pageLimit)
                : try await WeeklyLeaderboardService.fetchTopEntries(limit: pageLimit)
            entries = await PublicProfileService.hydrate(fetched)
        } catch {
            print("[WeeklyTrendLeaderboard] load failed: \(error.localizedDescription)")
            entries = []
        }
        isLoading = false
    }
}
