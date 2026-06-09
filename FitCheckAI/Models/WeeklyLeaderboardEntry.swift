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
    /// Sum of every outfit rating earned this week. Used to derive the weekly
    /// average — NOT used directly for ranking.
    var totalWeeklyRating: Double
    /// Number of fits checked this week.
    var outfitCount: Int
    /// Highest single outfit score this week.
    var bestScore: Double
    /// Whether the user opted into public/leaderboard visibility.
    var isPublic: Bool
    /// Timestamp of the user's most recent upload this week, used only as a
    /// final tiebreaker. Optional so older/backend docs without it still decode.
    var lastUploadAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case photoURL
        case totalWeeklyRating
        case outfitCount
        case bestScore
        case isPublic
        case lastUploadAt
    }

    /// Number of fits required to reach full ranking confidence.
    static let fullConfidenceFitCount = 5

    /// Display name with a graceful fallback for anonymous users.
    var name: String {
        if let displayName, !displayName.trimmingCharacters(in: .whitespaces).isEmpty {
            return displayName
        }
        return "Anonymous"
    }

    /// Average outfit score this week. Zero when no fits have been checked.
    var weeklyAverageScore: Double {
        guard outfitCount > 0 else { return 0 }
        return totalWeeklyRating / Double(outfitCount)
    }

    /// Ramps from 0.2 (1 fit) to 1.0 (5+ fits) so a single lucky high score
    /// can't outrank a consistent week.
    var confidenceMultiplier: Double {
        min(Double(outfitCount) / Double(Self.fullConfidenceFitCount), 1.0)
    }

    /// Hidden weighted ranking key — never shown to users.
    var weeklyTrendScore: Double {
        weeklyAverageScore * confidenceMultiplier
    }

    /// True until the user has logged enough fits for full ranking confidence.
    var needsMoreFits: Bool {
        outfitCount < Self.fullConfidenceFitCount
    }

    /// e.g. "8.0 avg" — the user-facing score (average, not total).
    var averageLabel: String {
        String(format: "%.1f avg", weeklyAverageScore)
    }

    /// e.g. "6 fits"
    var fitsLabel: String {
        "\(outfitCount) fit\(outfitCount == 1 ? "" : "s")"
    }

    /// Subtle hint shown only while the user hasn't reached full confidence.
    var confidenceHint: String? {
        needsMoreFits ? "Needs \(Self.fullConfidenceFitCount) fits to fully rank" : nil
    }

    // MARK: - Today (daily) presentation

    /// Right-side score for the Today leaderboard, e.g. "9.1 best" — the highest
    /// single outfit score the user hit today (NOT an average).
    var todayBestLabel: String {
        String(format: "%.1f best", bestScore)
    }

    /// Subtitle for the Today leaderboard, e.g. "Today, 1 fit" / "Today, 3 fits".
    var todayFitsLabel: String {
        "Today, \(outfitCount) fit\(outfitCount == 1 ? "" : "s")"
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
    /// Fetches the top public users for the current week, ranked by the
    /// confidence-weighted weekly trend score.
    ///
    /// Ranking can't be expressed as a single Firestore order (the trend score
    /// is derived from average × confidence), so we pull a generous candidate
    /// pool and rank it on the client. The pool is bounded by `totalWeeklyRating`
    /// purely to cap reads, then re-sorted by the real ranking key.
    static func fetchTopEntries(limit: Int) async throws -> [WeeklyLeaderboardEntry] {
        let weekId = WeekIdentifier.current
        // Over-fetch so consistent-but-lower-total users aren't excluded before
        // the confidence weighting is applied.
        let poolSize = max(limit * 5, 100)
        print("[WeeklyLeaderboard] reading weeklyTrends/\(weekId)/users where isPublic==true pool \(poolSize), ranking by weeklyTrendScore, returning top \(limit)")

        let snapshot = try await Firestore.firestore()
            .collection("weeklyTrends")
            .document(weekId)
            .collection("users")
            .whereField("isPublic", isEqualTo: true)
            .order(by: "totalWeeklyRating", descending: true)
            .limit(to: poolSize)
            .getDocuments()

        let decoded = snapshot.documents.compactMap { try? $0.data(as: WeeklyLeaderboardEntry.self) }
        let entries = Array(decoded.sorted(by: ranks).prefix(limit))

        print("[WeeklyLeaderboard] \(snapshot.documents.count) doc(s) returned for \(weekId), decoded \(decoded.count), returning \(entries.count)")
        if snapshot.documents.isEmpty {
            // Empty almost always means: nobody scored this week yet, the writer
            // used a different weekId, or every entry has isPublic != true.
            print("[WeeklyLeaderboard] ⚠️ empty — no public entries written under weeklyTrends/\(weekId)/users yet")
        } else {
            for entry in entries {
                print("[WeeklyLeaderboard]   • \(entry.name) avg=\(entry.weeklyAverageScore) fits=\(entry.outfitCount) trendScore=\(entry.weeklyTrendScore)")
            }
            if decoded.count < snapshot.documents.count {
                print("[WeeklyLeaderboard] ⚠️ \(snapshot.documents.count - decoded.count) doc(s) failed to decode — check field names match WeeklyLeaderboardEntry")
            }
        }

        return entries
    }

    /// Fair ranking order: weighted trend score, then raw average, then fit
    /// count, then most recent upload. Returns true if `a` outranks `b`.
    private static func ranks(_ a: WeeklyLeaderboardEntry, _ b: WeeklyLeaderboardEntry) -> Bool {
        if a.weeklyTrendScore != b.weeklyTrendScore {
            return a.weeklyTrendScore > b.weeklyTrendScore
        }
        if a.weeklyAverageScore != b.weeklyAverageScore {
            return a.weeklyAverageScore > b.weeklyAverageScore
        }
        if a.outfitCount != b.outfitCount {
            return a.outfitCount > b.outfitCount
        }
        return (a.lastUploadAt ?? .distantPast) > (b.lastUploadAt ?? .distantPast)
    }
}

