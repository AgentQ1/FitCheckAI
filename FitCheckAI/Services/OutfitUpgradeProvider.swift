import Foundation
import UIKit

// MARK: - Provider Abstraction
//
// One protocol, two engines. The coordinator (`OutfitUpgradeService`) treats both
// the server-side OpenAI path and the on-device Gemini path identically and runs
// them in parallel. To add a third engine later, conform a new type here.

/// Produces a single realistic outfit-EDIT preview from the user's photo + the
/// analysis advice. Implementations must keep the same person/pose/background and
/// only upgrade the outfit — never a brand-new model/catalog image.
protocol OutfitUpgradeProvider: Sendable {
    var kind: UpgradeProviderKind { get }
    /// Generates one upgraded preview. Throws on failure so the coordinator can
    /// mark just this provider's slide as failed (the other still shows).
    func generateUpgrade(_ request: OutfitUpgradeRequest) async throws -> OutfitUpgradeResult
}

// MARK: - Errors

enum OutfitUpgradeError: LocalizedError {
    case noSourceImage
    case emptyResponse
    case http(status: Int, body: String)
    case decode(String)
    case encodeImage

    var errorDescription: String? {
        switch self {
        case .noSourceImage:           return "No source photo available to edit."
        case .emptyResponse:           return "The provider returned no image."
        case .http(let status, _):     return "Image service error (HTTP \(status))."
        case .decode(let why):         return "Couldn't read the image response (\(why))."
        case .encodeImage:             return "Couldn't prepare the source image."
        }
    }
}

// MARK: - OpenAI Provider (server-side wrapper)
//
// OpenAI image editing stays on the backend: the Firebase function holds the
// OpenAI key and runs the proven `gpt-image-1` image-to-image edit (downloads the
// original full-res photo from Storage, preserves identity/pose/framing, uploads
// the result, returns a tokenized URL). This Swift type is a thin wrapper so it
// slots into the same parallel pipeline as Gemini.
struct OpenAIOutfitUpgradeProvider: OutfitUpgradeProvider {
    let kind: UpgradeProviderKind = .openAI
    let aiService: AIService

    func generateUpgrade(_ request: OutfitUpgradeRequest) async throws -> OutfitUpgradeResult {
        let tag = "[OpenAIProvider]"
        let started = Date()

        // Fast path: a preview URL we already know about (from the analyze response
        // or a prior view) — skip the round trip entirely.
        if let precomputed = request.precomputedOpenAIURL,
           !precomputed.isEmpty,
           let url = URL(string: precomputed) {
            print("\(tag) ⚡️ using precomputed/cached preview URL — skipping server call")
            return OutfitUpgradeResult(provider: .openAI,
                                       image: .remote(url),
                                       promptUsed: "(server gpt-image-1 edit — cached)",
                                       generationTime: Date().timeIntervalSince(started),
                                       status: .success)
        }

        print("\(tag) ▶️ requesting server edit — mode=image-to-image-edit model=gpt-image-1 fitCheckID=\(request.fitCheckID) sourceAttached=server-side(original photo)")
        let resp = try await aiService.generateSingleOutfitUpgradePreview(fitCheckID: request.fitCheckID)
        let elapsed = Date().timeIntervalSince(started)

        guard !resp.imageURL.isEmpty, let url = URL(string: resp.imageURL) else {
            print("\(tag) ❌ empty/invalid image_url after \(String(format: "%.1f", elapsed))s (status=\(resp.status ?? "nil"))")
            throw OutfitUpgradeError.emptyResponse
        }

        print("\(tag) ✅ done in \(String(format: "%.1f", elapsed))s — url=\(resp.imageURL.prefix(80))…")
        return OutfitUpgradeResult(provider: .openAI,
                                   image: .remote(url),
                                   promptUsed: "(server gpt-image-1 edit)",
                                   generationTime: elapsed,
                                   status: .success)
    }
}

// MARK: - Gemini Provider (on-device, direct REST)
//
// Calls Gemini AI Studio's image model directly from the app using the user's
// resized photo as the edit source. This is a TRUE image edit (input image +
// instruction → edited image), so the prompt mirrors the server's strong
// preservation directives and adds a subtle variation bias so the two carousel
// slides differ (e.g. brown suede vs. white sneakers) while both stay faithful to
// the original photo. Returns image bytes in memory — no extra upload round trip,
// which keeps this path fast.
//
// SECURITY NOTE: the API key ships in the client (see Config.Gemini). That is
// convenient but extractable from the binary — restrict the key in Google Cloud
// Console (app/bundle + API restrictions) or move this call behind a Firebase
// function before a wide release.
struct GeminiOutfitUpgradeProvider: OutfitUpgradeProvider {
    let kind: UpgradeProviderKind = .gemini

