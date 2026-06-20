import SwiftUI
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage

// MARK: - Models

/// One of the signed-in user's own outfit checks this week, reduced to what the
/// "This Week's Best Fits" cards need: a score and a resolved thumbnail URL.
struct WeeklyBestFit: Identifiable, Equatable {
    let id: String
    let score: Double
    let imageURL: URL?
}

// MARK: - View Model

/// Drives the Home "Your Style Progress" card and its detail screen.
///
/// Two independent data sources, loaded together:
///   • Personal weekly averages — read straight from the signed-in user's own
///     `users/{uid}/fit_checks`, bucketed into the current and previous ISO week.
///   • Weekly rank — pulled from `WeeklyLeaderboardService`, the SAME confidence-
///     weighted board the Week Trend / Arena Week tab uses, so the rank shown here
///     always matches the leaderboard. We deliberately do not re-implement ranking.
@MainActor
final class StyleProgressViewModel: ObservableObject {
    @Published var currentWeekAverage: Double?
    @Published var previousWeekAverage: Double?
    /// current − previous, 1 dp. nil when there's no prior week to compare against.
    @Published var weeklyDelta: Double?
    /// 1-based position on the weekly leaderboard. nil → user isn't ranked.
    @Published var userWeeklyRank: Int?
    /// The user's leaderboard score (confidence-weighted weekly average), 1 dp.
    @Published var userWeeklyScore: Double?
    @Published var fitsThisWeek: Int = 0
    @Published var bestScoreThisWeek: Double?
    /// The user's top 3 outfit checks this week (by score, desc), with resolved
    /// thumbnails — drives the "This Week's Best Fits" recap.
    @Published var topFitsThisWeek: [WeeklyBestFit] = []
    /// Current consecutive-day check-in streak. Computed from the same fit_checks
    /// read used for the weekly buckets via `HomeStatsViewModel.streak`, so it
    /// matches the streak shown in the Home CTA card exactly.
    @Published var streak: Int = 0
    @Published var isLoading = true

    /// True once the user has at least one check this week.
    var hasEnoughData: Bool { fitsThisWeek > 0 }

    private let db = Firestore.firestore()

    /// ISO-8601 week in UTC — matches `WeekIdentifier`, so "this week" here lines
    /// up exactly with the leaderboard's notion of the current week.
    private var isoCalendarUTC: Calendar {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal
    }

    func load() async {
        guard let uid = Auth.auth().currentUser?.uid else {
            isLoading = false
            return
        }
        isLoading = true

        async let bucketsTask = loadWeekBuckets(uid: uid)
        async let rankTask = computeRank(uid: uid)
        let (current, previous, topFits, streakDays) = await bucketsTask
        let (rank, rankScore) = await rankTask

        currentWeekAverage = current.average
        previousWeekAverage = previous.average
        fitsThisWeek = current.count
        bestScoreThisWeek = current.best
        topFitsThisWeek = topFits
        streak = streakDays

        if let c = current.average, let p = previous.average {
            weeklyDelta = ((c - p) * 10).rounded() / 10
        } else {
            weeklyDelta = nil
        }

        userWeeklyRank = rank
        userWeeklyScore = rankScore
        isLoading = false
    }

    // MARK: - Personal weekly averages

    /// One week's worth of the user's own scores.
    private struct WeekStats {
        let scores: [Double]
        var count: Int { scores.count }
        var average: Double? {
            guard !scores.isEmpty else { return nil }
            return ((scores.reduce(0, +) / Double(scores.count)) * 10).rounded() / 10
        }
        var best: Double? {
            guard let m = scores.max() else { return nil }
            return (m * 10).rounded() / 10
        }
        static let empty = WeekStats(scores: [])
    }

