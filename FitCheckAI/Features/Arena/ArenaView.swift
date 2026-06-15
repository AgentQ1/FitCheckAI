import SwiftUI

// MARK: - View Model

@MainActor
final class ArenaViewModel: ObservableObject {
    @Published var tab: ArenaTab = .today
    @Published var finalists: [ArenaFinalist] = []
    @Published var isLoading = true
    @Published var errorMessage: String?
    /// nil = all styles. Filters the loaded finalists client-side.
    @Published var styleFilter: String?
    /// Subtle, auto-dismissing toast for a failed background vote.
    @Published var toast: String?

    private let service = ArenaService()

    var filtered: [ArenaFinalist] {
        // Hide fits from users this person has blocked (Apple UGC guideline 1.2).
        let visible = finalists.filter { !BlockedUsers.shared.contains($0.ownerUid) }
        guard let s = styleFilter else { return visible }
        return visible.filter { $0.styleGoal == s }
    }
    var featured: ArenaFinalist? { filtered.first }
    var trailing: [ArenaFinalist] { Array(filtered.dropFirst()) }
    var availableStyles: [String] {
        Array(Set(finalists.compactMap { $0.styleGoal?.isEmpty == false ? $0.styleGoal : nil })).sorted()
    }
    var isEmpty: Bool { !isLoading && filtered.isEmpty }

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            finalists = try await service.fetchFinalists(tab: tab)
            prefetch()
        } catch {
            errorMessage = (error as? ArenaError)?.errorDescription ?? "Couldn't load the Arena."
        }
        isLoading = false
    }

    func select(_ newTab: ArenaTab) {
        guard newTab != tab else { return }
        tab = newTab
        styleFilter = nil
        Task { await load() }
    }

    private func prefetch() {
        for f in finalists.prefix(6) {
            guard let url = URL(string: f.imageUrl) else { continue }
            Task.detached(priority: .utility) { _ = await OutfitImageLoader.load(.remote(url)) }
        }
    }

    /// Optimistically marks a fit Hot, then confirms with the backend. Reverts on
    /// failure. Reconciles the count from the authoritative server reply.
    func vote(_ finalist: ArenaFinalist) {
        guard let idx = finalists.firstIndex(where: { $0.fitId == finalist.fitId }) else { return }
        guard !finalists[idx].hasVoted, !finalists[idx].isOwner else { return }
        finalists[idx].hasVoted = true
        finalists[idx].hotFitCount += 1
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        let fitID = finalist.fitId
        Task {
            do {
                let resp = try await service.voteHotFit(fitID: fitID)
                if let i = finalists.firstIndex(where: { $0.fitId == fitID }) {
                    finalists[i].hotFitCount = resp.hotFitCount
                    finalists[i].hasVoted = true
                }
            } catch {
                if let i = finalists.firstIndex(where: { $0.fitId == fitID }) {
                    finalists[i].hasVoted = false
                    finalists[i].hotFitCount = max(0, finalists[i].hotFitCount - 1)
                }
                showToast((error as? ArenaError)?.errorDescription ?? "Couldn't submit your vote.")
            }
        }
    }

    /// Reflects an updated finalist back from the detail page (vote / comment count).
    func apply(_ updated: ArenaFinalist) {
        if let i = finalists.firstIndex(where: { $0.fitId == updated.fitId }) {
            finalists[i] = updated
        }
    }

    private func showToast(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if toast == message { toast = nil }
        }
    }
}

// MARK: - Arena View (the public Top 3 board)

