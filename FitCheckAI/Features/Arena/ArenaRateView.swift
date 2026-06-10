import SwiftUI
import FirebaseAuth
import FirebaseFirestore

// MARK: - View Model

@MainActor
final class ArenaViewModel: ObservableObject {
    @Published var queue: [ArenaQueueItem] = []
    @Published var isLoading = true
    @Published var errorMessage: String?
    /// Ratings given toward unlocking the user's most recent pending fit (0...required).
    @Published var ratedTowardUnlock = 0
    @Published var didUnlockSomething = false

    let required = Config.Arena.ratingsRequiredToUnlock
    private let service = ArenaService()
    private let db = Firestore.firestore()

    var current: ArenaQueueItem? { queue.first }
    var next: ArenaQueueItem? { queue.count > 1 ? queue[1] : nil }
    var isEmpty: Bool { !isLoading && queue.isEmpty }

    func load() async {
        isLoading = true
        errorMessage = nil
        await refreshUnlockProgress()
        do {
            queue = try await service.fetchQueue()
        } catch {
            errorMessage = (error as? ArenaError)?.errorDescription ?? "Couldn't load the Arena."
        }
        isLoading = false
    }

    /// Vote on the top card, then advance. Optimistically removes the card; a failed
    /// vote re-surfaces an error but we don't re-insert (the next card keeps flow).
    func vote(liked: Bool) async {
        guard let item = queue.first else { return }
        queue.removeFirst()
        // Top up the queue before it runs dry.
        if queue.count <= 2 { Task { await topUp() } }
        do {
            let resp = try await service.submitRating(fitID: item.fitId, liked: liked)
            if resp.counted {
                ratedTowardUnlock = min(required, ratedTowardUnlock + 1)
                if resp.unlockedAny { didUnlockSomething = true }
            }
        } catch {
            errorMessage = (error as? ArenaError)?.errorDescription
        }
    }

    func report(_ item: ArenaQueueItem) async {
        queue.removeAll { $0.fitId == item.fitId }
        if queue.count <= 2 { Task { await topUp() } }
        try? await service.reportFit(fitID: item.fitId)
    }

    private func topUp() async {
        guard let more = try? await service.fetchQueue() else { return }
        let existing = Set(queue.map(\.fitId))
        queue.append(contentsOf: more.filter { !existing.contains($0.fitId) })
    }

    /// Reads the user's most recent still-locked posted fit so the progress bar starts
    /// where the backend left off (per-fit unlock lives in users/{uid}/arenaUnlocks).
    /// Uses a single-field `isUnlocked` filter and picks the newest doc in memory — this
    /// deliberately avoids an `isUnlocked + createdAt` composite index (the per-user
    /// subcollection is tiny, so client-side sort is cheap).
    private func refreshUnlockProgress() async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        do {
            let snap = try await db.collection("users/\(uid)/arenaUnlocks")
                .whereField("isUnlocked", isEqualTo: false)
                .getDocuments()
            let newest = snap.documents.max { a, b in
                let ta = (a.data()["createdAt"] as? Timestamp)?.dateValue() ?? .distantPast
                let tb = (b.data()["createdAt"] as? Timestamp)?.dateValue() ?? .distantPast
                return ta < tb
            }
            if let doc = newest {
                ratedTowardUnlock = min(required, doc.data()["ratingsGivenForThisFit"] as? Int ?? 0)
            }
        } catch {
            // Non-fatal — progress just starts at its current value.
        }
    }
}

// MARK: - Arena Rate View

