import SwiftUI
import FirebaseAuth
import FirebaseFirestore

/// Result-screen / history-detail Arena status. Entry is automatic: any fit
/// scoring >= 6.5 from a public profile is auto-pooled into the Arena and ranked
/// for the Top 3 — no manual posting. This card just tells the user where their
/// fit stands:
///   • score >= 6.5 → "You're in today's Arena race 🔥" + View the Arena
///   • score < 6.5  → "Score 6.5+ to enter Arena"
///
/// Frames everything around the OUTFIT competing for the Top 3 — never the person.
struct ArenaCTACard: View {
    let fitID: String
    @EnvironmentObject var appState: AppState

    private enum Phase: Equatable { case loading, inRace, notEligible }
    @State private var phase: Phase = .loading

    private let db = Firestore.firestore()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            content
        }
        .padding(18)
        .background(Color.fcSurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .task(id: fitID) { await load() }
    }

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
        case .loading:      return "Arena"
        case .inRace:       return "You're in the Arena race 🔥"
        case .notEligible:  return "Score 6.5+ to enter Arena"
        }
    }

    private var headerSubtitle: String {
        switch phase {
        case .loading:      return "Checking where this fit stands…"
        case .inRace:       return "This fit is competing for today's community Top 3."
        case .notEligible:  return "Improve your fit and try again — only 6.5+ fits compete."
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            HStack { Spacer(); ProgressView().tint(.fcAccent); Spacer() }.padding(.vertical, 8)

        case .inRace:
            Button { appState.selectedTab = .arena } label: {
                HStack(spacing: 8) {
                    Text("View the Arena").font(.fcBodyBold)
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold))
                }
                .foregroundColor(.fcAccent)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(Color.fcSurface2, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.fcAccent.opacity(0.4), lineWidth: 1))
            }
            .buttonStyle(HapticButtonStyle(style: .light))

        case .notEligible:
            HStack(spacing: 10) {
                Image(systemName: "lock.fill").font(.system(size: 15)).foregroundColor(.fcTextSecondary)
                Text("Fits automatically enter the Arena when they score 6.5 or higher.")
                    .font(.fcBody).foregroundColor(.fcTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }

    private func load() async {
        guard let uid = Auth.auth().currentUser?.uid else { phase = .notEligible; return }
        do {
            let snap = try await db.collection("users/\(uid)/fit_checks").document(fitID).getDocument()
            let score = snap.data()?["overallScore"] as? Double
            phase = (score ?? 0) >= Config.Arena.minScore ? .inRace : .notEligible
        } catch {
            // Couldn't read the score — assume in-race rather than dead-ending.
            phase = .inRace
        }
    }
}
