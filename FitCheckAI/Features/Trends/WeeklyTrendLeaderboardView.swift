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

// MARK: - Today Challenge Card

/// Dopamine nudge shown above the Today's Best board. Tells the signed-in user
/// how close they are to #1 (or to defend it) and offers a one-tap path to check
/// another fit. Hidden when the user has no fit on today's board.
struct TodayChallengeCard: View {
    /// The signed-in user's own Today standing (fetched even if outside the
    /// visible slice). Nil → no fit today → card hidden.
    let myEntry: WeeklyLeaderboardEntry?
    /// Current #1 on the board (the global leader), for the gap calculation.
    let leaderEntry: WeeklyLeaderboardEntry?
    let onCheckAnotherFit: () -> Void

    var body: some View {
        if let me = myEntry, let leader = leaderEntry {
            let isLeader = me.id != nil && me.id == leader.id
            let copy = message(me: me, leader: leader, isLeader: isLeader)
            card(title: copy.title, subtitle: copy.subtitle, isLeader: isLeader)
        }
    }

    private func card(title: String, subtitle: String, isLeader: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: isLeader ? "crown.fill" : "bolt.fill")
                .font(.system(size: 20))
                .foregroundColor(.fcGold)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.fcBodyBold)
                    .foregroundColor(.fcTextPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(subtitle)
                    .font(.fcCaption)
                    .foregroundColor(.fcTextSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 8)
            Button(action: onCheckAnotherFit) {
                Text("Check another fit")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.fcAccentCream)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.fcAccent)
                    .clipShape(Capsule())
            }
            .buttonStyle(HapticButtonStyle(style: .light))
            .fixedSize()
        }
        .padding(14)
        .background(Color.fcGold.opacity(0.12))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.fcGold.opacity(0.35), lineWidth: 1.5))
        .cornerRadius(16)
    }

    private func message(me: WeeklyLeaderboardEntry, leader: WeeklyLeaderboardEntry, isLeader: Bool)
        -> (title: String, subtitle: String) {
        if isLeader {
            return ("You're #1 today 🔥", "Defend your spot before midnight")
        }
        let gap = ((leader.bestScore - me.bestScore) * 10).rounded() / 10
        if gap <= 0 {
            // Same top score but behind on a tie-break.
            return ("You're tied at \(fmt(me.bestScore)) best", "Upload one more fit to climb")
        }
        let target = fmt(((leader.bestScore + 0.1) * 10).rounded() / 10)
        return ("Only \(fmt(gap)) away from #1", "Score \(target)+ to take #1")
    }

    private func fmt(_ value: Double) -> String { String(format: "%.1f", value) }
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
    /// Signed-in user's own Today standing, for the challenge nudge.
    @State private var todayMyEntry: WeeklyLeaderboardEntry?

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

            // Dopamine nudge — only on Today, only when the user is on the board.
            if selectedLeaderboardMode == .today {
                TodayChallengeCard(
                    myEntry: todayMyEntry,
                    leaderEntry: todayEntries.first,
                    onCheckAnotherFit: { appState.showCheckFlow = true }
                )
            }

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
                    let shown = Array(entries.prefix(previewLimit))
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, entry in
                        LeaderboardRow(
                            rank: index + 1,
                            entry: entry,
                            mode: selectedLeaderboardMode,
                            tieNote: selectedLeaderboardMode == .today
                                ? WeeklyLeaderboardEntry.todayTieNote(entries: shown, index: index)
                                : nil
                        )
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
            let fetched = try await WeeklyLeaderboardService.fetchTopEntries(limit: previewLimit)
            weekEntries = await PublicProfileService.hydrate(fetched)
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
            let fetched = try await DailyLeaderboardService.fetchTopEntries(limit: previewLimit)
            todayEntries = await PublicProfileService.hydrate(fetched)
        } catch {
            print("[WeeklyTrendPreview] today load failed: \(error.localizedDescription)")
            todayEntries = []
        }
        if let uid = appState.currentUser?.id {
            todayMyEntry = await DailyLeaderboardService.fetchMyEntry(uid: uid)
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

    @EnvironmentObject var appState: AppState
    @State private var entries: [WeeklyLeaderboardEntry] = []
    @State private var isLoading = true
    /// Signed-in user's own Today standing, for the challenge nudge.
    @State private var myEntry: WeeklyLeaderboardEntry?

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
                        if mode == .today {
                            TodayChallengeCard(
                                myEntry: myEntry,
                                leaderEntry: entries.first,
                                onCheckAnotherFit: { appState.showCheckFlow = true }
                            )
                        }
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
        if mode == .today, let uid = appState.currentUser?.id {
            myEntry = await DailyLeaderboardService.fetchMyEntry(uid: uid)
        }
        isLoading = false
    }
}
