import Foundation
import UIKit

// MARK: - Provider Abstraction
//
// One protocol, two slots. Both carousel slides are produced on-device by Gemini —
// each slot uses its OWN Gemini API key and its OWN styling bias so the two looks
// come out different, letting the user compare and pick what suits them. The
// coordinator (`OutfitUpgradeService`) runs the two slots in parallel.

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

// MARK: - Gemini Provider (on-device, direct REST)
//
// Calls Gemini AI Studio's image model directly from the app using the user's
// resized photo as the edit source. This is a TRUE image edit (input image +
// instruction → edited image), so the prompt carries strong preservation
// directives and a per-slot variation bias so the two carousel slides differ
// (e.g. brown suede vs. white sneakers) while both stay faithful to the original
// photo. Returns image bytes in memory — no extra upload round trip, fast.
//
// Each slot is configured with its own `apiKey` (so the two looks generate
// independently) and `kind` (its stable carousel slot).
//
// SECURITY NOTE: the API keys ship in the client (see Config.Gemini). That is
// convenient but extractable from the binary — restrict the keys in Google Cloud
// Console (app/bundle + API restrictions) or move these calls behind a Firebase
// function before a wide release.
struct GeminiOutfitUpgradeProvider: OutfitUpgradeProvider {
    let kind: UpgradeProviderKind
    /// Which Gemini API key this slot uses — distinct per slot so the two looks
    /// are generated independently.
    let apiKey: String
    /// A subtle alternate-styling nudge so this slot's look differs from the other.
    var variationBias: String
    /// When true, this slot REIMAGINES the whole outfit (a bold restyle into a fresh
    /// cohesive look) instead of only applying the targeted analysis changes. The two
    /// carousel slides differ clearly this way: one a subtle upgrade, one a full
    /// restyle. Person, pose, mirror, and background are preserved in both modes.
    var fullRestyle: Bool = false

    // MARK: Slot factories — the two looks shown side by side.

    /// Slot A — SUBTLE, targeted upgrade: applies only the analysis's suggested
    /// changes with warm, earthy styling. Uses the SECOND key (`apiKeyB`).
    static func styleA(variationBias: String? = nil) -> GeminiOutfitUpgradeProvider {
        GeminiOutfitUpgradeProvider(
            kind: .styleA,
            apiKey: Config.Gemini.apiKeyB,
            variationBias: variationBias ?? "For this variation, make a subtle, targeted upgrade — lean toward warm, earthy tones with brown suede footwear and a subtle layered accent. Keep every change minimal and realistic.",
            fullRestyle: false
        )
    }

    /// Slot B — FULL restyle: reimagines the whole outfit into a fresh, more elevated
    /// cohesive look using the analysis as inspiration. Uses the PRIMARY key (`apiKey`).
    static func styleB(variationBias: String? = nil) -> GeminiOutfitUpgradeProvider {
        GeminiOutfitUpgradeProvider(
            kind: .styleB,
            apiKey: Config.Gemini.apiKey,
            variationBias: variationBias ?? "For this restyle, reimagine the whole outfit into a fresh, noticeably more elevated and cohesive look — clean monochrome styling with crisp white leather sneakers and a single understated accent. Keep it realistic.",
            fullRestyle: true
        )
    }

    /// Rebuilds the same-slot provider for a reroll (keeps the slot's key, swaps in
    /// a fresh styling bias so a regenerate looks different).
    static func forSlot(_ kind: UpgradeProviderKind, variationBias: String) -> GeminiOutfitUpgradeProvider {
        switch kind {
        case .styleA: return styleA(variationBias: variationBias)
        case .styleB: return styleB(variationBias: variationBias)
        }
    }

    func generateUpgrade(_ request: OutfitUpgradeRequest) async throws -> OutfitUpgradeResult {
        let tag = "[GeminiProvider:\(kind.rawValue)]"
        let started = Date()

        guard let jpeg = request.sourceImageData, !jpeg.isEmpty else {
            print("\(tag) ❌ no source image data — cannot run an on-device edit")
            throw OutfitUpgradeError.noSourceImage
        }

        let prompt = GeminiOutfitUpgradeProvider.buildEditPrompt(
            changeLines: request.changeLines,
            bestOneChange: request.bestOneChange,
            variationBias: variationBias,
            fullRestyle: fullRestyle
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

        var req = URLRequest(url: Config.Gemini.generateContentURL(apiKey: apiKey))
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
        return OutfitUpgradeResult(provider: kind,
                                   image: .data(imageData),
                                   promptUsed: prompt,
                                   generationTime: elapsed,
                                   status: .success)
    }

    // MARK: Prompt

    /// Builds the on-device edit prompt. Two modes:
    /// - `fullRestyle == false` (subtle): change ONLY the targeted analysis items.
    /// - `fullRestyle == true` (bold): reimagine the WHOLE outfit into a fresh look,
    ///   using the analysis items as inspiration.
    /// Both modes keep the same person, pose, mirror, and background (the phrase
    /// "preserve the original composition" is kept verbatim so logging can confirm
    /// the directive is present).
    static func buildEditPrompt(changeLines: [String], bestOneChange: String, variationBias: String, fullRestyle: Bool = false) -> String {
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

        // Preservation directive — identical in both modes (only the OUTFIT scope differs).
        let preserve = "You MUST preserve the original composition exactly: keep the same real person, the same face and identity, the same body shape and proportions, the same pose, the same mirror-selfie framing, the same phone in hand, the same mirror and its frame, the same room and background, the same lighting, and the same camera angle. Keep the full body visible from head to shoes — do not crop the head, top, legs, or shoes, and do not zoom in or reframe."

        if fullRestyle {
            return [
                "Realistically RESTYLE the outfit in THIS photo into a fresh, noticeably more elevated and cohesive look. This is a photo retouch of the supplied image, not a new image.",
                "",
                preserve,
                "",
                "Reimagine the whole outfit — you may change the top, any layers, and the footwear (and the pants if it improves the look) into a stylish, cohesive new outfit, blending everything naturally into the existing lighting, shadows, and photo grain so it still looks like a real casual mirror selfie. Use these analysis suggestions as inspiration for the new look:",
                changesBlock + keyChange,
                "",
                variationBias,
                "",
                "Do NOT do any of the following: do not generate a new or different person; do not create a studio, showroom, or plain background; do not produce a catalog-, e-commerce-, or model-style photo; do not change the background, room, floor, wall, or mirror; do not change the pose or framing; do not edit the face or body. The result must look like the SAME real person in the SAME room and mirror selfie, just wearing a completely restyled, better outfit."
            ].joined(separator: "\n")
        }

        return [
            "Realistically edit THIS photo to upgrade only the outfit. This is a photo retouch of the supplied image, not a new image.",
            "",
            preserve,
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
