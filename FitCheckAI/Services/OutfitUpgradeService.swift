import Foundation
import SwiftUI

// MARK: - Outfit Upgrade Coordinator
//
// Launches every provider in parallel and exposes results to SwiftUI in COMPLETION
// ORDER: whoever finishes first becomes the first carousel slide (shown
// immediately), and the slower one is a swipeable slide that shows a loading tile
// while it's still generating. Also owns reroll (regenerate) / session-caching.
//
// IMPORTANT: OpenAI (the server-side gpt-image-1 path) is only ever called during
// the INITIAL generation. Every user-triggered reroll/retry runs through Gemini
// (on-device, fast, no server cost), re-keyed to whichever slot it replaces.

@MainActor
final class OutfitUpgradeService: ObservableObject {

    /// Finished + in-retry results, keyed by provider slot. Providers still in their
    /// first run are not here yet (rendered as loading slides via `launchedProviders`).
    @Published private(set) var results: [OutfitUpgradeResult] = []
    @Published private(set) var phase: Phase = .idle

    /// How many providers were launched this run (so we can tell "still waiting"
    /// from "everything returned").
    private(set) var expectedCount = 0

    /// Providers launched this run, used to render a loading slide for any provider
    /// that hasn't returned yet (so the "other" look is swipeable while generating).
    private(set) var launchedProviders: [UpgradeProviderKind] = []

    /// Once every provider has returned, the slide order is frozen to the
    /// completion order established during loading. This keeps a slide in place when
    /// the user rerolls only it (so it doesn't jump to the back while regenerating).
    private var frozenOrder: [UpgradeProviderKind]?

    /// Rotates the Gemini styling bias so each reroll yields a visibly different look.
    private var rerollCounter = 0

    enum Phase: Equatable {
        case idle
        case loading        // nothing ready yet
        case partial        // ≥1 ready, ≥1 still generating
        case complete       // all returned, ≥1 success
        case allFailed      // all returned, 0 success
    }

    private var runningFitCheckID: String?
    private var runTask: Task<Void, Never>?
    // Held so rerolls can rebuild a request without the view re-supplying it.
    private var lastRequest: OutfitUpgradeRequest?
    private var lastProviders: [any OutfitUpgradeProvider] = []

    deinit { runTask?.cancel() }

    // MARK: Derived state for the carousel

    private var successes: [OutfitUpgradeResult] { results.filter { $0.status == .success } }

    /// True once every launched provider has returned (no more pending) and none is
    /// mid-reroll.
    var allProvidersReturned: Bool {
        results.count >= expectedCount && !results.contains { $0.status == .generating }
    }

    /// Completion-ordered slides used during the initial load: successes first, then
    /// in-flight/pending loading slides, then failures.
    private var dynamicSlides: [OutfitUpgradeResult] {
        let succeeded = results.filter { $0.status == .success }
        let retrying  = results.filter { $0.status == .generating }
        let failed    = results.filter { $0.status == .failed }
        let present   = Set(results.map(\.provider))
        let pending   = launchedProviders
            .filter { !present.contains($0) }
            .map { OutfitUpgradeResult.generating(provider: $0) }
        return succeeded + retrying + pending + failed
    }

    /// Slides for the carousel. Before everything returns we use completion order;
    /// after that the order is frozen so rerolling one slide keeps it in place.
    var slides: [OutfitUpgradeResult] {
        guard let order = frozenOrder else { return dynamicSlides }
        return order.map { kind in
            results.first(where: { $0.provider == kind }) ?? .generating(provider: kind)
        }
    }

    /// Show a single all-failed error tile: everything returned, nothing succeeded.
    var showAllFailedTile: Bool { successes.isEmpty && allProvidersReturned }

    // MARK: Start

