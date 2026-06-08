import SwiftUI

struct SplashScreen: View {
    @EnvironmentObject var appState: AppState
    @State private var progress: CGFloat = 0
    @State private var logoScale: CGFloat = 0.6
    @State private var logoOpacity: Double = 0

    var body: some View {
        ZStack {
            Color.fcBackground.ignoresSafeArea()

            VStack(spacing: 16) {
                Spacer()

                // Logo — uses the real AppIcon artwork, masked with iOS's
                // squircle radius so it reads as "the app" on the splash.
                Image("AppLogo")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 116, height: 116)
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .shadow(color: Color.fcShadow, radius: 18, x: 0, y: 10)
                    .scaleEffect(logoScale)
                    .opacity(logoOpacity)

                VStack(spacing: 6) {
                    Text("FitCheck")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .foregroundColor(.fcTextPrimary)

                    Text("Your AI stylist.")
                        .font(.fcBody)
                        .foregroundColor(.fcTextSecondary)
                }
                .opacity(logoOpacity)

                Spacer()

                // Progress bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.fcTextSecondary.opacity(0.2))
                            .frame(height: 3)
                        Capsule()
                            .fill(Color.fcAccent)
                            .frame(width: geo.size.width * progress, height: 3)
                    }
                }
                .frame(height: 3)
                .padding(.horizontal, 60)
                .padding(.bottom, 48)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
                logoScale = 1.0
                logoOpacity = 1.0
            }
            // Run the bar progressively — but cap it so we don't sit on the splash
            // longer than necessary if auth resolves quickly.
            withAnimation(.linear(duration: 0.8)) {
                progress = 0.85
            }
        }
        .onChange(of: appState.isLoadingAuth) { _, loading in
            if !loading {
                withAnimation(.linear(duration: 0.2)) { progress = 1.0 }
            }
        }
    }
}
