import Foundation
import UIKit
import FirebaseAuth
import FirebaseStorage

// MARK: - AI Errors
enum AIError: LocalizedError {
    case noOutfitDetected
    case poorPhotoQuality
    case rateLimitExceeded(resetAt: Date?)
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
        case .serviceUnavailable:
            return "AI is temporarily busy. Your check wasn't used. Try again in a moment."
        case .parseError:
            return "Something went wrong reading the AI response. Try again."
        case .networkError:
            return "Connection issue. Check your internet and try again."
        case .unauthorized:
            return "Session expired. Please sign in again."
        case .unknown(let code):
            return "Something went wrong (error \(code))."
        }
    }
}

// MARK: - AI Service
final class AIService {

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
        guard let jpeg = image.jpegData(compressionQuality: 0.85) else {
            throw AIError.networkError
        }
        let ref = Storage.storage().reference().child(storagePath)
        let metadata = StorageMetadata()
        metadata.contentType = "image/jpeg"
        _ = try await ref.putDataAsync(jpeg, metadata: metadata)
    }

    // MARK: - Analyze
    func analyzeOutfit(fitCheckID: String, styleGoal: StyleGoal) async throws -> OutfitAnalysis {
        let body: [String: Any] = [
            "fit_check_id": fitCheckID,
            "style_goal": styleGoal.rawValue
        ]
        return try await post(url: Config.API.analyzeOutfit, body: body)
    }

    // MARK: - Generate Looks
    func requestLookGeneration(analysisID: String) async throws -> GenerationJobResponse {
        let body = ["analysis_id": analysisID]
        return try await post(url: Config.API.generateLooks, body: body)
    }

    func pollGenerationStatus(jobID: String) async throws -> GenerationStatusResponse {
        return try await get(url: "\(Config.API.generationStatus)/\(jobID)")
    }

    // MARK: - Save / Like
    func saveLook(fitCheckID: String, generatedLookID: String? = nil, tags: [String] = []) async throws {
        let body: [String: Any] = [
            "fit_check_id": fitCheckID,
            "generated_look_id": generatedLookID as Any,
            "tags": tags
        ]
        let _: EmptyResponse = try await post(url: Config.API.saveLook, body: body)
    }

    func likeLook(fitCheckID: String, liked: Bool) async throws {
        let body: [String: Any] = ["fit_check_id": fitCheckID, "liked": liked]
        let _: EmptyResponse = try await post(url: Config.API.likeLook, body: body)
    }

    func deleteOutfit(fitCheckID: String) async throws {
        let token = try await getAuthToken()
        let url = URL(string: "\(Config.API.deleteOutfit)/\(fitCheckID)")!
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AIError.networkError }
    }

    // MARK: - Rate Outfit
    func rateOutfit(body: [String: Any]) async throws {
        let token = try await getAuthToken()
        var req = URLRequest(url: URL(string: Config.API.rateOutfit)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw AIError.unauthorized }
    }

    // MARK: - Private Helpers
    private func getAuthToken() async throws -> String {
        guard let user = Auth.auth().currentUser else { throw AIError.unauthorized }
        return try await user.getIDToken()
    }

    private func post<T: Decodable>(url: String, body: [String: Any]) async throws -> T {
        let token = try await getAuthToken()
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 60
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        return try handleResponse(data: data, response: response)
    }

    private func get<T: Decodable>(url: String) async throws -> T {
        let token = try await getAuthToken()
        var req = URLRequest(url: URL(string: url)!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: req)
        return try handleResponse(data: data, response: response)
    }

    private func handleResponse<T: Decodable>(data: Data, response: URLResponse) throws -> T {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200, 202:
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            decoder.dateDecodingStrategy = .iso8601
            do {
                return try decoder.decode(T.self, from: data)
            } catch {
                throw AIError.parseError
            }
        case 401: throw AIError.unauthorized
        case 422:
            if let errResp = try? JSONDecoder().decode(APIErrorResponse.self, from: data) {
                switch errResp.error {
                case "no_outfit_detected":  throw AIError.noOutfitDetected
                case "poor_photo_quality":  throw AIError.poorPhotoQuality
                default:                    throw AIError.unknown(status)
                }
            }
            throw AIError.noOutfitDetected
        case 429: throw AIError.rateLimitExceeded(resetAt: nil)
        case 503: throw AIError.serviceUnavailable
        default:  throw AIError.unknown(status)
        }
    }
}

private struct APIErrorResponse: Codable {
    let error: String
    let message: String?
}

private struct EmptyResponse: Codable {}