struct ArenaView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = ArenaViewModel()
    @State private var detailFinalist: ArenaFinalist?
    @State private var commentFor: ArenaFinalist?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.fcBackground.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header
                        filterRow

                        if vm.isLoading {
                            loadingState
                        } else if vm.isEmpty {
                            emptyState
                        } else {
                            if let featured = vm.featured {
                                featuredCard(featured)
                            }
                            if !vm.trailing.isEmpty {
                                trendingSection
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 120)
                }

                if let toast = vm.toast {
                    VStack {
                        Spacer()
                        Text(toast)
                            .font(.fcCaption).foregroundColor(.white)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(.black.opacity(0.8), in: Capsule())
                            .padding(.bottom, 130)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .navigationDestination(item: $detailFinalist) { finalist in
                ArenaPostDetailView(finalist: finalist, tab: vm.tab) { updated in
                    vm.apply(updated)
                }
                .environmentObject(appState)
            }
        }
        .animation(.spring(response: 0.3), value: vm.toast)
        .task { if vm.finalists.isEmpty { await vm.load() } }
        .sheet(item: $commentFor) { finalist in
            ArenaCommentSheet(finalist: finalist) { updated in
                vm.apply(updated)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Arena")
                .font(.system(size: 34, weight: .bold))
                .foregroundColor(.fcTextPrimary)
            Text("\(vm.tab == .week ? "This week's" : "Today's") top fits, voted by the community")
                .font(.fcBody)
                .foregroundColor(.fcTextSecondary)
        }
    }

    // MARK: Filter row — Today / Week / Style

    private var filterRow: some View {
        HStack(spacing: 10) {
            filterPill(title: "Today", icon: "calendar", active: vm.tab == .today) { vm.select(.today) }
            filterPill(title: "Week", icon: nil, active: vm.tab == .week) { vm.select(.week) }
            styleMenu
            Spacer(minLength: 0)
        }
    }

    private func filterPill(title: String, icon: String?, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 13, weight: .semibold)) }
                Text(title).font(.fcBodyBold)
            }
            .foregroundColor(active ? .white : .fcTextPrimary)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(active ? Color.fcAccent : Color.fcSurface, in: Capsule())
            .overlay(Capsule().stroke(Color.fcTextSecondary.opacity(active ? 0 : 0.25), lineWidth: 1))
        }
        .buttonStyle(HapticButtonStyle(style: .light))
    }

    private var styleMenu: some View {
        Menu {
            Button("All Styles") { vm.styleFilter = nil }
            ForEach(vm.availableStyles, id: \.self) { style in
                Button(style.capitalized) { vm.styleFilter = style }
            }
        } label: {
            HStack(spacing: 6) {
                Text(vm.styleFilter?.capitalized ?? "Style").font(.fcBodyBold)
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
            }
            .foregroundColor(.fcTextPrimary)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(Color.fcSurface, in: Capsule())
            .overlay(Capsule().stroke(Color.fcTextSecondary.opacity(0.25), lineWidth: 1))
        }
        .disabled(vm.availableStyles.isEmpty)
    }

    // MARK: Featured #1 card

    private func featuredCard(_ f: ArenaFinalist) -> some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                PortraitOutfitImage(source: URL(string: f.imageUrl).map { .remote($0) })
                    .frame(height: 420)
                    .frame(maxWidth: .infinity)
                    .clipped()

                // Top badges
                VStack {
                    HStack(alignment: .top) {
                        rankBadge(topLabel: vm.tab == .week ? "Top Fit This Week" : "Top Fit Today")
                        Spacer()
                        aiPill(f.aiScore)
                    }
                    Spacer()
                    HStack {
                        nameChip(f.displayName, photoURL: f.ownerPhotoUrl)
                        Spacer()
                    }
                }
                .padding(14)
            }
            .frame(height: 420)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .onTapGesture { detailFinalist = f }

            // Actions + stats footer
            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    hotFitButton(f, large: true)
                    commentButton(f, large: true)
                }
                HStack(spacing: 20) {
                    statLabel(icon: "flame.fill", text: "\(f.hotFitCount) Hot Fits")
                    statLabel(icon: "bubble.left", text: "\(f.commentCount) comments")
                    Spacer()
                }
            }
            .padding(16)
        }
        .background(Color.fcSurface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Color.fcShadow, radius: 14, x: 0, y: 8)
    }

    private func rankBadge(topLabel: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "crown.fill").font(.system(size: 13)).foregroundColor(.fcGold)
            Text("#1").font(.system(size: 14, weight: .heavy))
                .foregroundColor(.fcTextPrimary)
            Text(topLabel).font(.system(size: 13, weight: .semibold))
                .foregroundColor(.fcTextPrimary)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().fill(Color.white.opacity(0.55)).blendMode(.overlay))
    }

    private func aiPill(_ score: Double?) -> some View {
        Text(score.map { String(format: "AI %.1f", $0) } ?? "AI —")
            .font(.system(size: 14, weight: .bold))
            .foregroundColor(.fcTextPrimary)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
    }

    private func nameChip(_ name: String, photoURL: String?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "tag.fill").font(.system(size: 12)).foregroundColor(.fcAccent)
            Text(name).font(.system(size: 14, weight: .bold)).foregroundColor(.fcTextPrimary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func statLabel(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 13)).foregroundColor(.fcTextSecondary)
            Text(text).font(.fcCaption).foregroundColor(.fcTextSecondary)
        }
    }

    // MARK: Trending (#2, #3) section

    private var trendingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Trending Fits")
                .font(.fcHeading)
                .foregroundColor(.fcTextPrimary)
            ForEach(vm.trailing) { f in
                trendingRow(f)
            }
        }
    }

    private func trendingRow(_ f: ArenaFinalist) -> some View {
        HStack(spacing: 12) {
            SmartOutfitImageView(source: URL(string: f.imageUrl).map { .remote($0) } ?? .remote(URL(string: "about:blank")!))
                .frame(width: 78, height: 100)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture { detailFinalist = f }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(f.displayName).font(.fcBodyBold).foregroundColor(.fcTextPrimary)
                    if let s = f.aiScore {
                        Text(String(format: "AI %.1f", s))
                            .font(.system(size: 11, weight: .semibold)).foregroundColor(.fcTextSecondary)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.fcSurface2, in: Capsule())
                    }
                }
                statLabel(icon: "flame.fill", text: "\(f.hotFitCount) Hot Fits")
                statLabel(icon: "bubble.left", text: "\(f.commentCount) comments")
            }
            Spacer(minLength: 0)

            VStack(spacing: 8) {
                hotFitButton(f, large: false)
                commentButton(f, large: false)
            }
        }
        .padding(12)
        .background(Color.fcSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Color.fcShadow, radius: 8, x: 0, y: 3)
        .contentShape(Rectangle())
        .onTapGesture { detailFinalist = f }
    }

    // MARK: Shared action buttons

    private func hotFitButton(_ f: ArenaFinalist, large: Bool) -> some View {
        Button { vm.vote(f) } label: {
            HStack(spacing: 6) {
                Image(systemName: "flame.fill").font(.system(size: large ? 15 : 12, weight: .bold))
                Text(f.isOwner ? "Your Fit" : (f.hasVoted ? "Hot Fit" : "Hot Fit"))
                    .font(large ? .fcBodyBold : .system(size: 12, weight: .bold))
            }
            .foregroundColor(f.hasVoted || f.isOwner ? .fcAccent : .white)
            .frame(maxWidth: large ? .infinity : nil)
            .padding(.horizontal, large ? 0 : 14)
            .padding(.vertical, large ? 14 : 8)
            .frame(minWidth: large ? nil : 110)
            .background(
                (f.hasVoted || f.isOwner ? Color.fcSurface2 : Color.fcAccent),
                in: Capsule()
            )
            .overlay(Capsule().stroke(Color.fcAccent.opacity(f.hasVoted || f.isOwner ? 0.4 : 0), lineWidth: 1))
        }
        .buttonStyle(HapticButtonStyle(style: .medium))
        .disabled(f.isOwner || f.hasVoted)
    }

    private func commentButton(_ f: ArenaFinalist, large: Bool) -> some View {
        Button { commentFor = f } label: {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left").font(.system(size: large ? 15 : 12, weight: .bold))
                Text("Comment").font(large ? .fcBodyBold : .system(size: 12, weight: .bold))
            }
            .foregroundColor(.fcTextPrimary)
            .frame(maxWidth: large ? .infinity : nil)
            .padding(.horizontal, large ? 0 : 14)
            .padding(.vertical, large ? 14 : 8)
            .frame(minWidth: large ? nil : 110)
            .background(Color.fcSurface, in: Capsule())
            .overlay(Capsule().stroke(Color.fcTextSecondary.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(HapticButtonStyle(style: .light))
    }

    // MARK: Loading / empty

    private var loadingState: some View {
        VStack { Spacer(minLength: 120); ProgressView().tint(.fcAccent).scaleEffect(1.2); Spacer() }
            .frame(maxWidth: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "flame")
                .font(.system(size: 52)).foregroundColor(.fcAccent)
            Text(vm.tab == .week ? "No weekly finalists yet" : "No finalists yet today")
                .font(.fcTitle).foregroundColor(.fcTextPrimary)
            Text(vm.tab == .week
                 ? "Check your fit and compete for the weekly Top 3."
                 : "Check a fit and it enters the Arena automatically.")
                .font(.fcBody).foregroundColor(.fcTextSecondary)
                .multilineTextAlignment(.center)

            if let err = vm.errorMessage {
                Text(err).font(.fcCaption).foregroundColor(.fcError)
            }

            Button {
                appState.showCheckFlow = true
            } label: {
                Label("Check today's fit", systemImage: "camera.fill")
                    .font(.fcBodyBold).foregroundColor(.white)
                    .padding(.horizontal, 22).padding(.vertical, 14)
                    .background(Color.fcAccent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(HapticButtonStyle(style: .medium))
            .padding(.top, 4)

            Button("Refresh") { Task { await vm.load() } }
                .font(.fcBodyBold).foregroundColor(.fcAccent)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
        .padding(.horizontal, 16)
    }
}
