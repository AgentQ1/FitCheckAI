import SwiftUI

/// The Home-screen Arena card — a teaser of today's #1 community fit with a CTA into
/// the full Arena board. No more swipe-to-unlock; the Arena is now a public Top 3
/// voting page, so this card just surfaces the current leader and invites a tap-in.
struct ArenaHomeCard: View {
    @EnvironmentObject var appState: AppState
    @State private var top: ArenaFinalist?
    @State private var isLoading = true

    private let service = ArenaService()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            topRow

            HStack(alignment: .top, spacing: 16) {
                leftColumn
                previewCard
                    .frame(width: 130, height: 180)
            }
        }
        .padding(20)
        .background(Color.fcSurface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: Color.fcShadow, radius: 14, x: 0, y: 8)
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .onTapGesture { appState.selectedTab = .arena }
        .task { if top == nil { await load() } }
    }

    private var topRow: some View {
        HStack {
            Text("⚔️").font(.system(size: 24))
            VStack(alignment: .leading, spacing: 2) {
                Text("Arena").font(.fcHeading).foregroundColor(.fcTextPrimary)
                Text("Today's top fits, voted by the community")
                    .font(.fcCaption).foregroundColor(.fcTextSecondary)
            }
            Spacer()
        }
    }

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let top {
                HStack(spacing: 6) {
                    Image(systemName: "crown.fill").font(.system(size: 13)).foregroundColor(.fcGold)
                    Text("#1 \(top.displayName)").font(.fcBodyBold).foregroundColor(.fcTextPrimary)
                        .lineLimit(1)
                }
                HStack(spacing: 12) {
                    if let s = top.aiScore {
                        Text(String(format: "AI %.1f", s))
                            .font(.system(size: 12, weight: .semibold)).foregroundColor(.fcTextSecondary)
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "flame.fill").font(.system(size: 11)).foregroundColor(.fcAccent)
                        Text("\(top.hotFitCount)").font(.system(size: 12, weight: .semibold)).foregroundColor(.fcTextSecondary)
                    }
                }
            } else {
                Text("Check a fit to join today's Top 3.")
                    .font(.fcBody).foregroundColor(.fcTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            enterButton

            HStack(spacing: 8) {
                avatarTrio
                Text("Vote on the community's best fits")
                    .font(.fcCaption).foregroundColor(.fcTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var enterButton: some View {
        Button { appState.selectedTab = .arena } label: {
            HStack(spacing: 6) {
                Text("Enter Arena").font(.fcBodyBold)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(Color.fcAccent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(HapticButtonStyle(style: .medium))
    }

    private var avatarTrio: some View {
        HStack(spacing: -8) {
            ForEach(0..<3, id: \.self) { i in
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 26))
                    .foregroundColor(.fcTextSecondary.opacity(0.5))
                    .background(Circle().fill(Color.fcSurface))
                    .zIndex(Double(3 - i))
            }
        }
    }

    @ViewBuilder
    private var previewCard: some View {
        ZStack(alignment: .bottomLeading) {
            if let top {
                PortraitOutfitImage(source: URL(string: top.imageUrl).map { .remote($0) })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .allowsHitTesting(false)
                Text("#1 Today")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.black.opacity(0.35), in: Capsule())
                    .padding(10)
            } else if isLoading {
                ZStack { ProgressView().tint(.fcTextSecondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "flame").font(.system(size: 24)).foregroundColor(.fcAccent)
                    Text("No finalists yet").font(.system(size: 11)).foregroundColor(.fcTextSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.fcSurface2, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: Color.fcShadow, radius: 8, x: 0, y: 4)
    }

    private func load() async {
        isLoading = true
        top = (try? await service.fetchFinalists(tab: .today))?.first
        isLoading = false
    }
}
