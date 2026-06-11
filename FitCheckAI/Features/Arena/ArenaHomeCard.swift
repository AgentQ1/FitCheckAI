import SwiftUI

/// The Home-screen Arena card — the app's primary engagement surface. Shows a live
/// preview of another user's public fit with inline 👍/👎, the reciprocity progress,
/// and an "Enter Arena" CTA into the full swipe view. Reuses `ArenaViewModel` so a
/// vote here advances the same queue and unlock progress.
struct ArenaHomeCard: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = ArenaViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            topRow
            Text("Rate 5 fits to unlock your Human Fit Score.")
                .font(.fcBody)
                .foregroundColor(.fcTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 16) {
                leftColumn
                previewCard
                    .frame(width: 150, height: 210)
            }

            hintFooter
        }
        .padding(20)
        .background(Color.fcSurface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: Color.fcShadow, radius: 14, x: 0, y: 8)
        .task { if vm.queue.isEmpty { await vm.load() } }
    }

    // MARK: Top row — title + rated pill

    private var topRow: some View {
        HStack {
            Text("⚔️").font(.system(size: 24))
            Text("Arena")
                .font(.fcHeading)
                .foregroundColor(.fcTextPrimary)
            Spacer()
            Text("\(vm.ratedTowardUnlock)/\(vm.required) rated")
                .font(.fcTag)
                .foregroundColor(.fcTextSecondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.fcBackground, in: Capsule())
        }
    }

    // MARK: Left column — progress, CTA, social proof

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 6) {
                ForEach(0..<vm.required, id: \.self) { i in
                    Circle()
                        .fill(i < vm.ratedTowardUnlock ? Color.fcAccent : Color.fcTextSecondary.opacity(0.2))
                        .frame(width: 12, height: 12)
                }
            }

            Button {
                appState.selectedTab = .arena
            } label: {
                HStack(spacing: 6) {
                    Text("Enter Arena").font(.fcBodyBold)
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.fcAccent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(HapticButtonStyle(style: .medium))

            HStack(spacing: 8) {
                avatarTrio
                Text("Join others in rating real people's fits")
                    .font(.fcCaption)
                    .foregroundColor(.fcTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    // MARK: Preview card — one public fit with inline rate buttons

    @ViewBuilder
    private var previewCard: some View {
        ZStack(alignment: .bottom) {
            if let item = vm.current {
                SmartOutfitImageView(source: URL(string: item.imageUrl).map { .remote($0) })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .allowsHitTesting(false)

                VStack(spacing: 8) {
                    VStack(spacing: 0) {
                        Text("Would you wear this?")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                        Text("Rate the fit")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.85))
                    }
                    HStack(spacing: 22) {
                        miniButton(system: "xmark", tint: .red) { Task { await vm.vote(liked: false) } }
                        miniButton(system: "heart.fill", tint: .fcAccent) { Task { await vm.vote(liked: true) } }
                    }
                }
                .padding(.bottom, 12)
            } else if vm.isLoading {
                placeholder { ProgressView().tint(.fcTextSecondary) }
            } else {
                placeholder {
                    VStack(spacing: 6) {
                        Image(systemName: "hourglass").font(.system(size: 26)).foregroundColor(.fcAccent)
                        Text("Waiting for fits")
                            .font(.fcCaption).foregroundColor(.fcTextPrimary)
                        Text("Tap Enter Arena to share yours")
                            .font(.system(size: 11)).foregroundColor(.fcTextSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 8)
                }
            }
        }
        .background(Color.fcSurface2, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: Color.fcShadow, radius: 8, x: 0, y: 4)
        // Faint stacked-card edge behind, for the Tinder look.
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.fcSurface2.opacity(0.6))
                .rotationEffect(.degrees(4))
                .offset(x: 8, y: 6)
        )
    }

    private func placeholder<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ZStack { content() }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func miniButton(system: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(tint)
                .frame(width: 38, height: 38)
                .background(Color.fcSurface, in: Circle())
        }
        .buttonStyle(HapticButtonStyle(style: .light))
    }

    private var hintFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.draw.fill").font(.system(size: 12))
            Text("Swipe right to like, left to pass")
                .font(.fcCaption).italic()
        }
        .foregroundColor(.fcTextSecondary)
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
    }
}