    /// Begins generation (or restores cached results) for a fit check. Idempotent:
    /// re-calling for the same fit check (e.g. the view's `.task` firing again) is a
    /// no-op unless `forceRegenerate` is set.
    ///
    /// `sourceImage` is resized + JPEG-compressed ONCE here (latency optimization),
    /// then only the resulting `Data` crosses into the parallel provider tasks.
    func start(fitCheckID: String,
               sourceImage: UIImage?,
               changeLines: [String],
               bestOneChange: String,
               themeTitle: String?,
               precomputedOpenAIURL: String?,
               providers: [any OutfitUpgradeProvider],
               forceRegenerate: Bool = false) {

        let tag = "[OutfitUpgrade]"

        if !forceRegenerate {
            // Already started this fit check in this store instance → leave it be.
            if runningFitCheckID == fitCheckID { return }
            // Restore from this session's cache (survives ResultView re-creation).
            if let cached = OutfitUpgradeCache.shared.results(for: fitCheckID), !cached.isEmpty {
                print("\(tag) ♻️ restored \(cached.count) cached result(s) for fitCheckID=\(fitCheckID)")
                results = cached
                expectedCount = cached.count
                launchedProviders = cached.map { $0.provider }
                frozenOrder = cached.map { $0.provider }   // stable order on re-view
                runningFitCheckID = fitCheckID
                recomputePhase()
                return
            }
        } else {
            OutfitUpgradeCache.shared.clear(fitCheckID: fitCheckID)
        }

        runTask?.cancel()
        runningFitCheckID = fitCheckID

        // ---- Resize + compress the source ONCE, off the providers' hot path. ----
        let originalW = Int(sourceImage?.size.width ?? 0)
        let originalH = Int(sourceImage?.size.height ?? 0)
        let resized = sourceImage?.fcResizedForUpload(maxDimension: Config.Gemini.maxSourceDimension)
        let jpeg = resized?.jpegData(compressionQuality: Config.Gemini.sourceJPEGQuality)
        let resizedW = Int(resized?.size.width ?? 0)
        let resizedH = Int(resized?.size.height ?? 0)

        print("\(tag) ▶️ generation STARTED — fitCheckID=\(fitCheckID) providers=[\(providers.map { $0.kind.rawValue }.joined(separator: ", "))]")
        print("\(tag) 🖼️ source image — original=\(originalW)x\(originalH) resized=\(resizedW)x\(resizedH) jpegBytes=\(jpeg?.count ?? 0) attached=\(jpeg != nil)")

        let request = OutfitUpgradeRequest(
            fitCheckID: fitCheckID,
            sourceImageData: jpeg,
            sourcePixelWidth: resizedW,
            sourcePixelHeight: resizedH,
            changeLines: changeLines,
            bestOneChange: bestOneChange,
            themeTitle: themeTitle,
            precomputedOpenAIURL: precomputedOpenAIURL
        )
        lastRequest = request
        lastProviders = providers

        // Start empty; each provider appends as it finishes (completion order).
        // launchedProviders lets the carousel show a loading slide for ones that
        // haven't returned yet.
        results = []
        expectedCount = providers.count
        launchedProviders = providers.map { $0.kind }
        frozenOrder = nil
        phase = .loading

        runTask = Task { [weak self, request, providers] in
            await self?.runGroup(providers: providers, request: request, fitCheckID: fitCheckID)
        }
    }

    // MARK: Parallel execution (initial load)

    /// Runs all providers concurrently with a TaskGroup and applies each result the
    /// instant it returns — so the first finisher shows immediately and the second
    /// appends without disturbing the user.
    private func runGroup(providers: [any OutfitUpgradeProvider],
                          request: OutfitUpgradeRequest,
                          fitCheckID: String) async {
        await withTaskGroup(of: OutfitUpgradeResult.self) { group in
            for provider in providers {
                group.addTask {
                    let started = Date()
                    do {
                        return try await provider.generateUpgrade(request)
                    } catch {
                        let elapsed = Date().timeIntervalSince(started)
                        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        print("[OutfitUpgrade] ⚠️ provider \(provider.kind.rawValue) FAILED in \(String(format: "%.1f", elapsed))s — \(message)")
                        return .failed(provider: provider.kind, message: message, elapsed: elapsed)
                    }
                }
            }
            for await result in group {
                guard !Task.isCancelled, self.runningFitCheckID == fitCheckID else { continue }
                self.apply(result)
            }
        }

        guard runningFitCheckID == fitCheckID else { return }
        print("[OutfitUpgrade] 🏁 generation COMPLETE — fitCheckID=\(fitCheckID) success=\(successes.count)/\(results.count)")
        cacheIfWorthwhile(fitCheckID: fitCheckID)
    }

    /// Records a finished (or in-reroll) result. New providers are APPENDED in
    /// completion order; a provider already present is replaced in place.
    private func apply(_ result: OutfitUpgradeResult) {
        if let idx = results.firstIndex(where: { $0.provider == result.provider }) {
            results[idx] = result
        } else {
            results.append(result)
        }
        let t = result.generationTime.map { String(format: "%.1fs", $0) } ?? "—"
        print("[OutfitUpgrade] \(result.status == .success ? "✅" : "❌") \(result.provider.rawValue) → \(result.status) (\(t))")
        recomputePhase()
    }

