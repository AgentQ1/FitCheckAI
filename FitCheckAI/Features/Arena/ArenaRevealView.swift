import SwiftUI

/// The Human Fit Score reveal. Driven by the dual gate from `getMyArenaResults`:
/// locked_reciprocity → "rate more", locked_votes → "waiting for votes",
/// revealed → the Style Approval payoff (anonymous aggregate only — never who voted).
struct ArenaRevealView: View {
    let fitID: String
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var result: ArenaResult?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var revealScale: CGFloat = 0.6

    private let service = ArenaService()

    var body: some View {
        ZStack {
            Color.fcBackground.ignoresSafeArea()
            if isLoading {
                ProgressView().tint(.fcTextSecondary)
            } else if let result {
                content(for: result)
            } else {
                errorState
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private func content(for result: ArenaResult) -> some View {
        switch result.state {
        case .revealed:        revealed(result)
        case .lockedReciprocity: locked(
            icon: "hand.thumbsup.fill",
            title: "Almost there",
            message: "Rate \(result.remaining ?? 0) more fit\(result.remaining == 1 ? "" : "s") to unlock this fit's score.",
            showRateButton: true)
        case .lockedVotes:     locked(
            icon: "hourglass",
            title: "Unlocked soon",
            message: "Waiting for \(result.remaining ?? 0) more rating\(result.remaining == 1 ? "" : "s") on your fit.",
            showRateButton: false)
        }
    }

    // MARK: Revealed

    private func revealed(_ r: ArenaResult) -> some View {
        VStack(spacing: 22) {
            Spacer()
            Text("Human Fit Score")
                .font(.fcTitle)
                .foregroundColor(.fcTextSecondary)

            Text("\(r.approvalPercent ?? 0)%")
                .font(.system(size: 84, weight: .bold, design: .rounded))
                .foregroundColor(.fcAccent)
                .scaleEffect(revealScale)
                .onAppear {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.55)) { revealScale = 1 }
                }

            Text("Style Approval")
                .font(.fcBodyBold)
                .foregroundColor(.fcTextPrimary)

            Text("\(r.voteCount ?? 0) \(r.voteCount == 1 ? "person" : "people") rated your fit")
                .font(.fcBody)
                .foregroundColor(.fcTextSecondary)

            // AI → Human comparison.
            if let ai = r.aiScore {
                HStack(spacing: 10) {
                    pill(label: "AI Score", value: String(format: "%.1f", ai), tint: .fcTextSecondary)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.fcTextSecondary)
                    pill(label: "Human", value: "\(r.approvalPercent ?? 0)%", tint: .fcAccent)
                }
                .padding(.top, 4)
            }

            if let pct = r.percentile {
                Text("Ahead of \(pct)% of similar fits")
                    .font(.fcCaption)
                    .foregroundColor(.fcGold)
                    .padding(.top, 2)
            }

            Spacer()
            doneButton
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 24)
        .multilineTextAlignment(.center)
    }

    private func pill(label: String, value: String, tint: Color) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.fcTag).foregroundColor(.fcTextSecondary)
            Text(value).font(.system(size: 22, weight: .bold, design: .rounded)).foregroundColor(tint)
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(Color.fcSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: Locked states

    private func locked(icon: String, title: String, message: String, showRateButton: Bool) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundColor(.fcAccent)
            Text(title).font(.fcTitle).foregroundColor(.fcTextPrimary)
            Text(message).font(.fcBody).foregroundColor(.fcTextSecondary)
            Spacer()
            if showRateButton {
                Button {
                    appState.selectedTab = .arena
                    dismiss()
                } label: {
                    Text("Rate fits in the Arena")
                        .font(.fcBodyBold).foregroundColor(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                        .background(Color.fcAccent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(HapticButtonStyle(style: .medium))
            }
            doneButton
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 24)
        .multilineTextAlignment(.center)
    }

    private var errorState: some View {
        VStack(spacing: 14) {
            Text(errorMessage ?? "Couldn't load your results.")
                .font(.fcBody).foregroundColor(.fcTextSecondary)
            doneButton
        }
        .padding(28)
        .multilineTextAlignment(.center)
    }

    private var doneButton: some View {
        Button("Done") { dismiss() }
            .font(.fcBodyBold)
            .foregroundColor(.fcTextSecondary)
            .padding(.top, 4)
    }

    private func load() async {
        isLoading = true
        do { result = try await service.myResults(fitID: fitID) }
        catch { errorMessage = (error as? ArenaError)?.errorDescription }
        isLoading = false
    }
}
