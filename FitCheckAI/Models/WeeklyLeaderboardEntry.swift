import Foundation
import FirebaseFirestore

/// A single public user's standing on the weekly outfit-rating leaderboard.
///
/// Documents live at `weeklyTrends/{weekId}/users/{uid}` and are written by the
/// backend aggregator as outfits are rated. Only entries with `isPublic == true`
/// are surfaced in the app.
struct WeeklyLeaderboardEntry: Codable, Identifiable {
    /// Firestore document ID — the user's uid.
    @DocumentID var id: String?
    var displayName: String?
    var photoURL: String?
    /// Sum of every outfit rating earned this week — the ranking key.
    var totalWeeklyRating: Double
    /// Number of fits checked this week.
    var outfitCount: Int
    /// Highest single outfit score this week.
    var bestScore: Double
    /// Whether the user opted into public/leaderboard visibility.
    var isPublic: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case photoURL
        case totalWeeklyRating
        case outfitCount
        case bestScore
        case isPublic
    }

    /// Display name with a graceful fallback for anonymous users.
    var name: String {
        if let displayName, !displayName.trimmingCharacters(in: .whitespaces).isEmpty {
            return displayName
        }
        return "Anonymous"
    }

    /// e.g. "42.5 pts"
    var pointsLabel: String {
        String(format: "%.1f pts", totalWeeklyRating)
    }

    /// e.g. "6 fits"
    var fitsLabel: String {
        "\(outfitCount) fit\(outfitCount == 1 ? "" : "s")"
    }
}

/// Identifies the current leaderboard week.
///
/// IMPORTANT: the backend aggregator that writes `weeklyTrends/{weekId}/users`
/// MUST produce the exact same identifier (ISO-8601 year + week, UTC) so the
/// client reads the right document.
enum WeekIdentifier {
    /// Current ISO-8601 week id, e.g. "2026-W24", computed in UTC.
    static var current: String {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
        let year = comps.yearForWeekOfYear ?? 0
        let week = comps.weekOfYear ?? 0
        return String(format: "%04d-W%02d", year, week)
    }
}

/// Reads the weekly leaderboard from Firestore.
enum WeeklyLeaderboardService {
    /// Fetches the top public users for the current week, highest rating first.
    static func fetchTopEntries(limit: Int) async throws -> [WeeklyLeaderboardEntry] {
        let weekId = WeekIdentifier.current
        print("[WeeklyLeaderboard] reading weeklyTrends/\(weekId)/users where isPublic==true order totalWeeklyRating desc limit \(limit)")

        let snapshot = try await Firestore.firestore()
            .collection("weeklyTrends")
            .document(weekId)
            .collection("users")
            .whereField("isPublic", isEqualTo: true)
            .order(by: "totalWeeklyRating", descending: true)
            .limit(to: limit)
            .getDocuments()

        let entries = snapshot.documents.compactMap { try? $0.data(as: WeeklyLeaderboardEntry.self) }

        print("[WeeklyLeaderboard] \(snapshot.documents.count) doc(s) returned for \(weekId), decoded \(entries.count)")
        if snapshot.documents.isEmpty {
            // Empty almost always means: nobody scored this week yet, the writer
            // used a different weekId, or every entry has isPublic != true.
            print("[WeeklyLeaderboard] ⚠️ empty — no public entries written under weeklyTrends/\(weekId)/users yet")
        } else {
            for entry in entries {
                print("[WeeklyLeaderboard]   • \(entry.name) totalWeeklyRating=\(entry.totalWeeklyRating) outfitCount=\(entry.outfitCount)")
            }
            if entries.count < snapshot.documents.count {
                print("[WeeklyLeaderboard] ⚠️ \(snapshot.documents.count - entries.count) doc(s) failed to decode — check field names match WeeklyLeaderboardEntry")
            }
        }

        return entries
    }
}
