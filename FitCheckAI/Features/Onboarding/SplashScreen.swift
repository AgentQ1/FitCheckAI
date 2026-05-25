import SwiftUI

struct SplashScreen: View {
    @State private var progress: CGFloat = 0
    @State private var logoScale: CGFloat = 0.6
    @State private var logoOpacity: Double = 0

    var body: some View {
        ZStack {
            Color.fcBackground.ignoresSafeArea()

            VStack(spacing: 16) {
                Spacer()

                // Logo
                ZStack {
                    Circle()
                        .fill(Color.fcAccent.opacity(0.12))
                        .frame(width: 100, height: 100)

                    Image(systemName: "bolt.fill")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundColor(.fcAccent)
                }
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
            withAnimation(.linear(duration: 1.5)) {
                progress = 1.0
            }
        }
    }
}

#Preview {
    SplashScreen()
}
