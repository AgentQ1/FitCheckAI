import SwiftUI

/// Result-screen / history-detail Arena status. Entry is automatic: any fit
/// scoring >= 6.5 from a public profile is pooled into the Arena and ranked for
/// the Top 3 — no manual posting. This card calls `ensureArenaEntry`, which both
/// reports the fit's TRUE state and backfills/self-heals a missing entry, so it
/// never claims "in the race" for a fit that isn't actually competing.
///
///   • in the pool   → "You're in the Arena race 🔥" (+ finalist note) + View
///   • private        → "Make your profile public to compete"
///   • score < 6.5    → "Score 6.5+ to enter Arena"
///
/// Frames everything around the OUTFIT competing for the Top 3 — never the person.
struct ArenaCTACard: View {
    let fitID: String
    @EnvironmentObject var appState: AppState

    private enum Phase: Equatable { case loading, inRace, isPrivate, notEligible }
    @State private var phase: Phase = .loading
    @State private var isFinalist = false
    @State private var todayRank: Int?

    private let service = ArenaService()

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
        case .inRace:       return isFinalist ? "Top 3 finalist! 🔥" : "You're in the Arena race 🔥"
        case .isPrivate:    return "Go public to enter the Arena"
        case .notEligible:  return "Score 6.5+ to enter Arena"
        }
    }

    private var headerSubtitle: String {
        switch phase {
        case .loading:      return "Checking where this fit stands…"
        case .inRace:
            if isFinalist, let r = todayRank { return "Currently #\(r) on today's board. View the Arena." }
            return "This fit is competing for today's community Top 3."
        case .isPrivate:    return "Your fits only compete when your profile is public."
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

        case .isPrivate:
            HStack(spacing: 10) {
                Image(systemName: "eye.slash.fill").font(.system(size: 15)).foregroundColor(.fcTextSecondary)
                Text("Make your profile public in Edit Profile to let your fits compete.")
                    .font(.fcBody).foregroundColor(.fcTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

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
        do {
            let status = try await service.ensureEntry(fitCheckID: fitID)
            isFinalist = status.isFinalist ?? false
            todayRank = status.todayRank
            if status.inArena {
                phase = .inRace
            } else if !status.isPublic {
                phase = .isPrivate
            } else {
                phase = .notEligible
            }
        } catch {
            // Network/transient — don't dead-end; the board still works.
            phase = .notEligible
        }
    }
}
