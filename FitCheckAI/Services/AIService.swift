import Foundation
import UIKit
import FirebaseAuth
import FirebaseStorage

// MARK: - AI Errors
enum AIError: LocalizedError {
    case noOutfitDetected
    case poorPhotoQuality
    case rateLimitExceeded(resetAt: Date?)
    /// A guest used their one free fit check — the caller should show the sign-in gate.
    case guestLimitReached
    case serviceUnavailable
    case parseError
    case networkError
    case unauthorized
    case unknown(Int)

    var errorDescription: String? {
        switch self {
        case .noOutfitDetected:
            return "No outfit detected. Try a full-body photo with clear lighting."
        case .poorPhotoQuality:
            return "The photo is too dark or blurry. Try in better lighting."
        case .rateLimitExceeded:
            return "3 free checks used today. Upgrade for unlimited."
        case .guestLimitReached:
            return "You've used your free guest Fit Check. Sign in to keep checking fits."
        case .serviceUnavailable:
            return "AI is temporarily busy. Your check wasn't used. Try again in a moment."
        case .parseError:
            return "Something went wrong reading the AI response. Try again."
        case .networkError:
            return "Connection issue. Check your internet and try again."
        case .unauthorized:
            return "We couldn't verify your account for this request. Please try again — if it keeps happening, sign out and back in."
        case .unknown(let code):
            return "Something went wrong (error \(code))."
        }
    }
}

// MARK: - AI Service
// Sendable: this type holds no mutable state (all methods, no stored properties),
// so it's safe to share across the concurrent OutfitUpgrade provider tasks.
final class AIService: Sendable {

    // MARK: - Upload
    func requestUploadSlot(fileName: String, fileSizeBytes: Int, styleGoal: StyleGoal) async throws -> UploadOutfitResponse {
        let body: [String: Any] = [
            "file_name": fileName,
            "file_size_bytes": fileSizeBytes,
            "mime_type": "image/jpeg",
            "style_goal": styleGoal.rawValue
        ]
        return try await post(url: Config.API.uploadOutfit, body: body)
    }

    func uploadImage(_ image: UIImage, toStoragePath storagePath: String) async throws {
        guard let jpeg = image.jpegData(compressionQuality: StorageService.defaultJPEGQuality) else {
            print("[AIService] ⚠️ JPEG encoding failed for upload")
            throw AIError.networkError
        }
        try await uploadImageData(jpeg, toStoragePath: storagePath)
    }

    /// Upload PRE-ENCODED JPEG bytes. Preferred over `uploadImage(_:)` when the caller
    /// already has the Data — it avoids a second JPEG encode of the same image (the
    /// check flow previously encoded once to measure size and again to upload).
    func uploadImageData(_ jpeg: Data, toStoragePath storagePath: String) async throws {
        print("[AIService] Uploading \(jpeg.count) bytes to \(storagePath)")

        // Pre-warm the Firebase Auth token so the Storage SDK has a fresh credential
        // before the rules check. Avoids an intermittent permission-denied race.
        _ = try? await Auth.auth().currentUser?.getIDToken(forcingRefresh: false)

        let ref = Storage.storage().reference().child(storagePath)
        let metadata = StorageMetadata()
        metadata.contentType = "image/jpeg"
        do {
            _ = try await ref.putDataAsync(jpeg, metadata: metadata)
        } catch {
            // Surface the underlying Storage error so it isn't masked as "session expired".
            print("[AIService] ⚠️ Storage upload failed at \(storagePath): \(error.localizedDescription)")
            throw AIError.networkError
        }
    }

    // MARK: - Analyze
    func analyzeOutfit(fitCheckID: String, styleGoal: StyleGoal) async throws -> OutfitAnalysis {
        let body: [String: Any] = [
            "fit_check_id": fitCheckID,
            "style_goal": styleGoal.rawValue
        ]
        return try await post(url: Config.API.analyzeOutfit, body: body)
    }

    // MARK: - Save
    func saveLook(fitCheckID: String, generatedLookID: String? = nil, tags: [String] = []) async throws {
        let body: [String: Any] = [
            "fit_check_id": fitCheckID,
            "generated_look_id": generatedLookID as Any,
            "tags": tags
        ]
        let _: EmptyResponse = try await post(url: Config.API.saveLook, body: body)
    }