    /// A subtle alternate-styling nudge so Gemini's slide differs from OpenAI's
    /// while staying a realistic edit of the same outfit.
    var variationBias: String = "For this variation, lean toward warm, earthy accents — prefer brown suede footwear over white sneakers and a slightly different but equally subtle accessory choice. Keep every change minimal and realistic."

    func generateUpgrade(_ request: OutfitUpgradeRequest) async throws -> OutfitUpgradeResult {
        let tag = "[GeminiProvider]"
        let started = Date()

        guard let jpeg = request.sourceImageData, !jpeg.isEmpty else {
            print("\(tag) ❌ no source image data — cannot run an on-device edit")
            throw OutfitUpgradeError.noSourceImage
        }

        let prompt = GeminiOutfitUpgradeProvider.buildEditPrompt(
            changeLines: request.changeLines,
            bestOneChange: request.bestOneChange,
            variationBias: variationBias
        )

        print("\(tag) ▶️ start — mode=image-to-image-edit model=\(Config.Gemini.model) " +
              "sourceAttached=true sourceBytes=\(jpeg.count) sourceDims=\(request.sourcePixelWidth)x\(request.sourcePixelHeight) " +
              "changeLines=\(request.changeLines.count) promptLen=\(prompt.count) " +
              "includesPreserveDirective=\(prompt.contains("preserve the original composition"))")
        print("\(tag) 📝 exact edit prompt: \(prompt)")

        // Build the multipart-free JSON body: [text instruction] + [inline image].
        let base64 = jpeg.base64EncodedString()
        let body: [String: Any] = [
            "contents": [[
                "parts": [
                    ["text": prompt],
                    ["inlineData": ["mimeType": "image/jpeg", "data": base64]]
                ]
            ]],
            // responseModalities tells the model to return image bytes. ["IMAGE"]
            // is correct for gemini-2.5-flash-image; if you swap to an older
            // preview model that requires text too, use ["TEXT","IMAGE"].
            "generationConfig": ["responseModalities": Config.Gemini.responseModalities]
        ]

        var req = URLRequest(url: Config.Gemini.generateContentURL())
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Fail-fast: don't let a slow provider hold up the carousel. The other
        // slide still appears; this one shows Retry.
        req.timeoutInterval = Config.Gemini.requestTimeout
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            print("\(tag) ❌ network error after \(String(format: "%.1f", Date().timeIntervalSince(started)))s: \(error.localizedDescription)")
            throw error
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            // Surface the precise Gemini error (bad key, unsupported field, safety
            // block, wrong model name) so it's obvious in the logs what to fix.
            print("\(tag) ❌ HTTP \(status): \(bodyStr.prefix(400))")
            throw OutfitUpgradeError.http(status: status, body: bodyStr)
        }

        // Decode and pull the first inline image part out of the candidates.
        let decoded: GeminiGenerateResponse
        do {
            decoded = try JSONDecoder().decode(GeminiGenerateResponse.self, from: data)
        } catch {
            print("\(tag) ❌ decode failed: \(error). Body: \(String(data: data, encoding: .utf8)?.prefix(300) ?? "")")
            throw OutfitUpgradeError.decode("\(error)")
        }

        guard let b64Image = decoded.firstInlineImageBase64,
              let imageData = Data(base64Encoded: b64Image), !imageData.isEmpty else {
            let textPart = decoded.firstText ?? ""
            print("\(tag) ❌ no inline image in response. modelText=\(textPart.prefix(160))")
            throw OutfitUpgradeError.emptyResponse
        }

