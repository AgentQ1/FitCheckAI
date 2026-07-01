import Foundation
import FirebaseAuth
import FirebaseFirestore

/// Backs the stats footer inside the Home "Check today's fit" card: the user's
/// current check-in streak and their best score this week.
///
/// Both are derived live from the user's own `users/{uid}/fit_checks` in a single
/// read (the stored `AppUser.streakCount` / `bestScore` are deliberately NOT used
/// — the spec wants these computed from active checks). "Best this week" uses the
/// same ISO-week (UTC) boundary as the Style Progress card so the two cards agree.
@MainActor
final class HomeStatsViewModel: ObservableObject {
    @Published var firstName: String?
    @Published var currentStreak: Int = 0
    @Published var bestScoreThisWeek: Double?
    @Published var isLoadingStats: Bool = true

    private let db = Firestore.firestore()

    func load(displayName: String?) async {
        firstName = Self.firstName(from: displayName)
        guard let uid = Auth.auth().currentUser?.uid else {
            // Guest / signed-out: no personal stats to show.
            currentStreak = 0
            bestScoreThisWeek = nil
            isLoadingStats = false
            return
        }
        isLoadingStats = true
        do {
            // Same query shape History/Style Progress use, so no new index.
            let snapshot = try await db.collection("users/\(uid)/fit_checks")
                .whereField("isDeleted", isEqualTo: false)
                .order(by: "createdAt", descending: true)
                .limit(to: 200)
                .getDocuments()

            let checks: [(date: Date, score: Double?)] = snapshot.documents.compactMap { doc in
                let d = doc.data()
                guard let ts = (d["createdAt"] as? Timestamp)?.dateValue() else { return nil }
                let score = d["overall_score"] as? Double ?? d["overallScore"] as? Double
                return (ts, score)
            }

            currentStreak = Self.streak(from: checks.map { $0.date })
            bestScoreThisWeek = Self.bestThisWeek(checks)
        } catch {
            print("[HomeStats] load failed: \(error.localizedDescription)")
            currentStreak = 0
            bestScoreThisWeek = nil
        }
        isLoadingStats = false
    }

    // MARK: - Derivations (pure, testable)

    /// First word of a display name, or nil when there's no usable name.
    static func firstName(from displayName: String?) -> String? {
        guard
            let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return nil }
        return trimmed.split(separator: " ").first.map(String.init)
    }

    /// Consecutive calendar days (local time) with at least one active check,
    /// ending today — or yesterday, so a streak isn't shown as broken just because
    /// the user hasn't checked in yet today. 0 when neither today nor yesterday
    /// has a check.
    static func streak(from dates: [Date]) -> Int {
        guard !dates.isEmpty else { return 0 }
        let cal = Calendar.current
        let days = Set(dates.map { cal.startOfDay(for: $0) })
        let today = cal.startOfDay(for: Date())
        guard let yesterday = cal.date(byAdding: .day, value: -1, to: today) else { return 0 }

        let anchor: Date
        if days.contains(today) { anchor = today }
        else if days.contains(yesterday) { anchor = yesterday }
        else { return 0 }

        var streak = 0
        var cursor = anchor
        while days.contains(cursor) {
            streak += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return streak
    }

    /// Highest active score within the current ISO week (UTC), rounded to 1 dp.
    /// nil when there are no scored checks this week.
    static func bestThisWeek(_ checks: [(date: Date, score: Double?)]) -> Double? {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        guard let week = cal.dateInterval(of: .weekOfYear, for: Date()) else { return nil }

        let scores = checks.compactMap { check -> Double? in
            guard check.date >= week.start, check.date < week.end else { return nil }
            return check.score
        }
        guard let best = scores.max() else { return nil }
        return (best * 10).rounded() / 10
    }
}
