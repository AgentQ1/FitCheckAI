import SwiftUI

/// Result-screen call to action: invites the user to share this analyzed fit to the
/// Arena and get a Human Fit Score. After sharing it surfaces the reciprocity/vote
/// progress and opens the reveal sheet. Frames the score as the OUTFIT's approval,
/// never the person.
struct ArenaCTACard: View {
    let fitID: String
    @EnvironmentObject var appState: AppState

    private enum Phase: Equatable { case idle, posting, posted }
    @State private var phase: Phase = .idle
    @State private var errorMessage: String?
    @State private var showReveal = false

    private let service = ArenaService()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text("⚔️").font(.system(size: 22))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Get your Human Fit Score 👀")
                        .font(.fcBodyBold)
                        .foregroundColor(.fcTextPrimary)
                    Text("Share this fit to the Arena and see what real people think.")
                        .font(.fcCaption)
                        .foregroundColor(.fcTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.fcCaption)
                    .foregroundColor(.fcError)
            }

            actionButton
        }
        .padding(18)
        .background(Color.fcSurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .sheet(isPresented: $showReveal) {
            ArenaRevealView(fitID: fitID).environmentObject(appState)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch phase {
        case .idle:
            button(title: "Send to Arena", icon: "paperplane.fill") { Task { await send() } }
        case .posting:
            HStack { Spacer(); ProgressView().tint(.white); Spacer() }
                .padding(.vertical, 16)
                .background(Color.fcAccent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        case .posted:
            button(title: "See what people think", icon: "sparkles") { showReveal = true }
        }
    }

    private func button(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 15, weight: .bold))
                Text(title).font(.fcBodyBold)
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color.fcAccent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(HapticButtonStyle(style: .medium))
    }

    private func send() async {
        phase = .posting
        errorMessage = nil
        do {
            _ = try await service.enterArena(fitCheckID: fitID)
            phase = .posted
            showReveal = true   // opens the reveal sheet (shows the locked state first)
        } catch {
            phase = .idle
            errorMessage = (error as? ArenaError)?.errorDescription ?? "Couldn't share to the Arena."
        }
    }
}