    /// Reads the user's recent fit checks once and buckets them into the current
    /// and previous ISO week on the client. Reuses the exact (isDeleted, createdAt)
    /// query shape History already relies on, so no new Firestore index is needed.
    /// Also returns this week's top 3 checks (by score) with resolved thumbnails and
    /// the current check-in streak — all from the single read.
    private func loadWeekBuckets(uid: String) async -> (current: WeekStats, previous: WeekStats, topFits: [WeeklyBestFit], streak: Int) {
        let cal = isoCalendarUTC
        guard
            let weekInterval = cal.dateInterval(of: .weekOfYear, for: Date()),
            let prevStart = cal.date(byAdding: .weekOfYear, value: -1, to: weekInterval.start)
        else { return (.empty, .empty, [], 0) }

        let curStart = weekInterval.start
        let curEnd = weekInterval.end

        do {
            // 200 recent checks covers a two-week window for any realistic user.
            let snapshot = try await db.collection("users/\(uid)/fit_checks")
                .whereField("isDeleted", isEqualTo: false)
                .order(by: "createdAt", descending: true)
                .limit(to: 200)
                .getDocuments()

            var current: [Double] = []
            var previous: [Double] = []
            // Every dated check, scored or not — streak counts check-in days.
            var allDates: [Date] = []
            // Current-week checks carrying enough to render a ranked card.
            var currentChecks: [PendingFit] = []
            for doc in snapshot.documents {
                let d = doc.data()
                guard let ts = (d["createdAt"] as? Timestamp)?.dateValue() else { continue }
                allDates.append(ts)

                guard let score = d["overall_score"] as? Double ?? d["overallScore"] as? Double else { continue }
                if ts >= curStart && ts < curEnd {
                    current.append(score)
                    currentChecks.append(PendingFit(
                        id: doc.documentID,
                        score: score,
                        storagePath: d["storagePath"] as? String,
                        cachedThumb: d["thumbnailURL"] as? String
                    ))
                } else if ts >= prevStart && ts < curStart {
                    previous.append(score)
                }
            }
            let topFits = await Self.topThreeFits(from: currentChecks)
            // Same derivation the Home CTA uses, so both surfaces agree.
            let streak = HomeStatsViewModel.streak(from: allDates)
            return (WeekStats(scores: current), WeekStats(scores: previous), topFits, streak)
        } catch {
            print("[StyleProgress] week query failed: \(error.localizedDescription)")
            return (.empty, .empty, [], 0)
        }
    }

    /// A current-week check before its thumbnail URL has been resolved.
    private struct PendingFit {
        let id: String
        let score: Double
        let storagePath: String?
        let cachedThumb: String?
    }

    /// Top three checks by score (desc), with Storage thumbnails resolved in
    /// parallel. Mirrors History's cached-thumb → storagePath download fallback,
    /// so only the three shown cards ever hit Storage. `nonisolated` so the three
    /// download tasks run concurrently off the main actor.
    private nonisolated static func topThreeFits(from checks: [PendingFit]) async -> [WeeklyBestFit] {
        let top = checks.sorted { $0.score > $1.score }.prefix(3)
        return await withTaskGroup(of: (Int, WeeklyBestFit).self) { group in
            for (index, check) in top.enumerated() {
                group.addTask {
                    let url = await resolveThumbURL(storagePath: check.storagePath, cached: check.cachedThumb)
                    return (index, WeeklyBestFit(id: check.id, score: check.score, imageURL: url))
                }
            }
            var collected: [(Int, WeeklyBestFit)] = []
            for await result in group { collected.append(result) }
            return collected.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }

    /// Cached thumbnail URL if present, otherwise the Storage download URL.
    private nonisolated static func resolveThumbURL(storagePath: String?, cached: String?) async -> URL? {
        if let cached, let url = URL(string: cached) { return url }
        guard let storagePath else { return nil }
        return try? await Storage.storage().reference(withPath: storagePath).downloadURL()
    }

    // MARK: - Weekly rank (shared leaderboard logic)

    /// Finds the signed-in user inside the weekly leaderboard. Returns their
    /// 1-based rank and the score the board would display (confidence-weighted
    /// weekly average), or (nil, nil) if they aren't ranked / not in the top slice.
    private func computeRank(uid: String) async -> (rank: Int?, score: Double?) {
        do {
            let entries = try await WeeklyLeaderboardService.fetchTopEntries(limit: 100)
            guard let idx = entries.firstIndex(where: { $0.id == uid }) else {
                return (nil, nil)
            }
            let score = (entries[idx].weeklyAverageScore * 10).rounded() / 10
            return (idx + 1, score)
        } catch {
            print("[StyleProgress] rank load failed: \(error.localizedDescription)")
            return (nil, nil)
        }
    }
}

// MARK: - Home Card

/// "Your Style Progress" card shown on Home, directly under "Check today's fit".
/// Left: this week's personal average + week-over-week delta. Right: the user's
/// weekly leaderboard rank and score. Tapping "View details" opens the full
/// breakdown.
struct StyleProgressCard: View {
    @EnvironmentObject var appState: AppState
    // Owned by HomeView and shared with the CTA-footer stats, so the card reuses the
    // same single `fit_checks` read instead of issuing its own. HomeView drives
    // `load()` (on appear + on weeklyTrendRefreshToken), so the card no longer loads
    // independently.
    @ObservedObject var viewModel: StyleProgressViewModel
    @State private var showDetail = false

