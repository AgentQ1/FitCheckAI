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

    // MARK: - Today (daily) ranking inputs
    // Written by the backend recompute (see analyze-outfit.ts). Weekly docs don't
    // carry these, so they're optional and decode to nil there.

    /// Average of all of today's active outfit scores — the 3rd tie-break.
    var averageScoreToday: Double?
    /// Earliest time the user reached `bestScore` today — the final tie-break.
    var timeReachedHighestScoreToday: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case photoURL
        case totalWeeklyRating
        case outfitCount
        case bestScore
        case isPublic
        case lastUploadAt
        case averageScoreToday
        case timeReachedHighestScoreToday
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

    // MARK: - Today (daily) ranking + tie explanations

    /// Today's ranking order, true if `a` outranks `b`:
    ///   1. highest single score today (desc)
    ///   2. more fits today (desc) — rewards effort over a single lucky shot
    ///   3. higher average today (desc) — consistency
    ///   4. earliest time reaching the best score (asc) — deterministic final key
    static func ranksToday(_ a: WeeklyLeaderboardEntry, _ b: WeeklyLeaderboardEntry) -> Bool {
        if a.bestScore != b.bestScore { return a.bestScore > b.bestScore }
        if a.outfitCount != b.outfitCount { return a.outfitCount > b.outfitCount }
        let aAvg = a.averageScoreToday ?? 0
        let bAvg = b.averageScoreToday ?? 0
        if aAvg != bAvg { return aAvg > bAvg }
        return (a.timeReachedHighestScoreToday ?? .distantFuture)
             < (b.timeReachedHighestScoreToday ?? .distantFuture)
    }

    private static func fullyTied(_ a: WeeklyLeaderboardEntry, _ b: WeeklyLeaderboardEntry) -> Bool {
        a.bestScore == b.bestScore
            && a.outfitCount == b.outfitCount
            && (a.averageScoreToday ?? 0) == (b.averageScoreToday ?? 0)
    }

    /// Subtext explaining why the row at `index` sits where it does within a
    /// best-score tie. Returns nil when the row isn't tied on best score.
    /// `entries` must be the already-ranked Today list (sorted by ``ranksToday``).
    static func todayTieNote(entries: [WeeklyLeaderboardEntry], index: Int) -> String? {
        guard entries.indices.contains(index) else { return nil }
        let entry = entries[index]
        let group = entries.filter { $0.bestScore == entry.bestScore }
        guard group.count > 1 else { return nil }   // not tied → no explanation
        let bestStr = String(format: "%.1f", entry.bestScore)

        // 1. Sole highest fit count in the tie group → won on effort.
        let maxCount = group.map { $0.outfitCount }.max() ?? 0
        let topByCount = group.filter { $0.outfitCount == maxCount }
        if entry.outfitCount == maxCount && topByCount.count == 1 {
            return "Same best · more fits wins"
        }

        // 2. Among rows sharing this row's fit count, average breaks the tie.
        let peers = group.filter { $0.outfitCount == entry.outfitCount }
        let avg = entry.averageScoreToday ?? 0
        if peers.count > 1 {
            let maxAvg = peers.compactMap { $0.averageScoreToday }.max() ?? 0
            let topByAvg = peers.filter { ($0.averageScoreToday ?? 0) == maxAvg }
            if avg == maxAvg && topByAvg.count == 1 {
                return "Same best · higher avg wins"
            }
            if avg == maxAvg {
                // Fully tied on best+fits+avg — earliest to the score ranks first.
                let prevFullyTied = index > 0 && fullyTied(entries[index - 1], entry)
                return prevFullyTied ? "Tied score" : "First to \(bestStr)"
            }
            return String(format: "Avg %.1f today", avg)
        }

        // 3. Unique fit count that isn't the group max → lost the tie on fits.
        return "Same best · \(entry.outfitCount) fit\(entry.outfitCount == 1 ? "" : "s") today"
    }
}

// MARK: - Public Profile mirror

/// Minimal, world-readable copy of a user's profile (`publicProfiles/{uid}`).
/// Leaderboards hydrate their rows from this so an edited name/photo shows up
/// even for users whose private `users/{uid}` doc the viewer can't read.
struct PublicProfile {
    var displayName: String?
    var photoURL: String?
}

enum PublicProfileService {
    static let collectionName = "publicProfiles"

    /// Upserts the public mirror. Safe to call on every profile change and on
    /// login (keeps pre-existing users backfilled). Failures are non-fatal —
    /// the leaderboard simply falls back to the denormalized row values.
    static func write(uid: String,
                      displayName: String?,
                      photoURL: String?,
                      profileImageUpdatedAt: Int? = nil) async {
        var data: [String: Any] = ["updatedAt": FieldValue.serverTimestamp()]
        if let displayName { data["displayName"] = displayName }
        if let photoURL { data["photoURL"] = photoURL }
        if let profileImageUpdatedAt { data["profileImageUpdatedAt"] = profileImageUpdatedAt }
        do {
            try await Firestore.firestore()
                .collection(collectionName)
                .document(uid)
                .setData(data, merge: true)
            print("[PublicProfile] wrote uid=\(uid) name=\(displayName ?? "<keep>") photo=\(photoURL ?? "<keep>")")
        } catch {
            print("[PublicProfile] write failed uid=\(uid): \(error.localizedDescription)")
        }
    }