    func deleteOutfit(fitCheckID: String) async throws {
        let token = try await getAuthToken()
        guard let url = URL(string: "\(Config.API.deleteOutfit)/\(fitCheckID)") else { throw AIError.networkError }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AIError.networkError }
    }

    // MARK: - Rate Outfit
    func rateOutfit(body: [String: Any]) async throws {
        let token = try await getAuthToken()
        guard let endpoint = URL(string: Config.API.rateOutfit) else { throw AIError.networkError }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // Validate EVERY non-2xx response, not only 401 — otherwise a 403/429/500
        // looked like success and the rating was silently dropped.
        guard (200..<300).contains(status) else {
            let bodyPreview = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            print("[AIService] ⚠️ rateOutfit HTTP \(status): \(bodyPreview)")
            if status == 401 { throw AIError.unauthorized }
            if status == 429 { throw AIError.rateLimitExceeded(resetAt: nil) }
            throw AIError.unknown(status)
        }
    }

    // MARK: - Private Helpers
    private func getAuthToken(forcingRefresh: Bool = false) async throws -> String {
        guard let user = Auth.auth().currentUser else {
            throw AIError.unauthorized
        }
        do {
            return try await user.getIDToken(forcingRefresh: forcingRefresh)
        } catch {
            // One retry with forced refresh on token error.
            if !forcingRefresh {
                return try await user.getIDToken(forcingRefresh: true)
            }
            print("[AIService] ⚠️ getIDToken failed after force-refresh: \(error.localizedDescription)")
            throw AIError.unauthorized
        }
    }

    private func post<T: Decodable>(url: String, body: [String: Any]) async throws -> T {
        let token = try await getAuthToken()
        guard let endpoint = URL(string: url) else {
            print("[AIService] ⚠️ invalid endpoint URL: \(url)")
            throw AIError.networkError
        }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // analyzeOutfit (GPT-4o) can take up to ~50–90s. Its server timeout is 120s,
        // so the client must wait at least that long or it will time out first and
        // surface a fake "unauthorized / network" error.
        let isLongRunning = url.contains("/analyzeOutfit")
        req.timeoutInterval = isLongRunning ? 120 : 30
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // On 401, force-refresh the token once and retry
        if status == 401 {
            print("[AIService] 401 received — force-refreshing token and retrying \(url)")
            let freshToken = try await getAuthToken(forcingRefresh: true)
            req.setValue("Bearer \(freshToken)", forHTTPHeaderField: "Authorization")
            let (data2, response2) = try await URLSession.shared.data(for: req)
            return try handleResponse(data: data2, response: response2)
        }
        return try handleResponse(data: data, response: response)
    }

    private func handleResponse<T: Decodable>(data: Data, response: URLResponse) throws -> T {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200, 202:
            // NOTE: do NOT set .convertFromSnakeCase here. Every response model
            // declares explicit snake_case CodingKeys (e.g. fit_check_id), and
            // the strategy would rewrite the JSON keys to camelCase first, so
            // those raw values would never match. Result: keyNotFound on every
            // response.
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            do {
                return try decoder.decode(T.self, from: data)
            } catch {
                let bodyPreview = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
                print("[AIService] ⚠️ JSON decode error: \(error). Body: \(bodyPreview)")
                throw AIError.parseError
            }
        case 401:
            throw AIError.unauthorized
        case 422:
            if let errResp = try? JSONDecoder().decode(APIErrorResponse.self, from: data) {
                switch errResp.error {
                case "no_outfit_detected":  throw AIError.noOutfitDetected
                case "poor_photo_quality":  throw AIError.poorPhotoQuality
                default:                    throw AIError.unknown(status)
                }
            }
            throw AIError.noOutfitDetected
        case 429:
            // A guest hitting their one-check limit gets a distinct code so the caller
            // can present the sign-in gate instead of the generic "upgrade" message.
            if let errResp = try? JSONDecoder().decode(APIErrorResponse.self, from: data),
               errResp.error == "guest_limit_reached" {
                throw AIError.guestLimitReached
            }
            throw AIError.rateLimitExceeded(resetAt: nil)
        case 503: throw AIError.serviceUnavailable
        default:
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            let backendMsg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            print("[AIService] ⚠️ Unexpected HTTP \(status): \(backendMsg ?? bodyStr.prefix(200).description)")
            throw AIError.unknown(status)
        }
    }
}

private struct APIErrorResponse: Codable {
    let error: String
    let message: String?
}

private struct EmptyResponse: Codable {}
