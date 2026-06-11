import Foundation
import FirebaseAuth

// MARK: - Arena Errors

enum ArenaError: LocalizedError {
    case unauthorized
    case dailyCap(String)
    case notEligible(String)
    case cannotRateOwn
    case notLive
    case notAnalyzed
    case notInArena
    case moderation(String)
    case network
    case server(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:        return "We couldn't verify your account. Please try again."
        case .dailyCap(let msg):   return msg
        case .notEligible(let msg): return msg
        case .cannotRateOwn:       return "You can't Hot Fit your own post."
        case .notLive:             return "This fit is no longer available."
        case .notAnalyzed:         return "Analyze this fit before posting it to the Arena."
        case .notInArena:          return "This fit hasn't been posted to the Arena yet."
        case .moderation(let msg): return msg
        case .network:             return "Connection issue. Check your internet and try again."
        case .server(let msg):     return msg
        }
    }
}

// MARK: - Response models
//
// NOTE: the backend returns snake_case and the decoder does NOT use
// .convertFromSnakeCase, so every key is mapped explicitly.

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

/// One Top 3 finalist on the Today / Week board.
struct ArenaFinalist: Decodable, Identifiable, Equatable, Hashable {
    let fitId: String
    let imageUrl: String
    let ownerUid: String
    let ownerDisplayName: String?
    let ownerPhotoUrl: String?
    let aiScore: Double?
    var hotFitCount: Int
    var commentCount: Int
    let rank: Int
    let styleGoal: String?
    var hasVoted: Bool
    let isOwner: Bool

    var id: String { fitId }

    /// Display name fallback so a finalist card always shows a person, never blank.
    var displayName: String {
        if let n = ownerDisplayName, !n.isEmpty { return n }
        return "Someone"
    }

    enum CodingKeys: String, CodingKey {
        case fitId = "fit_id"
        case imageUrl = "image_url"
        case ownerUid = "owner_uid"
        case ownerDisplayName = "owner_display_name"
        case ownerPhotoUrl = "owner_photo_url"
        case aiScore = "ai_score"
        case hotFitCount = "hot_fit_count"
        case commentCount = "comment_count"
        case rank
        case styleGoal = "style_goal"
        case hasVoted = "has_voted"
        case isOwner = "is_owner"
    }
}

private struct ArenaFinalistsResponse: Decodable {
    let tab: String
    let count: Int
    let items: [ArenaFinalist]
}

struct VoteHotFitResponse: Decodable {
    let counted: Bool
    let hotFitCount: Int
    let reason: String?
    enum CodingKeys: String, CodingKey {
        case counted, reason
        case hotFitCount = "hot_fit_count"
    }
}

struct ArenaComment: Decodable, Identifiable, Equatable {
    let id: String
    let commenterName: String
    let text: String
    let tags: [String]
    let createdAt: String?
    enum CodingKeys: String, CodingKey {
        case id, text, tags
        case commenterName = "commenter_name"
        case createdAt = "created_at"
    }
}

private struct ArenaCommentsResponse: Decodable {
    let count: Int
    let items: [ArenaComment]
}

private struct PostCommentResponse: Decodable {
    let ok: Bool
    let comment: ArenaComment
}

private struct ArenaErrorBody: Decodable {
    let error: String?
    let message: String?
}

// MARK: - Arena Service

final class ArenaService: Sendable {

    /// Post a fit (score >= 6.5) into the public Arena. May throw `.notEligible` /
    /// `.dailyCap` / `.moderation`.
    func enterArena(fitCheckID: String) async throws -> EnterArenaResponse {
        try await post(url: Config.API.enterArena, body: ["fit_check_id": fitCheckID])
    }

    /// Fetch the current Top 3 finalists for "today" or "week".
    func fetchFinalists(tab: ArenaTab) async throws -> [ArenaFinalist] {
        let resp: ArenaFinalistsResponse = try await post(url: Config.API.getArenaFinalists, body: ["tab": tab.rawValue])
        return resp.items
    }

    /// Cast one "Hot Fit 🔥" vote. Idempotent server-side (re-voting returns counted=false).
    @discardableResult
    func voteHotFit(fitID: String) async throws -> VoteHotFitResponse {
        try await post(url: Config.API.voteHotFit, body: ["fit_id": fitID])
    }

    /// Post an outfit-focused comment (quick tags and/or ≤120-char note).
    @discardableResult
    func postComment(fitID: String, text: String, tags: [String]) async throws -> ArenaComment {
        let resp: PostCommentResponse = try await post(
            url: Config.API.postArenaComment,
            body: ["fit_id": fitID, "text": text, "tags": tags]
        )
        return resp.comment
    }

    /// Fetch the live comments for one finalist (newest first).
    func fetchComments(fitID: String) async throws -> [ArenaComment] {
        let resp: ArenaCommentsResponse = try await post(url: Config.API.getArenaComments, body: ["fit_id": fitID])
        return resp.items
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
            case (422, "not_eligible"):       throw ArenaError.notEligible(msg)
            case (403, "cannot_rate_own"):    throw ArenaError.cannotRateOwn
            case (404, "not_found"):          throw ArenaError.notInArena
            case (409, "not_live"):           throw ArenaError.notLive
            case (409, "not_analyzed"):       throw ArenaError.notAnalyzed
            case (422, "moderation_failed"):  throw ArenaError.moderation(msg)
            default:                          throw ArenaError.server(msg)
            }
        }
    }
}

/// Which Top 3 board to load.
enum ArenaTab: String, CaseIterable {
    case today, week
}

private struct EmptyArenaResponse: Decodable {}
