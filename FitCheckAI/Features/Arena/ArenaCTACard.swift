import SwiftUI
import FirebaseAuth
import FirebaseFirestore

/// Result-screen / history-detail Arena CTA. Reads the fit's real score + posted
/// status so the copy is always truthful:
///   • score >= 6.5, not posted → "Eligible for Arena 🔥" + Post to Arena
///   • already posted           → "Posted to Arena 🔥" + View Arena
///   • score < 6.5              → "Score 6.5+ to enter Arena"
///
/// Frames everything around the OUTFIT competing for today's Top 3 — never the person.
struct ArenaCTACard: View {
    let fitID: String
    @EnvironmentObject var appState: AppState

    private enum Phase: Equatable { case loading, eligible, notEligible, posting, posted }
    @State private var phase: Phase = .loading
    @State private var score: Double?
    @State private var errorMessage: String?

    private let db = Firestore.firestore()
    private let service = ArenaService()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let errorMessage {
                Text(errorMessage).font(.fcCaption).foregroundColor(.fcError)
            }
            content
        }
        .padding(18)
        .background(Color.fcSurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .task(id: fitID) { await load() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Text("⚔️").font(.system(size: 22))
            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle).font(.fcBodyBold).foregroundColor(.fcTextPrimary)
                Text(headerSubtitle).font(.fcCaption).foregroundColor(.fcTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var headerTitle: String {
        switch phase {
        case .loading:               return "Arena"
        case .eligible, .posting:    return "Eligible for Arena 🔥"
        case .posted:                return "Posted to Arena 🔥"
        case .notEligible:           return "Score 6.5+ to enter Arena"
        }
    }

    private var headerSubtitle: String {
        switch phase {
        case .loading:               return "Checking if this fit can enter the Arena…"
        case .eligible, .posting:    return "Post this fit for a chance to enter \(todayOrWeek) Top 3."
        case .posted:                return "It's in the running for the community Top 3."
        case .notEligible:           return "Improve your fit and try again."
        }
    }

    private var todayOrWeek: String { "today's" }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            HStack { Spacer(); ProgressView().tint(.fcAccent); Spacer() }.padding(.vertical, 8)

        case .eligible:
            filledButton(title: "Post to Arena", icon: "flame.fill") { Task { await post() } }

        case .posting:
            HStack { Spacer(); ProgressView().tint(.white); Spacer() }
                .padding(.vertical, 16)
                .background(Color.fcAccent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

        case .posted:
            outlinedButton(title: "View the Arena", icon: "chevron.right") { appState.selectedTab = .arena }

        case .notEligible:
            HStack(spacing: 10) {
                Image(systemName: "lock.fill").font(.system(size: 15)).foregroundColor(.fcTextSecondary)
                Text("Only fits scoring 6.5 or higher can compete.")
                    .font(.fcBody).foregroundColor(.fcTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }

    private func filledButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 15, weight: .bold))
                Text(title).font(.fcBodyBold)
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity).padding(.vertical, 16)
            .background(Color.fcAccent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(HapticButtonStyle(style: .medium))
    }

    private func outlinedButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).font(.fcBodyBold)
                Image(systemName: icon).font(.system(size: 13, weight: .bold))
            }
            .foregroundColor(.fcAccent)
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(Color.fcSurface2, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.fcAccent.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(HapticButtonStyle(style: .light))
    }

    // MARK: Data

    private func load() async {
        guard let uid = Auth.auth().currentUser?.uid else { phase = .notEligible; return }
        do {
            let snap = try await db.collection("users/\(uid)/fit_checks").document(fitID).getDocument()
            let data = snap.data() ?? [:]
            let s = data["overallScore"] as? Double
            score = s
            let posted = (data["arenaPosted"] as? Bool) ?? false
            if posted {
                phase = .posted
            } else if let s, s >= Config.Arena.minScore {
                phase = .eligible
            } else {
                phase = .notEligible
            }
        } catch {
            // Couldn't read — let the user try posting; the backend re-checks eligibility.
            phase = .eligible
        }
    }

    private func post() async {
        phase = .posting
        errorMessage = nil
        do {
            _ = try await service.enterArena(fitCheckID: fitID)
            phase = .posted
        } catch {
            if case ArenaError.notEligible(let msg) = error {
                phase = .notEligible
                errorMessage = msg
            } else {
                phase = .eligible
                errorMessage = (error as? ArenaError)?.errorDescription ?? "Couldn't post to the Arena."
            }
        }
    }
}