    /// Batch-fetches public profiles for `uids`, chunked to respect Firestore's
    /// `in`-query limit. Returns a uid→profile map; missing users are omitted.
    static func fetch(uids: [String]) async -> [String: PublicProfile] {
        let unique = Array(Set(uids))
        guard !unique.isEmpty else { return [:] }
        var result: [String: PublicProfile] = [:]
        await withTaskGroup(of: [String: PublicProfile].self) { group in
            for chunk in unique.chunked(into: 10) {
                group.addTask {
                    var partial: [String: PublicProfile] = [:]
                    do {
                        let snap = try await Firestore.firestore()
                            .collection(collectionName)
                            .whereField(FieldPath.documentID(), in: chunk)
                            .getDocuments()
                        for doc in snap.documents {
                            let d = doc.data()
                            partial[doc.documentID] = PublicProfile(
                                displayName: d["displayName"] as? String,
                                photoURL: d["photoURL"] as? String
                            )
                        }
                    } catch {
                        print("[PublicProfile] fetch chunk failed: \(error.localizedDescription)")
                    }
                    return partial
                }
            }
            for await partial in group { result.merge(partial) { _, new in new } }
        }
        return result
    }

    /// Replaces each entry's denormalized name/photo with the live values from
    /// `publicProfiles`, falling back to the original row data when a user has no
    /// public mirror yet. Call right after fetching leaderboard entries.
    static func hydrate(_ entries: [WeeklyLeaderboardEntry]) async -> [WeeklyLeaderboardEntry] {
        let profiles = await fetch(uids: entries.compactMap { $0.id })
        guard !profiles.isEmpty else { return entries }
        return entries.map { entry in
            guard let uid = entry.id, let profile = profiles[uid] else { return entry }
            return entry.merging(profile)
        }
    }
}

extension WeeklyLeaderboardEntry {
    /// Returns a copy whose name/photo are replaced by `profile` when present —
    /// the leaderboard's source of truth for display becomes the live profile.
    func merging(_ profile: PublicProfile) -> WeeklyLeaderboardEntry {
        var copy = self
        if let dn = profile.displayName, !dn.trimmingCharacters(in: .whitespaces).isEmpty {
            copy.displayName = dn
        }
        if let pu = profile.photoURL, !pu.isEmpty {
            copy.photoURL = pu
        }
        return copy
    }
}

extension Array {
    /// Splits into consecutive sub-arrays of at most `size` elements.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
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
        } else if decoded.count < snapshot.documents.count {
            print("[WeeklyLeaderboard] ⚠️ \(snapshot.documents.count - decoded.count) doc(s) failed to decode — check field names match WeeklyLeaderboardEntry")
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
        // The full ranking (best → fits → avg → time) can't be expressed as one
        // Firestore order, so over-fetch a pool ordered by the primary key
        // (bestScore) and apply the complete tie-break on the client.
        let poolSize = max(limit * 5, 100)
        print("[DailyLeaderboard] reading dailyTrends/\(dayId)/users where isPublic==true pool \(poolSize), ranking best→fits→avg→time, returning top \(limit)")

        let snapshot = try await Firestore.firestore()
            .collection("dailyTrends")
            .document(dayId)
            .collection("users")
            .whereField("isPublic", isEqualTo: true)
            .order(by: "bestScore", descending: true)
            .limit(to: poolSize)
            .getDocuments()

        let pool = snapshot.documents.map { entry(from: $0) }
        let ranked = Array(pool.sorted(by: WeeklyLeaderboardEntry.ranksToday).prefix(limit))

        print("[DailyLeaderboard] \(snapshot.documents.count) doc(s) for \(dayId), returning \(ranked.count)")
        if snapshot.documents.isEmpty {
            print("[DailyLeaderboard] ⚠️ empty — no public entries written under dailyTrends/\(dayId)/users yet")
        }

        return ranked
    }

    /// The signed-in user's own Today standing, even when they're outside the
    /// fetched top slice — used by the challenge card to compute their gap to #1.
    /// dailyTrends docs are readable by any signed-in user, so this is allowed.
    static func fetchMyEntry(uid: String) async -> WeeklyLeaderboardEntry? {
        let dayId = DayIdentifier.current
        guard
            let doc = try? await Firestore.firestore()
                .collection("dailyTrends").document(dayId)
                .collection("users").document(uid).getDocument(),
            doc.exists
        else { return nil }
        return entry(from: doc)
    }

    /// Builds an entry from a daily doc's raw data. Manual (not Codable) because a
    /// daily doc shouldn't carry the weekly-only `totalWeeklyRating` just to decode.
    private static func entry(from doc: DocumentSnapshot) -> WeeklyLeaderboardEntry {
        let data = doc.data() ?? [:]
        return WeeklyLeaderboardEntry(
            id: doc.documentID,
            displayName: data["displayName"] as? String,
            photoURL: data["photoURL"] as? String,
            totalWeeklyRating: 0, // unused for daily
            outfitCount: data["outfitCount"] as? Int ?? 0,
            bestScore: data["bestScore"] as? Double ?? 0,
            isPublic: data["isPublic"] as? Bool ?? false,
            lastUploadAt: (data["lastUploadAt"] as? Timestamp)?.dateValue(),
            averageScoreToday: data["averageScoreToday"] as? Double,
            timeReachedHighestScoreToday: (data["timeReachedHighestScoreToday"] as? Timestamp)?.dateValue()
        )
    }
}
