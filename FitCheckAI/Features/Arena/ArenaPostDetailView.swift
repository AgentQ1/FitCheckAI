import SwiftUI

// MARK: - Finalist detail page

/// Full-screen detail for one Top 3 finalist: the full outfit photo, rank badge,
/// user name, AI score, Hot Fit + Comment actions, the live comment list, and a
/// report option. Vote/comment changes are pushed back to the board via `onChange`.
struct ArenaPostDetailView: View {
    @State var finalist: ArenaFinalist
    let tab: ArenaTab
    let onChange: (ArenaFinalist) -> Void

    @EnvironmentObject var appState: AppState
    @State private var comments: [ArenaComment] = []
    @State private var isLoadingComments = true
    @State private var showCommentSheet = false
    @State private var showFullImage = false
    @State private var showReport = false
    @State private var toast: String?

    private let service = ArenaService()

    var body: some View {
        ZStack {
            Color.fcBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    imageHeader
                    identityRow
                    actionRow
                    statsRow
                    Divider().background(Color.fcTextSecondary.opacity(0.2))
                    commentsSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 60)
            }

            if let toast {
                VStack { Spacer()
                    Text(toast).font(.fcCaption).foregroundColor(.white)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.black.opacity(0.8), in: Capsule())
                        .padding(.bottom, 40)
                }.transition(.opacity)
            }
        }
        .navigationTitle("Top Fit")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.fcBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Report this fit", role: .destructive) { showReport = true }
                } label: {
                    Image(systemName: "ellipsis.circle").foregroundColor(.fcTextPrimary)
                }
            }
        }
        .onAppear { appState.hideTabBar = true }
        .onDisappear { appState.hideTabBar = false }
        .task { await loadComments() }
        .animation(.spring(response: 0.3), value: toast)
        .fullScreenCover(isPresented: $showFullImage) {
            if let url = URL(string: finalist.imageUrl) {
                OutfitImageViewer(source: .remote(url)) { showFullImage = false }
            }
        }
        .sheet(isPresented: $showCommentSheet) {
            ArenaCommentSheet(finalist: finalist) { updated in
                finalist = updated
                onChange(updated)
                Task { await loadComments() }
            }
        }
        .confirmationDialog("Report this fit?", isPresented: $showReport, titleVisibility: .visible) {
            Button("Report", role: .destructive) { Task { await report() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("We'll hide it from you. Repeated reports trigger a review.")
        }
    }

    // MARK: Image + badges

    private var imageHeader: some View {
        ZStack(alignment: .topLeading) {
            PortraitOutfitImage(source: URL(string: finalist.imageUrl).map { .remote($0) })
                .frame(height: 440)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .onTapGesture { showFullImage = true }

            VStack {
                HStack(alignment: .top) {
                    rankBadge
                    Spacer()
                    Text(finalist.aiScore.map { String(format: "AI %.1f", $0) } ?? "AI —")
                        .font(.system(size: 14, weight: .bold)).foregroundColor(.fcTextPrimary)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                Spacer()
            }
            .padding(14)
        }
        .frame(height: 440)
    }

    private var rankBadge: some View {
        HStack(spacing: 6) {
            if finalist.rank == 1 {
                Image(systemName: "crown.fill").font(.system(size: 13)).foregroundColor(.fcGold)
            }
            Text("#\(finalist.rank)").font(.system(size: 14, weight: .heavy)).foregroundColor(.fcTextPrimary)
            Text(tab == .week ? "This Week" : "Today").font(.system(size: 13, weight: .semibold)).foregroundColor(.fcTextPrimary)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var identityRow: some View {
        HStack(spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                Text(finalist.displayName).font(.fcHeading).foregroundColor(.fcTextPrimary)
                if let style = finalist.styleGoal, !style.isEmpty {
                    Text(style.capitalized).font(.fcCaption).foregroundColor(.fcTextSecondary)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var avatar: some View {
        if let s = finalist.ownerPhotoUrl, let url = URL(string: s) {
            AsyncImage(url: url) { phase in
                if case .success(let img) = phase {
                    img.resizable().scaledToFill()
                } else {
                    Color.fcSurface2
                }
            }
            .frame(width: 44, height: 44).clipShape(Circle())
        } else {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 40)).foregroundColor(.fcTextSecondary.opacity(0.5))
        }
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button { vote() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "flame.fill").font(.system(size: 15, weight: .bold))
                    Text(finalist.isOwner ? "Your Fit" : "Hot Fit").font(.fcBodyBold)
                }
                .foregroundColor(finalist.hasVoted || finalist.isOwner ? .fcAccent : .white)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(finalist.hasVoted || finalist.isOwner ? Color.fcSurface2 : Color.fcAccent, in: Capsule())
                .overlay(Capsule().stroke(Color.fcAccent.opacity(finalist.hasVoted || finalist.isOwner ? 0.4 : 0), lineWidth: 1))
            }
            .buttonStyle(HapticButtonStyle(style: .medium))
            .disabled(finalist.isOwner || finalist.hasVoted)

            Button { showCommentSheet = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "bubble.left").font(.system(size: 15, weight: .bold))
                    Text("Comment").font(.fcBodyBold)
                }
                .foregroundColor(.fcTextPrimary)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(Color.fcSurface, in: Capsule())
                .overlay(Capsule().stroke(Color.fcTextSecondary.opacity(0.3), lineWidth: 1))
            }
            .buttonStyle(HapticButtonStyle(style: .light))
        }
    }

    private var statsRow: some View {
        HStack(spacing: 20) {
            HStack(spacing: 6) {
                Image(systemName: "flame.fill").font(.system(size: 14)).foregroundColor(.fcAccent)
                Text("\(finalist.hotFitCount) Hot Fits").font(.fcBody).foregroundColor(.fcTextPrimary)
            }
            HStack(spacing: 6) {
                Image(systemName: "bubble.left").font(.system(size: 14)).foregroundColor(.fcTextSecondary)
                Text("\(finalist.commentCount) comments").font(.fcBody).foregroundColor(.fcTextPrimary)
            }
            Spacer()
        }
    }

    // MARK: Comments

    private var commentsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Comments").font(.fcHeading).foregroundColor(.fcTextPrimary)

            if isLoadingComments {
                HStack { Spacer(); ProgressView().tint(.fcTextSecondary); Spacer() }.padding(.vertical, 12)
            } else if comments.isEmpty {
                Text("No comments yet. Be the first to weigh in on the fit.")
                    .font(.fcBody).foregroundColor(.fcTextSecondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(comments) { c in commentRow(c) }
            }
        }
    }

    private func commentRow(_ c: ArenaComment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(c.commenterName).font(.fcBodyBold).foregroundColor(.fcTextPrimary)
            if !c.tags.isEmpty {
                FlowChips(tags: c.tags)
            }
            if !c.text.isEmpty {
                Text(c.text).font(.fcBody).foregroundColor(.fcTextPrimary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.fcSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: Actions

    private func vote() {
        guard !finalist.hasVoted, !finalist.isOwner else { return }
        finalist.hasVoted = true
        finalist.hotFitCount += 1
        onChange(finalist)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        let id = finalist.fitId
        Task {
            do {
                let resp = try await service.voteHotFit(fitID: id)
                finalist.hotFitCount = resp.hotFitCount
                finalist.hasVoted = true
                onChange(finalist)
            } catch {
                finalist.hasVoted = false
                finalist.hotFitCount = max(0, finalist.hotFitCount - 1)
                onChange(finalist)
                showToast((error as? ArenaError)?.errorDescription ?? "Couldn't submit your vote.")
            }
        }
    }

    private func loadComments() async {
        isLoadingComments = true
        comments = (try? await service.fetchComments(fitID: finalist.fitId)) ?? []
        isLoadingComments = false
    }

    private func report() async {
        try? await service.reportFit(fitID: finalist.fitId)
        showToast("Thanks — we'll review this fit.")
    }

    private func showToast(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if toast == message { toast = nil }
        }
    }
}

// MARK: - Comment bottom sheet

/// "Comment on the fit" — outfit-focused quick chips plus an optional ≤120-char
/// note. Posts via the backend, then reports the bumped comment count back.
struct ArenaCommentSheet: View {
    let finalist: ArenaFinalist
    let onPosted: (ArenaFinalist) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedTags: Set<String> = []
    @State private var text = ""
    @State private var isPosting = false
    @State private var errorMessage: String?

    private let service = ArenaService()
    private let maxLen = Config.Arena.commentMaxLength

    private var canPost: Bool { !selectedTags.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.fcBackground.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Comment on the fit").font(.fcTitle).foregroundColor(.fcTextPrimary)
                            Text("Keep it about the outfit.").font(.fcBody).foregroundColor(.fcTextSecondary)
                        }

                        chipGrid

                        VStack(alignment: .leading, spacing: 6) {
                            TextField("Add a short note (optional)", text: $text, axis: .vertical)
                                .lineLimit(1...3)
                                .font(.fcBody)
                                .padding(12)
                                .background(Color.fcSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .onChange(of: text) { _, newValue in
                                    if newValue.count > maxLen { text = String(newValue.prefix(maxLen)) }
                                }
                            Text("\(text.count)/\(maxLen)")
                                .font(.fcCaption).foregroundColor(.fcTextSecondary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }

                        if let errorMessage {
                            Text(errorMessage).font(.fcCaption).foregroundColor(.fcError)
                        }

                        Button { Task { await post() } } label: {
                            Group {
                                if isPosting { ProgressView().tint(.white) }
                                else { Text("Post comment").font(.fcBodyBold) }
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                            .background(canPost ? Color.fcAccent : Color.fcTextSecondary.opacity(0.4),
                                       in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(HapticButtonStyle(style: .medium))
                        .disabled(!canPost || isPosting)
                    }
                    .padding(20)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }.foregroundColor(.fcTextSecondary)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var chipGrid: some View {
        FlowChips(tags: Config.Arena.commentTags, selected: selectedTags) { tag in
            if selectedTags.contains(tag) { selectedTags.remove(tag) } else { selectedTags.insert(tag) }
        }
    }

    private func post() async {
        isPosting = true
        errorMessage = nil
        do {
            _ = try await service.postComment(
                fitID: finalist.fitId,
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                tags: Array(selectedTags)
            )
            var updated = finalist
            updated.commentCount += 1
            onPosted(updated)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
        } catch {
            errorMessage = (error as? ArenaError)?.errorDescription ?? "Couldn't post your comment."
        }
        isPosting = false
    }
}

// MARK: - Chip flow layout

/// A simple wrapping row of tag chips. When `onTap` is provided the chips are
/// selectable (comment sheet); otherwise they're read-only labels (comment list).
struct FlowChips: View {
    let tags: [String]
    var selected: Set<String> = []
    var onTap: ((String) -> Void)?

    var body: some View {
        FlowLayout(spacing: 8, lineSpacing: 8) {
            ForEach(tags, id: \.self) { tag in
                let isOn = selected.contains(tag)
                Button {
                    onTap?(tag)
                } label: {
                    Text(tag)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(isOn ? .white : .fcTextPrimary)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(isOn ? Color.fcAccent : Color.fcSurface2, in: Capsule())
                        .overlay(Capsule().stroke(Color.fcTextSecondary.opacity(isOn ? 0 : 0.25), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(onTap == nil)
            }
        }
    }
}

/// Minimal flow layout that wraps its children onto multiple lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0; y += lineHeight + lineSpacing; lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, lineHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth && x > bounds.minX {
                x = bounds.minX; y += lineHeight + lineSpacing; lineHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