    private func recomputePhase() {
        let anySuccess = !successes.isEmpty
        if !allProvidersReturned {
            phase = anySuccess ? .partial : .loading
        } else {
            phase = anySuccess ? .complete : .allFailed
            // Freeze the display order once, the first time everything has returned.
            if frozenOrder == nil { frozenOrder = dynamicSlides.map { $0.provider } }
        }
    }

    // MARK: Reroll (regenerate) — Gemini only, single slot

    /// Regenerates ONLY the given slot (the slide currently on screen) using Gemini —
    /// the OpenAI server API is never called here. The slot keeps its position
    /// (frozen order) and gets a fresh styling variation each time.
    func reroll(provider kind: UpgradeProviderKind) {
        guard let request = lastRequest, let fitCheckID = runningFitCheckID else { return }
        let engine = GeminiOutfitUpgradeProvider(variationBias: nextRerollBias())
        print("[OutfitUpgrade] 🔄 reroll slot=\(kind.rawValue) via Gemini (OpenAI not called)")

        // Show a loading tile in this slot's existing position.
        if let idx = results.firstIndex(where: { $0.provider == kind }) {
            results[idx] = .generating(provider: kind)
        } else {
            results.append(.generating(provider: kind))
        }
        recomputePhase()

        Task { [weak self] in
            let started = Date()
            var result: OutfitUpgradeResult
            do {
                let g = try await engine.generateUpgrade(request)
                // Re-key the Gemini output to THIS slot so position/identity stay put.
                result = OutfitUpgradeResult(provider: kind,
                                             image: g.image,
                                             promptUsed: g.promptUsed,
                                             generationTime: g.generationTime,
                                             status: .success)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                result = .failed(provider: kind, message: message, elapsed: Date().timeIntervalSince(started))
            }
            guard let self, self.runningFitCheckID == fitCheckID else { return }
            self.apply(result)
            self.cacheIfWorthwhile(fitCheckID: fitCheckID)
        }
    }

    /// Rerolls every slot via Gemini — used by the all-failed retry tile (there is
    /// no single "visible" slide to target in that state).
    func rerollAll() {
        for kind in launchedProviders { reroll(provider: kind) }
    }

    /// Cycles styling biases so repeated rerolls of the same slot look different
    /// while staying realistic edits of the original photo.
    private func nextRerollBias() -> String {
        let biases = [
            "Lean toward warm, earthy tones with brown suede footwear and a subtle accessory; keep every change minimal and realistic.",
            "Lean toward clean monochrome styling with white leather sneakers and a single understated silver accent.",
            "Lean toward a smart-casual lift: a fitted neutral knit or overshirt with refined, minimal accessories.",
            "Lean toward relaxed streetwear refinement with tonal layers and clean sneakers; keep it subtle and realistic."
        ]
        let bias = biases[rerollCounter % biases.count]
        rerollCounter += 1
        return bias
    }

    // MARK: Caching

    private func cacheIfWorthwhile(fitCheckID: String) {
        // Only cache once nothing is still generating and at least one succeeded.
        guard !results.contains(where: { $0.status == .generating }),
              !successes.isEmpty else { return }
        // Cache successes in their displayed (frozen) order so re-view matches.
        let ordered = slides.filter { $0.status == .success }
        OutfitUpgradeCache.shared.store(ordered, for: fitCheckID)
    }
}

// MARK: - Session Cache
//
// In-memory, session-scoped cache keyed by fit check. Survives ResultView being
// re-created (e.g. navigating away and back) so we don't regenerate — but is
// intentionally not persisted to disk: a fresh launch re-derives OpenAI from the
// server cache and regenerates Gemini, which is acceptable.
@MainActor
final class OutfitUpgradeCache {
    static let shared = OutfitUpgradeCache()
    private init() {}

    private var store: [String: [OutfitUpgradeResult]] = [:]

    func results(for fitCheckID: String) -> [OutfitUpgradeResult]? { store[fitCheckID] }

    func store(_ results: [OutfitUpgradeResult], for fitCheckID: String) {
        // Persist only the successful slides; a failed slide should re-attempt on
        // the next visit rather than being remembered as failed.
        let keep = results.filter { $0.status == .success }
        guard !keep.isEmpty else { return }
        store[fitCheckID] = keep
    }

    func clear(fitCheckID: String) { store[fitCheckID] = nil }
}