        let elapsed = Date().timeIntervalSince(started)
        print("\(tag) ✅ done in \(String(format: "%.1f", elapsed))s — imageBytes=\(imageData.count)")
        return OutfitUpgradeResult(provider: .gemini,
                                   image: .data(imageData),
                                   promptUsed: prompt,
                                   generationTime: elapsed,
                                   status: .success)
    }

    // MARK: Prompt

    /// Mirrors the server's edit prompt: strong preservation directives first, then
    /// only the targeted outfit changes, then explicit negative constraints, plus a
    /// subtle variation bias. The phrase "preserve the original composition" is kept
    /// verbatim so logging can confirm the directive is present.
    static func buildEditPrompt(changeLines: [String], bestOneChange: String, variationBias: String) -> String {
        func sanitize(_ s: String) -> String {
            s.replacingOccurrences(of: "nude", with: "", options: .caseInsensitive)
             .replacingOccurrences(of: "naked", with: "", options: .caseInsensitive)
             .replacingOccurrences(of: "explicit", with: "", options: .caseInsensitive)
        }

        let changesBlock: String = {
            if changeLines.isEmpty {
                return "- Subtly upgrade the top layer, the vest, and the footwear so the outfit looks more styled."
            }
            return changeLines.map(sanitize).joined(separator: "\n")
        }().prefixString(1200)

        let keyChange = bestOneChange.isEmpty ? "" : "\nHighest-impact change: \(sanitize(bestOneChange).prefixString(200))"

        return [
            "Realistically edit THIS photo to upgrade only the outfit. This is a photo retouch of the supplied image, not a new image.",
            "",
            "You MUST preserve the original composition exactly: keep the same real person, the same face and identity, the same body shape and proportions, the same pose, the same mirror-selfie framing, the same phone in hand, the same mirror and its frame, the same room and background, the same lighting, and the same camera angle. Keep the full body visible from head to shoes — do not crop the head, top, legs, or shoes, and do not zoom in or reframe.",
            "",
            "Only modify the outfit elements listed below, blending them naturally into the existing lighting, shadows, and photo grain so it still looks like a real casual mirror selfie:",
            changesBlock + keyChange,
            "",
            variationBias,
            "",
            "Do NOT do any of the following: do not generate a new or different person; do not create a studio, showroom, or plain background; do not produce a catalog-, e-commerce-, or model-style photo; do not change the background, room, floor, wall, or mirror; do not change the pose or framing; do not over-style or restyle the whole outfit; do not change the pants unless explicitly listed; do not invent a totally different outfit concept; do not edit the face or body. The result must look like the same real uploaded mirror selfie, same room and person, just with the outfit improved."
        ].joined(separator: "\n")
    }
}

// MARK: - Gemini REST response shapes
//
// Gemini's generateContent returns proto-JSON (camelCase): candidates[].content
// .parts[] where an image part carries `inlineData.data` (base64). Error responses
// carry a top-level `error`.
private struct GeminiGenerateResponse: Decodable {
    let candidates: [Candidate]?
    let error: GeminiAPIError?

    struct Candidate: Decodable { let content: Content? }
    struct Content: Decodable { let parts: [Part]? }
    struct Part: Decodable {
        let text: String?
        let inlineData: InlineData?
    }
    struct InlineData: Decodable {
        let mimeType: String?
        let data: String?
    }
    struct GeminiAPIError: Decodable {
        let code: Int?
        let message: String?
        let status: String?
    }

    /// First base64 image found across all candidate parts.
    var firstInlineImageBase64: String? {
        candidates?
            .compactMap { $0.content?.parts }
            .flatMap { $0 }
            .compactMap { $0.inlineData?.data }
            .first
    }

    /// First text part (used only to log why no image came back).
    var firstText: String? {
        candidates?
            .compactMap { $0.content?.parts }
            .flatMap { $0 }
            .compactMap { $0.text }
            .first
    }
}

// MARK: - Helpers

private extension String {
    /// Safe prefix that returns a `String` (not `Substring`).
    func prefixString(_ maxLength: Int) -> String { String(prefix(maxLength)) }
}

extension UIImage {
    /// Downscales so the longest side is at most `maxDimension` (no upscaling) and
    /// returns compressed JPEG bytes. Shrinking the payload before upload is the
    /// single biggest client-side latency win for the on-device Gemini edit.
    func fcResizedForUpload(maxDimension: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxDimension, longest > 0 else { return self }
        let scale = maxDimension / longest
        let newSize = CGSize(width: (size.width * scale).rounded(),
                             height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1 // pixel dimensions == point dimensions, predictable payload
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in draw(in: CGRect(origin: .zero, size: newSize)) }
    }
}
