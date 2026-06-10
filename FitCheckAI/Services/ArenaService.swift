import Foundation
import FirebaseAuth

// MARK: - Arena Errors

enum ArenaError: LocalizedError {
    case unauthorized
    case dailyCap(String)
    case cannotRateOwn
    case notLive
    case notAnalyzed
    case moderation(String)
    case network
    case server(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:        return "We couldn't verify your account. Please try again."
        case .dailyCap(let msg):   return msg
        case .cannotRateOwn:       return "You can't rate your own fit."
        case .notLive:             return "This fit is no longer available."
        case .notAnalyzed:         return "Analyze this fit before sharing it to the Arena."
        case .moderation(let msg): return msg
        case .network:             return "Connection issue. Check your internet and try again."
        case .server(let msg):     return msg
        }
    }
}

// MARK: - Response models
//
// NOTE: the backend returns snake_case and the decoder does NOT use
// .convertFromSnakeCase (see AIService), so every key is mapped explicitly.

struct EnterArenaResponse: Decodable {
    let fitId: String
    let status: String
    let imageUrl: String?
    let alreadyPosted: Bool?
    enum CodingKeys: String, CodingKey {
        case fitId = "fit_id", status
        case imageUrl = "image_url"
        case alreadyPosted = "already_posted"
    }
}

struct ArenaQueueItem: Decodable, Identifiable, Equatable {
    let fitId: String
    let imageUrl: String
    let styleGoal: String?
    let aiScore: Double?
    var id: String { fitId }
    enum CodingKeys: String, CodingKey {
        case fitId = "fit_id"
        case imageUrl = "image_url"
        case styleGoal = "style_goal"
        case aiScore = "ai_score"
    }
}

private struct ArenaQueueResponse: Decodable {
    let items: [ArenaQueueItem]
    let count: Int
}

struct SubmitRatingResponse: Decodable {
    let counted: Bool
    let unlockedAny: Bool
    enum CodingKeys: String, CodingKey {
        case counted
        case unlockedAny = "unlocked_any"
    }
}

/// The dual-gated reveal payload. `state` selects which fields are populated.
struct ArenaResult: Decodable {
    enum State: String { case lockedReciprocity = "locked_reciprocity", lockedVotes = "locked_votes", revealed }

    let stateRaw: String
    let remaining: Int?
    // locked_reciprocity
    let ratingsGiven: Int?
    let ratingsRequired: Int?
    // locked_votes
    let voteCount: Int?
    let votesRequired: Int?
    // revealed
    let approvalPercent: Int?
    let upvotes: Int?
    let aiScore: Double?
    let percentile: Int?

    var state: State { State(rawValue: stateRaw) ?? .lockedReciprocity }

    enum CodingKeys: String, CodingKey {
        case stateRaw = "state"
        case remaining, upvotes, percentile
        case ratingsGiven = "ratings_given"
        case ratingsRequired = "ratings_required"
        case voteCount = "vote_count"
        case votesRequired = "votes_required"
        case approvalPercent = "approval_percent"
        case aiScore = "ai_score"
    }
}

private struct ArenaErrorBody: Decodable {
    let error: String?
    let message: String?
}

// MARK: - Arena Service

final class ArenaService: Sendable {

    /// Opt a fit check into the public Arena. May throw `.dailyCap` / `.moderation`.
    func enterArena(fitCheckID: String) async throws -> EnterArenaResponse {
        try await post(url: Config.API.enterArena, body: ["fit_check_id": fitCheckID])
    }

    /// Fetch a batch of other users' live fits to rate. `blockedUIDs` is reserved for
    /// a future block feature — pass [] until block data exists.
    func fetchQueue(blockedUIDs: [String] = []) async throws -> [ArenaQueueItem] {
        let resp: ArenaQueueResponse = try await post(url: Config.API.getArenaQueue, body: ["blocked_uids": blockedUIDs])
        return resp.items
    }

    /// Submit one binary vote. Idempotent server-side (re-voting returns counted=false).
    @discardableResult
    func submitRating(fitID: String, liked: Bool) async throws -> SubmitRatingResponse {
        try await post(url: Config.API.submitPeerRating, body: ["fit_id": fitID, "liked": liked])
    }

    /// Fetch the dual-gated Human Fit Score reveal for one of the user's own fits.
    func myResults(fitID: String) async throws -> ArenaResult {
        try await post(url: Config.API.getMyArenaResults, body: ["fit_id": fitID])
    }

    /// Report a fit. Hides it for this user; global removal needs a threshold.
    func reportFit(fitID: String, reason: String? = nil) async throws {
        var body: [String: Any] = ["fit_id": fitID]
        if let reason { body["reason"] = reason }
        let _: EmptyArenaResponse = try await post(url: Config.API.reportFit, body: body)
    }

    // MARK: - Private

    private func getAuthToken(forcingRefresh: Bool = false) async throws -> String {
        guard let user = Auth.auth().currentUser else { throw ArenaError.unauthorized }
        do {
            return try await user.getIDToken(forcingRefresh: forcingRefresh)
        } catch {
            if !forcingRefresh { return try await user.getIDToken(forcingRefresh: true) }
            throw ArenaError.unauthorized
        }
    }

    private func post<T: Decodable>(url: String, body: [String: Any]) async throws -> T {
        let token = try await getAuthToken()
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // enterArena downloads + moderates an image; give it room.
        req.timeoutInterval = url.contains("/enterArena") ? 60 : 30
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw ArenaError.network
        }
        var status = (response as? HTTPURLResponse)?.statusCode ?? 0

        // Refresh-and-retry once on 401.
        var payload = data
        if status == 401 {
            let fresh = try await getAuthToken(forcingRefresh: true)
            req.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
            guard let (data2, response2) = try? await URLSession.shared.data(for: req) else { throw ArenaError.network }
            payload = data2
            status = (response2 as? HTTPURLResponse)?.statusCode ?? 0
        }

        switch status {
        case 200, 201:
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            do { return try decoder.decode(T.self, from: payload) }
            catch {
                print("[ArenaService] decode error: \(error) — body: \(String(data: payload, encoding: .utf8)?.prefix(200) ?? "")")
                throw ArenaError.server("Unexpected response. Try again.")
            }
        case 401:
            throw ArenaError.unauthorized
        default:
            let err = try? JSONDecoder().decode(ArenaErrorBody.self, from: payload)
            let msg = err?.message ?? "Something went wrong. Try again."
            switch (status, err?.error) {
            case (429, _):                    throw ArenaError.dailyCap(msg)
            case (403, "cannot_rate_own"):    throw ArenaError.cannotRateOwn
            case (409, "not_live"):           throw ArenaError.notLive
            case (409, "not_analyzed"):       throw ArenaError.notAnalyzed
            case (422, "moderation_failed"):  throw ArenaError.moderation(msg)
            default:                          throw ArenaError.server(msg)
            }
        }
    }
}

private struct EmptyArenaResponse: Decodable {}