// MARK: - Daily ("Today's Best") leaderboard

/// Identifies the current leaderboard day.
///
/// IMPORTANT: the backend aggregator that writes `dailyTrends/{dayId}/users`
/// (`currentDayId` in analyze-outfit.ts) MUST produce the same identifier so the
/// client reads the right document. UTC — not the user's local tz — is
/// intentional: a *shared* daily board needs one global day boundary, otherwise
/// users in different timezones would land on different `dayId` docs and never
/// compete. Mirrors `WeekIdentifier`, which is UTC for the same reason.
enum DayIdentifier {
    /// Current UTC calendar-day id, e.g. "2026-06-08".
    static var current: String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC") ?? .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}

/// Reads the daily "Today's Best" leaderboard from Firestore.
///
/// Mirrors `WeeklyLeaderboardService`, but ranks purely by the highest single
/// outfit score earned today — a daily mini-competition. Documents live at
/// `dailyTrends/{dayId}/users/{uid}` and carry the same denormalized fields as
/// the weekly entry (so the same row UI/model can render them), where
/// `bestScore` is today's top score and `outfitCount` is today's fit count.
enum DailyLeaderboardService {
    static func fetchTopEntries(limit: Int) async throws -> [WeeklyLeaderboardEntry] {
        let dayId = DayIdentifier.current
        print("[DailyLeaderboard] reading dailyTrends/\(dayId)/users where isPublic==true, ranking by bestScore, returning top \(limit)")

        let snapshot = try await Firestore.firestore()
            .collection("dailyTrends")
            .document(dayId)
            .collection("users")
            .whereField("isPublic", isEqualTo: true)
            .order(by: "bestScore", descending: true)
            .limit(to: limit)
            .getDocuments()

        // Build entries from raw data rather than Codable: a daily doc only needs
        // bestScore/outfitCount and shouldn't be required to carry the weekly-only
        // `totalWeeklyRating` field just to decode.
        let entries: [WeeklyLeaderboardEntry] = snapshot.documents.map { doc in
            let data = doc.data()
            return WeeklyLeaderboardEntry(
                id: doc.documentID,
                displayName: data["displayName"] as? String,
                photoURL: data["photoURL"] as? String,
                totalWeeklyRating: 0, // unused for daily
                outfitCount: data["outfitCount"] as? Int ?? 0,
                bestScore: data["bestScore"] as? Double ?? 0,
                isPublic: data["isPublic"] as? Bool ?? false,
                lastUploadAt: (data["lastUploadAt"] as? Timestamp)?.dateValue()
            )
        }

        print("[DailyLeaderboard] \(snapshot.documents.count) doc(s) for \(dayId), returning \(entries.count)")
        if snapshot.documents.isEmpty {
            print("[DailyLeaderboard] ⚠️ empty — no public entries written under dailyTrends/\(dayId)/users yet")
        } else {
            for entry in entries {
                print("[DailyLeaderboard]   • \(entry.name) best=\(entry.bestScore) fits=\(entry.outfitCount)")
            }
        }

        return entries
    }
}