    var body: some View {
        // The entire card is one tap target — pressing anywhere opens the full
        // Style Progress screen. "View details" stays as a visual affordance only.
        Button(action: { showDetail = true }) {
            VStack(alignment: .leading, spacing: 18) {
                titleRow
                statsRow
            }
            .padding(20)
            .appCard()
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(HapticButtonStyle(style: .light))
        .navigationDestination(isPresented: $showDetail) {
            StyleProgressView(viewModel: viewModel)
        }
    }

    // MARK: Title row

    private var titleRow: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.fcAccent.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.fcAccent)
            }

            Text("Your Style Progress")
                .font(.fcBodyBold)
                .foregroundColor(.fcTextPrimary)

            Spacer(minLength: 8)

            // Visual hint only — the whole card is the tap target.
            HStack(spacing: 3) {
                Text("View details")
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.fcAccent)
        }
    }

    // MARK: Stats row

    private var statsRow: some View {
        HStack(alignment: .top, spacing: 18) {
            // Left — this week's personal average + delta.
            VStack(alignment: .leading, spacing: 6) {
                Text("This week avg")
                    .font(.fcCaption)
                    .foregroundColor(.fcTextSecondary)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(avgText)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundColor(.fcTextPrimary)
                    deltaBadge
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
                .frame(width: 1, height: 56)
                .overlay(Color.fcTextSecondary.opacity(0.18))

            // Right — weekly leaderboard rank + score.
            VStack(alignment: .leading, spacing: 4) {
                Text("Your rank")
                    .font(.fcCaption)
                    .foregroundColor(.fcTextSecondary)
                Text(rankText)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundColor(.fcTextPrimary)
                Text(scoreText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.fcTextSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Derived display values

    private var avgText: String {
        guard let avg = viewModel.currentWeekAverage else { return "—" }
        return String(format: "%.1f", avg)
    }

    private var rankText: String {
        guard let rank = viewModel.userWeeklyRank else { return "#—" }
        return "#\(rank)"
    }

    private var scoreText: String {
        if let score = viewModel.userWeeklyScore {
            return String(format: "Score %.1f", score)
        }
        return viewModel.isLoading ? "Loading…" : "Check a fit to rank"
    }

    @ViewBuilder
    private var deltaBadge: some View {
        // Only meaningful when we have both a current average and a prior week.
        if viewModel.currentWeekAverage != nil, let delta = viewModel.weeklyDelta {
            let up = delta > 0
            let flat = delta == 0
            let tint: Color = flat ? .fcTextSecondary : (up ? .fcSuccess : .fcError)
            HStack(spacing: 3) {
                Image(systemName: flat ? "minus" : (up ? "arrow.up" : "arrow.down"))
                    .font(.system(size: 10, weight: .bold))
                Text(StyleProgressFormat.delta(delta))
                    .font(.system(size: 13, weight: .bold))
            }
            .foregroundColor(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.14))
            .clipShape(Capsule())
        }
    }
}

// MARK: - Style Progress Screen

/// Full-screen weekly style breakdown reached from the Home "Your Style Progress"
/// card. Custom beige header (circular back + large title), one hero stats card
/// (this-week average, week-over-week delta, streak, progress bar and a 2×3 metric
/// grid), and a "This Week's Best Fits" carousel. Every card opens the SAME History
/// detail (`AnalysisDetailView`) used elsewhere. No white surfaces — beige/olive only.
struct StyleProgressView: View {
    @ObservedObject var viewModel: StyleProgressViewModel
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.fcBackground.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    header

                    if showSkeleton {
                        ProgressSkeleton(cardWidth: bestFitCardWidth)
                    } else {
                        progressCard
                        bestFitsSection
                    }

                    // Clears the floating tab bar AND the FAB that overlay this
                    // pushed view (it lives in the Home tab's nav stack).
                    Spacer(minLength: 140)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }
        }
        // Custom beige header replaces the system nav bar to match the design.
        .toolbar(.hidden, for: .navigationBar)
    }

    /// First load only: skeletons until the shared view model has its first numbers.
    private var showSkeleton: Bool {
        viewModel.isLoading && viewModel.currentWeekAverage == nil && viewModel.fitsThisWeek == 0
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.fcTextPrimary)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Color.fcAccentCream))
                    .overlay(Circle().stroke(Color.fcTextSecondary.opacity(0.15), lineWidth: 1))
                    .shadow(color: Color.fcShadow, radius: 6, x: 0, y: 3)
            }
            .buttonStyle(HapticButtonStyle(style: .light))

            Text("Style Progress")
                .font(.system(size: 34, weight: .bold))
                .foregroundColor(.fcTextPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Main progress card

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            heroRow
            if !visibleStats.isEmpty {
                statsGrid
            }
        }
        .padding(20)
        .appCard()
    }

    /// Top of the card: big average + delta badge + subtitle on the left, the
    /// circular fit-streak badge on the right.
    private var heroRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                Text("This week average")
                    .font(.fcCaption)
                    .foregroundColor(.fcTextSecondary)

                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(avgText)
                        .font(.system(size: 64, weight: .bold, design: .rounded))
                        .foregroundColor(.fcTextPrimary)
                        .overlay(alignment: .topTrailing) {
                            SparkAccent().offset(x: 14, y: 2)
                        }

                    VStack(alignment: .leading, spacing: 6) {
                        deltaBadge
                        improvementSubtitle
                    }
                    .padding(.top, 8)
                }
            }

            Spacer(minLength: 0)

            streakBadge
        }
    }

    @ViewBuilder
    private var deltaBadge: some View {
        if let delta = viewModel.weeklyDelta, viewModel.currentWeekAverage != nil {
            let style = DeltaStyle(delta)
            HStack(spacing: 4) {
                Image(systemName: style.icon)
                    .font(.system(size: 11, weight: .bold))
                Text("\(StyleProgressFormat.delta(delta)) this week")
                    .font(.system(size: 14, weight: .bold))
            }
            .foregroundColor(style.tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(style.tint.opacity(0.15))
            .clipShape(Capsule())
        }
    }

    @ViewBuilder
    private var improvementSubtitle: some View {
        if let delta = viewModel.weeklyDelta, viewModel.currentWeekAverage != nil {
            Text(subtitle(for: delta))
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(delta >= 0 ? .fcSuccess : .fcTextSecondary)
        }
    }

    private func subtitle(for delta: Double) -> String {
        if delta > 0 { return "Looking better this week" }
        if delta < 0 { return "A step down from last week" }
        return "Holding steady this week"
    }

    /// Circular fire-streak badge on the right of the hero row.
    private var streakBadge: some View {
        VStack(spacing: 2) {
            HStack(spacing: 3) {
                Text("🔥").font(.system(size: 15))
                Text("\(viewModel.streak)")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundColor(.fcTextPrimary)
            }
            Text("fit streak")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.fcTextSecondary)
        }
        .frame(width: 78, height: 78)
        .background(Circle().fill(Color.fcAccent.opacity(0.08)))
        .overlay(Circle().stroke(Color.fcAccent.opacity(0.25), lineWidth: 1.5))
    }

    // MARK: Dynamic stats grid

    /// One metric tile in the stats grid.
    private struct StatItem: Identifiable {
        let id: String
        let icon: String
        let title: String
        let value: String
        var valueColor: Color = .fcTextPrimary
    }

    /// Only the metrics that actually have data this week, in priority order.
    /// Anything nil/unavailable (e.g. previous-week average or weekly change on a
    /// user's first week) is simply omitted — no placeholder "–" tiles.
    private var visibleStats: [StatItem] {
        var items: [StatItem] = []

        if let rank = viewModel.userWeeklyRank {
            items.append(.init(id: "rank", icon: "trophy",
                               title: "Your weekly rank", value: "#\(rank)"))
        }
        if let score = viewModel.userWeeklyScore {
            items.append(.init(id: "score", icon: "star",
                               title: "Your ranking score", value: String(format: "%.1f", score)))
        }
        if viewModel.fitsThisWeek > 0 {
            items.append(.init(id: "fits", icon: "checklist",
                               title: "Fits checked this week", value: "\(viewModel.fitsThisWeek)"))
        }
        if let best = viewModel.bestScoreThisWeek {
            items.append(.init(id: "best", icon: "crown",
                               title: "Best fit this week", value: String(format: "%.1f", best)))
        }
        if let prev = viewModel.previousWeekAverage {
            items.append(.init(id: "prev", icon: "calendar",
                               title: "Previous week average", value: String(format: "%.1f", prev)))
        }
        if let delta = viewModel.weeklyDelta, viewModel.currentWeekAverage != nil {
            items.append(.init(id: "change", icon: DeltaStyle(delta).icon,
                               title: "Weekly change", value: StyleProgressFormat.delta(delta),
                               valueColor: changeColor))
        }
        return items
    }

    /// Two-column grid so the visible tiles always flow flush with no empty holes,
    /// regardless of how many metrics are available.
    private var statsGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
            spacing: 10
        ) {
            ForEach(visibleStats) { statCell($0) }
        }
    }

    private func statCell(_ item: StatItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                ZStack {
                    Circle().fill(Color.fcAccent.opacity(0.12)).frame(width: 32, height: 32)
                    Image(systemName: item.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.fcAccent)
                }
                Text(item.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.fcTextSecondary)
                    .lineLimit(2, reservesSpace: true)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            Text(item.value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundColor(item.valueColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.fcBackground.opacity(0.55))
        )
    }

    // MARK: - This Week's Best Fits

    private var bestFitsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("This Week's Best Fits")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.fcTextPrimary)
                Text("Your strongest looks ranked by score")
                    .font(.fcCaption)
                    .foregroundColor(.fcTextSecondary)
            }

            bestFitsContent
        }
    }

    @ViewBuilder
    private var bestFitsContent: some View {
        let fits = viewModel.topFitsThisWeek
        if fits.isEmpty {
            bestFitsEmptyState
        } else {
            carousel(fits)
        }
    }

    /// The user's ranked best fits laid out in a single row. There are at most three
    /// (the view model caps `topFitsThisWeek` at 3) and three cards fit across the
    /// screen at once, so this is always one page — no pager or page dots needed.
    /// Each card pushes the SAME `AnalysisDetailView` History uses, by `analysisId`.
    private func carousel(_ fits: [WeeklyBestFit]) -> some View {
        let cardWidth = bestFitCardWidth
        return HStack(spacing: bestFitGap) {
            ForEach(Array(fits.enumerated()), id: \.element.id) { index, fit in
                NavigationLink {
                    AnalysisDetailView(
                        analysisId: fit.id,
                        initialThumbnailURL: fit.imageURL?.absoluteString,
                        initialScore: fit.score
                    )
                    .environmentObject(appState)
                } label: {
                    BestFitCard(fit: fit, rank: index + 1, width: cardWidth)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    private var bestFitsEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 34, weight: .light))
                .foregroundColor(.fcTextSecondary.opacity(0.5))
            Text("Check your first fit this week")
                .font(.fcBody)
                .foregroundColor(.fcTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .appCard()
    }

    private var bestFitGap: CGFloat { 12 }

    /// Width that fits three cards across the 20pt-padded content with two gaps.
    private var bestFitCardWidth: CGFloat {
        let usable = UIScreen.main.bounds.width - 40 - bestFitGap * 2
        return (usable / 3).rounded(.down)
    }

    // MARK: - Display formatting

    private var avgText: String {
        guard let avg = viewModel.currentWeekAverage else { return "–" }
        return String(format: "%.1f", avg)
    }

    private var changeColor: Color {
        guard let delta = viewModel.weeklyDelta else { return .fcTextPrimary }
        if delta > 0 { return .fcSuccess }
        if delta < 0 { return .fcError }
        return .fcTextSecondary
    }
}

// MARK: - Shared formatting

private enum StyleProgressFormat {
    /// Signed delta string, e.g. "+0.4", "-0.3", "0.0".
    static func delta(_ value: Double) -> String {
        if value > 0 { return String(format: "+%.1f", value) }
        if value < 0 { return String(format: "%.1f", value) } // sign already present
        return "0.0"
    }
}

// MARK: - Hero-row helpers

/// Tint + arrow for the week-over-week delta badge / change cell.
private struct DeltaStyle {
    let tint: Color
    let icon: String

    init(_ delta: Double) {
        if delta > 0 { tint = .fcSuccess; icon = "arrow.up.right" }
        else if delta < 0 { tint = .fcError; icon = "arrow.down.right" }
        else { tint = .fcTextSecondary; icon = "arrow.right" }
    }
}

/// Small olive "shine" flourish that sits at the top-right of the big average.
private struct SparkAccent: View {
    var body: some View {
        ZStack {
            mark.rotationEffect(.degrees(-15)).offset(x: -1, y: -8)
            mark.rotationEffect(.degrees(18)).offset(x: 7, y: -2)
            mark.rotationEffect(.degrees(48)).offset(x: 9, y: 8)
        }
        .foregroundColor(.fcAccent)
        .frame(width: 18, height: 22)
    }

    private var mark: some View {
        Capsule().frame(width: 3, height: 11)
    }
}

// MARK: - Best-Fit Card

/// One ranked best-fit card in the carousel: a smart-cropped photo with a medal
/// rank badge (gold/silver/bronze), a star on #1, and a laurel + score footer on a
/// cream surface bordered in the medal colour.
private struct BestFitCard: View {
    let fit: WeeklyBestFit
    let rank: Int
    let width: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            SmartOutfitImageView(source: fit.imageURL.map { .remote($0) })
                .frame(width: width, height: width * 1.12)
                .clipped()
                .overlay(alignment: .topLeading) {
                    MedalRankBadge(rank: rank).padding(8)
                }
                .overlay(alignment: .topTrailing) {
                    if rank == 1 { bestStar.padding(8) }
                }

            scoreFooter
        }
        .background(Color.fcAccentCream)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(medalColor, lineWidth: 2)
        )
        .shadow(color: Color.fcShadow, radius: rank == 1 ? 12 : 8, x: 0, y: 4)
    }

    private var scoreFooter: some View {
        HStack(spacing: 6) {
            LaurelWreath(color: medalColor)
            Spacer(minLength: 0)
            VStack(spacing: 0) {
                Text("Score")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.fcTextSecondary)
                Text(String(format: "%.1f", fit.score))
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundColor(.fcTextPrimary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(width: width)
    }

    private var bestStar: some View {
        Image(systemName: "star.fill")
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(.fcGold)
            .padding(6)
            .background(Circle().fill(Color.fcAccentCream))
            .overlay(Circle().stroke(Color.fcGold.opacity(0.4), lineWidth: 1))
    }

    private var medalColor: Color {
        switch rank {
        case 1: return .fcGold
        case 2: return .fcSilver
        default: return .fcBronze
        }
    }
}

/// Medal-tinted "#N" chip shown over a best-fit photo (gold / silver / bronze).
private struct MedalRankBadge: View {
    let rank: Int

    var body: some View {
        Text("#\(rank)")
            .font(.system(size: 13, weight: .heavy, design: .rounded))
            .foregroundColor(.fcAccentCream)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color))
    }

    private var color: Color {
        switch rank {
        case 1: return .fcGold
        case 2: return .fcSilver
        default: return .fcBronze
        }
    }
}

/// A laurel wreath built from the two mirrored SF Symbol halves, tinted to match
/// the card's medal colour.
private struct LaurelWreath: View {
    let color: Color

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "laurel.leading")
            Image(systemName: "laurel.trailing")
        }
        .font(.system(size: 18, weight: .semibold))
        .foregroundColor(color)
    }
}

// MARK: - Loading skeleton

/// First-load placeholders that mirror the real card shapes (one big progress
/// card + a three-card best-fits row), redacted so they read as loading.
private struct ProgressSkeleton: View {
    let cardWidth: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.fcSurface)
                .frame(height: 360)
                .shadow(color: Color.fcShadow, radius: 16, x: 0, y: 6)

            VStack(alignment: .leading, spacing: 14) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.fcSurface)
                    .frame(width: 220, height: 24)
                HStack(spacing: 12) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.fcSurface)
                            .frame(width: cardWidth, height: cardWidth * 1.55)
                    }
                }
            }
        }
        .redacted(reason: .placeholder)
    }
}
