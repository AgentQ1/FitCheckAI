import SwiftUI
import FirebaseAuth
import FirebaseFirestore

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
        let (current, previous) = await bucketsTask
        let (rank, rankScore) = await rankTask

        currentWeekAverage = current.average
        previousWeekAverage = previous.average
        fitsThisWeek = current.count
        bestScoreThisWeek = current.best

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
    private func loadWeekBuckets(uid: String) async -> (current: WeekStats, previous: WeekStats) {
        let cal = isoCalendarUTC
        guard
            let weekInterval = cal.dateInterval(of: .weekOfYear, for: Date()),
            let prevStart = cal.date(byAdding: .weekOfYear, value: -1, to: weekInterval.start)
        else { return (.empty, .empty) }

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
            for doc in snapshot.documents {
                let d = doc.data()
                guard
                    let score = d["overall_score"] as? Double ?? d["overallScore"] as? Double,
                    let ts = (d["createdAt"] as? Timestamp)?.dateValue()
                else { continue }
                if ts >= curStart && ts < curEnd {
                    current.append(score)
                } else if ts >= prevStart && ts < curStart {
                    previous.append(score)
                }
            }
            return (WeekStats(scores: current), WeekStats(scores: previous))
        } catch {
            print("[StyleProgress] week query failed: \(error.localizedDescription)")
            return (.empty, .empty)
        }
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
    @StateObject private var viewModel = StyleProgressViewModel()
    @State private var showDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            titleRow
            statsRow
        }
        .padding(20)
        .appCard()
        .navigationDestination(isPresented: $showDetail) {
            StyleProgressDetailView(viewModel: viewModel)
        }
        .task { await viewModel.load() }
        // A finished check bumps this token; reload so the card reflects the new
        // average and rank without a manual pull-to-refresh.
        .onChange(of: appState.weeklyTrendRefreshToken) { _, _ in
            Task { await viewModel.load() }
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

            Button(action: { showDetail = true }) {
                HStack(spacing: 3) {
                    Text("View details")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.fcAccent)
            }
            .buttonStyle(HapticButtonStyle(style: .light))
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

// MARK: - Detail Screen

/// Full breakdown behind "View details". Same beige background and card style as
/// the rest of the app — no white surfaces, olive accents only.
struct StyleProgressDetailView: View {
    @ObservedObject var viewModel: StyleProgressViewModel

    var body: some View {
        ZStack {
            Color.fcBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    statsCard
                    explanationCard
                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
            }
        }
        .navigationTitle("Style Progress")
        .navigationBarTitleDisplayMode(.large)
    }

    private var statsCard: some View {
        VStack(spacing: 0) {
            statRow("This week average", value: optional(viewModel.currentWeekAverage))
            divider
            statRow("Previous week average", value: optional(viewModel.previousWeekAverage))
            divider
            statRow("Weekly change", value: changeText, valueColor: changeColor)
            divider
            statRow("Your weekly rank", value: viewModel.userWeeklyRank.map { "#\($0)" } ?? "#—")
            divider
            statRow("Your ranking score", value: optional(viewModel.userWeeklyScore))
            divider
            statRow("Fits checked this week", value: "\(viewModel.fitsThisWeek)")
            divider
            statRow("Best fit this week", value: optional(viewModel.bestScoreThisWeek))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .appCard()
    }

    private var explanationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            explanationLine("chart.bar.fill",
                            "Your weekly average is based on your outfit checks this week.")
            explanationLine("trophy.fill",
                            "Your rank follows the same Week Trend leaderboard logic.")
        }
        .padding(18)
        .appCard()
    }

    private func explanationLine(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.fcAccent)
                .frame(width: 22)
            Text(text)
                .font(.fcCaption)
                .foregroundColor(.fcTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func statRow(_ label: String, value: String, valueColor: Color = .fcTextPrimary) -> some View {
        HStack {
            Text(label)
                .font(.fcBody)
                .foregroundColor(.fcTextSecondary)
            Spacer()
            Text(value)
                .font(.fcBodyBold)
                .foregroundColor(valueColor)
        }
        .padding(.vertical, 14)
    }

    private var divider: some View {
        Divider().background(Color.fcTextSecondary.opacity(0.12))
    }

    // MARK: Detail formatting

    private func optional(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f", value)
    }

    private var changeText: String {
        guard let delta = viewModel.weeklyDelta else { return "—" }
        return StyleProgressFormat.delta(delta)
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
