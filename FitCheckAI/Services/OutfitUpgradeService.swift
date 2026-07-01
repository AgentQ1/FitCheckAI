import Foundation
import SwiftUI

// MARK: - Outfit Upgrade Coordinator
//
// Launches every provider in parallel and exposes results to SwiftUI in COMPLETION
// ORDER: whoever finishes first becomes the first carousel slide (shown
// immediately), and the slower one is a swipeable slide that shows a loading tile
// while it's still generating. Also owns reroll (regenerate) / session-caching.
//
// Both slots run on-device through Gemini — each with its own API key + styling
// bias so the two looks differ. A user-triggered reroll/retry rebuilds the same
// slot (keeping its key) with a fresh bias, re-keyed to the slot it replaces.

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

    // MARK: Persistence (Firestore upgrade history)
    //
    // When a uid is supplied, each NEW successful result is persisted under
    // users/{uid}/fit_checks/{analysisId}/generatedUpgrades and the analysis's upgrade
    // history is pruned to the cap. Set once per `start`; nil disables persistence.
    private var persistUID: String?
    private var persistSourceImageURL: String?
    private var persistEnabled: Bool { persistUID != nil }
    /// Result ids already persisted this session — guards against double writes when
    /// the same result is re-applied (e.g. phase recompute).
    private var persistedResultIDs: Set<UUID> = []

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
    /// no-op unless `forceRegenerate` is set. The source photo isn't passed in — the
    /// backend reads the user's original image from Storage by `fitCheckID`.
    func start(fitCheckID: String,
               changeLines: [String],
               bestOneChange: String,
               themeTitle: String?,
               providers: [any OutfitUpgradeProvider],
               forceRegenerate: Bool = false,
               persistUID: String? = nil,
               sourceImageURL: String? = nil) {

        let tag = "[OutfitUpgrade]"

        // Persistence context applies for this run (and any rerolls it spawns).
        self.persistUID = persistUID
        self.persistSourceImageURL = sourceImageURL

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

        print("\(tag) ▶️ generation STARTED — fitCheckID=\(fitCheckID) providers=[\(providers.map { $0.kind.rawValue }.joined(separator: ", "))]")

        let request = OutfitUpgradeRequest(
            fitCheckID: fitCheckID,
            changeLines: changeLines,
            bestOneChange: bestOneChange,
            themeTitle: themeTitle
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
        persistedResultIDs = []
        phase = .loading

        runTask = Task { [weak self, request, providers] in
            await self?.runGroup(providers: providers, request: request, fitCheckID: fitCheckID)
        }
    }

    /// Derives the change lines + the two Gemini slots from an analysis and starts
    /// (or resumes) generation. Idempotent per `analysis.id`, so the scan flow can
    /// PRE-WARM this the instant `analyzeOutfit` returns — overlapping the ~11s
    /// generation with the result screen + the time the user spends reading their
    /// score — and ResultView can call it again on appear as a safe no-op. The
    /// carousel then shows whatever the background run has already produced instead
    /// of starting from zero. Both call sites go through here so the change-line
    /// extraction and provider set stay in one place.
    func startForAnalysis(_ analysis: OutfitAnalysis,
                          persistUID: String?,
                          forceRegenerate: Bool = false) {
        let changeLines: [String] = (analysis.improvedLooks.first?.changes ?? []).compactMap { c in
            let item = c.item.trimmingCharacters(in: .whitespaces)
            let change = c.change.trimmingCharacters(in: .whitespaces)
            guard !change.isEmpty else { return nil }
            return item.isEmpty ? "- \(change)" : "- \(item): \(change)"
        }
        let providers: [any OutfitUpgradeProvider] = [
            GeminiOutfitUpgradeProvider.styleA(),
            GeminiOutfitUpgradeProvider.styleB()
        ]
        start(fitCheckID: analysis.id,
              changeLines: changeLines,
              bestOneChange: analysis.bestOneChange,
              themeTitle: analysis.improvedLooks.first?.theme,
              providers: providers,
              forceRegenerate: forceRegenerate,
              persistUID: persistUID)
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
        persistIfNeeded(result)
    }

    /// Persists a NEW successful result to the analysis's upgrade history, then prunes
    /// to the cap. No-op when persistence is disabled or the result was already saved.
    private func persistIfNeeded(_ result: OutfitUpgradeResult) {
        guard persistEnabled,
              result.status == .success,
              let uid = persistUID,
              let image = result.image,
              let analysisId = runningFitCheckID,
              !persistedResultIDs.contains(result.id) else { return }
        persistedResultIDs.insert(result.id)

        let provider = result.provider
        let promptUsed = result.promptUsed
        let generationTime = result.generationTime
        let variationIndex = launchedProviders.firstIndex(of: provider) ?? 0
        let sourceImageURL = persistSourceImageURL

        Task {
            await UpgradeHistoryService.saveGeneratedUpgrade(
                uid: uid,
                analysisId: analysisId,
                provider: provider,
                image: image,
                promptUsed: promptUsed,
                generationTime: generationTime,
                variationIndex: variationIndex,
                sourceImageURL: sourceImageURL
            )
            await UpgradeHistoryService.cleanupGeneratedUpgrades(uid: uid, analysisId: analysisId)
        }
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
        // Rebuild THIS slot's provider so the reroll keeps the slot's own API key,
        // just with a fresh styling bias for a visibly different result.
        let engine = GeminiOutfitUpgradeProvider.forSlot(kind, variationBias: nextRerollBias())
        print("[OutfitUpgrade] 🔄 reroll slot=\(kind.rawValue)")

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
            "Lean toward warm, earthy tones with brown suede footwear and a layered accent; keep it realistic.",
            "Lean toward clean monochrome styling with white leather sneakers and a single understated silver accent.",
            "Lean toward a smart-casual lift: a fitted neutral knit or overshirt with refined accessories.",
            "Lean toward relaxed streetwear refinement with tonal layers and clean sneakers; keep it realistic."
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
