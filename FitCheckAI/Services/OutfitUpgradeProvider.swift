import Foundation
import FirebaseAuth

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

// MARK: - Gemini Provider (server-backed)
//
// Builds the outfit-EDIT prompt on-device, then calls the `generateGeminiUpgrade`
// Cloud Function which holds the Gemini API key server-side and reads the user's
// original photo from Storage (the same source the OpenAI preview uses). The two
// carousel slides differ purely by their prompt (subtle upgrade vs. full restyle +
// styling bias). Returns image bytes in memory so the carousel + history
// persistence keep working unchanged.
//
// SECURITY: the Gemini key no longer ships in the app — see `generate-gemini-upgrade.ts`.
struct GeminiOutfitUpgradeProvider: OutfitUpgradeProvider {
    let kind: UpgradeProviderKind
    /// A subtle alternate-styling nudge so this slot's look differs from the other.
    var variationBias: String
    /// When true, this slot REIMAGINES the whole outfit (a bold restyle into a fresh
    /// cohesive look) instead of only applying the targeted analysis changes. The two
    /// carousel slides differ clearly this way: one a subtle upgrade, one a full
    /// restyle. Person, pose, mirror, and background are preserved in both modes.
    var fullRestyle: Bool = false

    // MARK: Slot factories — the two looks shown side by side.

    /// Slot A — SUBTLE, targeted upgrade: applies only the analysis's suggested
    /// changes with warm, earthy styling.
    static func styleA(variationBias: String? = nil) -> GeminiOutfitUpgradeProvider {
        GeminiOutfitUpgradeProvider(
            kind: .styleA,
            variationBias: variationBias ?? "For this variation, make a subtle, targeted upgrade — lean toward warm, earthy tones with brown suede footwear and a subtle layered accent. Keep every change minimal and realistic.",
            fullRestyle: false
        )
    }

    /// Slot B — FULL restyle: reimagines the whole outfit into a fresh, more elevated
    /// cohesive look using the analysis as inspiration.
    static func styleB(variationBias: String? = nil) -> GeminiOutfitUpgradeProvider {
        GeminiOutfitUpgradeProvider(
            kind: .styleB,
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

        // The backend reads the original photo from Storage by fit-check id, so the
        // client only needs the id + the (client-built) edit prompt.
        guard !request.fitCheckID.isEmpty else {
            print("\(tag) ❌ no fitCheckID — cannot request a server-side edit")
            throw OutfitUpgradeError.noSourceImage
        }

        let prompt = GeminiOutfitUpgradeProvider.buildEditPrompt(
            changeLines: request.changeLines,
            bestOneChange: request.bestOneChange,
            variationBias: variationBias,
            fullRestyle: fullRestyle
        )

        print("\(tag) ▶️ start — mode=server-image-edit fitCheckID=\(request.fitCheckID) " +
              "changeLines=\(request.changeLines.count) promptLen=\(prompt.count) " +
              "includesPreserveDirective=\(prompt.contains("preserve the original composition"))")

        // Authenticate the call — the Cloud Function holds the Gemini key.
        guard let firebaseUser = Auth.auth().currentUser else {
            print("\(tag) ❌ not signed in — cannot call the upgrade function")
            throw OutfitUpgradeError.http(status: 401, body: "not signed in")
        }
        let token = try await firebaseUser.getIDToken()

        var req = URLRequest(url: URL(string: Config.API.generateGeminiUpgrade)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // Fail-fast: don't let a slow generation hold up the carousel. The other
        // slide still appears; this one shows Retry.
        req.timeoutInterval = Config.Gemini.requestTimeout
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "fit_check_id": request.fitCheckID,
            "prompt": prompt,
            // Slot identity lets the backend pick a dedicated Gemini API key per
            // slot, so the two carousel images generate through different keys.
            "slot": kind.rawValue,
        ])

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
            print("\(tag) ❌ HTTP \(status): \(bodyStr.prefix(300))")
            throw OutfitUpgradeError.http(status: status, body: bodyStr)
        }

        let decoded: GeminiUpgradeResponse
        do {
            decoded = try JSONDecoder().decode(GeminiUpgradeResponse.self, from: data)
        } catch {
            print("\(tag) ❌ decode failed: \(error). Body: \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
            throw OutfitUpgradeError.decode("\(error)")
        }

        guard let imageData = Data(base64Encoded: decoded.image_base64), !imageData.isEmpty else {
            print("\(tag) ❌ empty/invalid image in response")
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

// MARK: - Backend response

/// Response from the `generateGeminiUpgrade` Cloud Function — a base64-encoded image.
private struct GeminiUpgradeResponse: Decodable {
    let image_base64: String
}

// MARK: - Helpers

private extension String {
    /// Safe prefix that returns a `String` (not `Substring`).
    func prefixString(_ maxLength: Int) -> String { String(prefix(maxLength)) }
}