struct ArenaRateView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = ArenaViewModel()

    // Top-card drag state.
    @State private var drag: CGSize = .zero
    @State private var reportingItem: ArenaQueueItem?

    private let swipeThreshold: CGFloat = 110

    var body: some View {
        ZStack {
            Color.fcBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                progressBar
                    .padding(.horizontal, 24)
                    .padding(.top, 4)

                if vm.isLoading {
                    Spacer(); ProgressView().tint(.fcTextSecondary); Spacer()
                } else if vm.isEmpty {
                    emptyState
                } else {
                    cardArea
                    actionButtons
                        .padding(.bottom, 8)
                    Text("Swipe right to like, left to pass")
                        .font(.fcCaption)
                        .foregroundColor(.fcTextSecondary)
                        .padding(.bottom, 110)
                }
            }
        }
        .task { if vm.queue.isEmpty { await vm.load() } }
        .confirmationDialog("Report this fit?",
                            isPresented: Binding(get: { reportingItem != nil }, set: { if !$0 { reportingItem = nil } }),
                            titleVisibility: .visible) {
            Button("Report", role: .destructive) {
                if let item = reportingItem { Task { await vm.report(item) } }
                reportingItem = nil
            }
            Button("Cancel", role: .cancel) { reportingItem = nil }
        } message: {
            Text("We'll hide it from you. Repeated reports trigger a review.")
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Arena")
                        .font(.fcHeading)
                        .foregroundColor(.fcTextPrimary)
                    Text("Rate the fit — would you wear it?")
                        .font(.fcBody)
                        .foregroundColor(.fcTextSecondary)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
    }

    private var progressBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(0..<vm.required, id: \.self) { i in
                    Capsule()
                        .fill(i < vm.ratedTowardUnlock ? Color.fcAccent : Color.fcTextSecondary.opacity(0.2))
                        .frame(height: 6)
                }
            }
            Text(vm.ratedTowardUnlock >= vm.required
                 ? "Unlocked — your Human Fit Score is on the way"
                 : "\(vm.ratedTowardUnlock)/\(vm.required) rated to unlock your Human Fit Score")
                .font(.fcCaption)
                .foregroundColor(.fcTextSecondary)
        }
    }

    // MARK: Card stack

    private var cardArea: some View {
        ZStack {
            if let next = vm.next {
                card(for: next, isTop: false)
                    .scaleEffect(0.95)
                    .offset(y: 16)
                    .opacity(0.9)
            }
            if let top = vm.current {
                card(for: top, isTop: true)
                    .offset(drag)
                    .rotationEffect(.degrees(Double(drag.width / 22)))
                    .overlay(decisionStamp)
                    .gesture(
                        DragGesture()
                            .onChanged { drag = $0.translation }
                            .onEnded { value in handleDragEnd(value.translation, item: top) }
                    )
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: drag)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func card(for item: ArenaQueueItem, isTop: Bool) -> some View {
        ZStack(alignment: .bottom) {
            SmartOutfitImageView(source: URL(string: item.imageUrl).map { .remote($0) })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))

            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .allowsHitTesting(false)

            VStack(spacing: 2) {
                Text("Would you wear this?")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text("Rate the fit")
                    .font(.fcBody)
                    .foregroundColor(.white.opacity(0.85))
            }
            .padding(.bottom, 22)

            if isTop {
                VStack {
                    HStack {
                        Spacer()
                        Button { reportingItem = item } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(.white.opacity(0.9))
                                .padding(10)
                                .background(.black.opacity(0.25), in: Circle())
                        }
                    }
                    Spacer()
                }
                .padding(14)
            }
        }
        .shadow(color: Color.fcShadow, radius: 16, x: 0, y: 10)
    }

    /// LIKE / PASS stamp that fades in as the card is dragged.
    private var decisionStamp: some View {
        let liking = drag.width > 0
        return Text(liking ? "LIKE" : "PASS")
            .font(.system(size: 30, weight: .heavy, design: .rounded))
            .foregroundColor(liking ? .green : .red)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(liking ? Color.green : Color.red, lineWidth: 4))
            .rotationEffect(.degrees(liking ? -16 : 16))
            .opacity(min(1, Double(abs(drag.width) / swipeThreshold)))
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: liking ? .topLeading : .topTrailing)
            .allowsHitTesting(false)
    }

    private var actionButtons: some View {
        HStack(spacing: 56) {
            circleButton(system: "xmark", tint: .red) { swipe(liked: false) }
            circleButton(system: "heart.fill", tint: .fcAccent) { swipe(liked: true) }
        }
        .padding(.top, 18)
    }

    private func circleButton(system: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(tint)
                .frame(width: 64, height: 64)
                .background(Color.fcSurface, in: Circle())
                .shadow(color: Color.fcShadow, radius: 10, y: 4)
        }
        .buttonStyle(HapticButtonStyle(style: .medium))
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 52))
                .foregroundColor(.fcAccent)
            Text("You're all caught up")
                .font(.fcTitle)
                .foregroundColor(.fcTextPrimary)
            Text("Come back later for more fits to rate.")
                .font(.fcBody)
                .foregroundColor(.fcTextSecondary)
            Button("Refresh") { Task { await vm.load() } }
                .font(.fcBodyBold)
                .foregroundColor(.fcAccent)
                .padding(.top, 4)
            Spacer(); Spacer()
        }
        .padding(.horizontal, 32)
        .multilineTextAlignment(.center)
    }

    // MARK: Interaction

    private func handleDragEnd(_ translation: CGSize, item: ArenaQueueItem) {
        if abs(translation.width) > swipeThreshold {
            swipe(liked: translation.width > 0)
        } else {
            drag = .zero
        }
    }

    private func swipe(liked: Bool) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        // Fling the card off-screen, then commit the vote and reset.
        withAnimation(.easeOut(duration: 0.28)) {
            drag = CGSize(width: liked ? 700 : -700, height: 60)
        }
        Task {
            await vm.vote(liked: liked)
            drag = .zero
        }
    }
}
