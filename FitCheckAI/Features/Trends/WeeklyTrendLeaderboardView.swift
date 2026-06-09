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
    let rank: Int
    let entry: WeeklyLeaderboardEntry
    var mode: LeaderboardMode = .week
    var detailed: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            RankBadge(rank: rank)
            LeaderboardAvatar(photoURL: entry.photoURL, name: entry.name, size: detailed ? 48 : 40)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
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

/// Compact leaderboard shown on the Home screen, with a Week / Today toggle.
/// Week ranks by the confidence-weighted weekly average; Today ranks purely by
/// the highest single outfit score earned today — a daily mini-competition.
struct WeeklyTrendPreviewView: View {
    private let previewLimit = 3

    @EnvironmentObject var appState: AppState
    @State private var selectedLeaderboardMode: LeaderboardMode = .week
    @State private var weekEntries: [WeeklyLeaderboardEntry] = []
    @State private var todayEntries: [WeeklyLeaderboardEntry] = []
    @State private var weekLoading = true
    @State private var todayLoaded = false
    @State private var todayLoading = false
    @State private var showLeaderboard = false

    /// Entries for whichever mode is selected.
    private var entries: [WeeklyLeaderboardEntry] {
        selectedLeaderboardMode == .week ? weekEntries : todayEntries
    }

    private var isLoading: Bool {
        selectedLeaderboardMode == .week ? weekLoading : todayLoading
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Toggle sits just above the header, between Latest Look and the card.
            LeaderboardModeToggle(mode: $selectedLeaderboardMode)
                .frame(maxWidth: 220)

            HStack {
                FCSectionTitle(text: selectedLeaderboardMode.header)
                Spacer()
                if !entries.isEmpty {
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

            content
                .animation(.easeInOut(duration: 0.25), value: selectedLeaderboardMode)
        }
        .navigationDestination(isPresented: $showLeaderboard) {
            WeeklyTrendLeaderboardView(mode: selectedLeaderboardMode)
        }
        .task { await loadWeek() }
        // Lazily load Today the first time the user switches to it, then reload
        // whenever they switch back so a fresh check shows up.
        .onChange(of: selectedLeaderboardMode) { _, newMode in
            if newMode == .today { Task { await loadToday() } }
        }
        // Reload the moment a new check finishes (CheckFlow bumps this once the
        // backend has written the new standing) so the score shows without a
        // manual pull-to-refresh.
        .onChange(of: appState.weeklyTrendRefreshToken) { _, _ in
            Task {
                await loadWeek()
                if todayLoaded { await loadToday() }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.fcSurface)
                .frame(height: 150)
                .overlay(ProgressView().tint(.fcTextSecondary))
        } else if entries.isEmpty {
            emptyState
        } else {
            Button(action: { showLeaderboard = true }) {
                VStack(spacing: 0) {
                    ForEach(Array(entries.prefix(previewLimit).enumerated()), id: \.element.id) { index, entry in
                        LeaderboardRow(rank: index + 1, entry: entry, mode: selectedLeaderboardMode)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 14)
                        if index < min(previewLimit, entries.count) - 1 {
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

    private var emptyState: some View {
        HStack(spacing: 14) {
            Image(systemName: "trophy")
                .font(.system(size: 26))
                .foregroundColor(.fcTextSecondary.opacity(0.5))
            Text(selectedLeaderboardMode.emptyMessage)
                .font(.fcBody)
                .foregroundColor(.fcTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(18)
        .appCard()
    }

    @MainActor
    private func loadWeek() async {
        weekLoading = true
        do {
            weekEntries = try await WeeklyLeaderboardService.fetchTopEntries(limit: previewLimit)
        } catch {
            print("[WeeklyTrendPreview] week load failed: \(error.localizedDescription)")
            weekEntries = []
        }
        weekLoading = false
    }

    @MainActor
    private func loadToday() async {
        todayLoading = !todayLoaded // only show the spinner on first load
        do {
            todayEntries = try await DailyLeaderboardService.fetchTopEntries(limit: previewLimit)
        } catch {
            print("[WeeklyTrendPreview] today load failed: \(error.localizedDescription)")
            todayEntries = []
        }
        todayLoaded = true
        todayLoading = false
    }
}

// MARK: - Full Leaderboard Page

/// Full weekly leaderboard, ranked by the confidence-weighted weekly trend
/// score (weekly average × 5-fit confidence), displaying each user's average.
struct WeeklyTrendLeaderboardView: View {
    private let pageLimit = 50
    var mode: LeaderboardMode = .week

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
                            LeaderboardRow(rank: index + 1, entry: entry, mode: mode, detailed: mode == .week)
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
    }

    @MainActor
    private func load() async {
        isLoading = true
        do {
            entries = mode == .today
                ? try await DailyLeaderboardService.fetchTopEntries(limit: pageLimit)
                : try await WeeklyLeaderboardService.fetchTopEntries(limit: pageLimit)
        } catch {
            print("[WeeklyTrendLeaderboard] load failed: \(error.localizedDescription)")
            entries = []
        }
        isLoading = false
    }
}
