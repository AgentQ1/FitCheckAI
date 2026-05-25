import SwiftUI

struct OnboardingView: View {
    @State private var currentPage = 0
    @State private var navigateToAuth = false

    private let pages: [OnboardingPage] = [
        OnboardingPage(
            icon: "bolt.fill",
            iconColor: Color.fcAccent,
            headline: "Drop the guesswork.",
            body: "Upload your mirror pic. Get an AI style score in seconds.",
            progressIndex: 0
        ),
        OnboardingPage(
            icon: "chart.pie.fill",
            iconColor: Color.fcAccent2,
            headline: "Scored through 8 lenses.",
            body: "Gen Z. Professional. Date Night. Streetwear. Campus. Luxury. And more.",
            progressIndex: 1
        ),
        OnboardingPage(
            icon: "wand.and.stars",
            iconColor: Color.fcGold,
            headline: "See your upgrades.",
            body: "AI generates 3 improved versions of your exact outfit. No judgment, just style.",
            progressIndex: 2
        )
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.fcBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Page content
                    TabView(selection: $currentPage) {
                        ForEach(pages.indices, id: \.self) { idx in
                            OnboardingPageView(page: pages[idx])
                                .tag(idx)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .animation(.spring(), value: currentPage)

                    // Progress dots
                    HStack(spacing: 8) {
                        ForEach(pages.indices, id: \.self) { idx in
                            Capsule()
                                .fill(currentPage == idx ? Color.fcAccent : Color.white.opacity(0.2))
                                .frame(width: currentPage == idx ? 24 : 8, height: 8)
                                .animation(.spring(response: 0.3), value: currentPage)
                        }
                    }
                    .padding(.bottom, 32)

                    // Actions
                    VStack(spacing: 12) {
                        if currentPage < pages.count - 1 {
                            Button("Next →") {
                                withAnimation { currentPage += 1 }
                            }
                            .font(.system(size: 17, weight: .bold))
                            .foregroundColor(.fcBackground)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.fcAccent)
                            .cornerRadius(16)
                        } else {
                            Button("Let's Go →") {
                                navigateToAuth = true
                            }
                            .font(.system(size: 17, weight: .bold))
                            .foregroundColor(.fcBackground)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.fcAccent)
                            .cornerRadius(16)
                            .buttonStyle(HapticButtonStyle())

                            Button("Already have an account? Sign in") {
                                navigateToAuth = true
                            }
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.fcTextSecondary)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 40)
                }
            }
            .navigationDestination(isPresented: $navigateToAuth) {
                AuthView()
            }
        }
    }
}

struct OnboardingPage: Identifiable {
    let id = UUID()
    let icon: String
    let iconColor: Color
    let headline: String
    let body: String
    let progressIndex: Int
}

struct OnboardingPageView: View {
    let page: OnboardingPage
    @State private var iconScale: CGFloat = 0.5
    @State private var textOpacity: Double = 0

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            ZStack {
                Circle()
                    .fill(page.iconColor.opacity(0.12))
                    .frame(width: 140, height: 140)
                Circle()
                    .fill(page.iconColor.opacity(0.07))
                    .frame(width: 200, height: 200)
                Image(systemName: page.icon)
                    .font(.system(size: 60, weight: .bold))
                    .foregroundColor(page.iconColor)
            }
            .scaleEffect(iconScale)

            VStack(spacing: 16) {
                Text(page.headline)
                    .font(.fcDisplay)
                    .foregroundColor(.fcTextPrimary)
                    .multilineTextAlignment(.center)

                Text(page.body)
                    .font(.fcBody)
                    .foregroundColor(.fcTextSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
            .opacity(textOpacity)
            .padding(.horizontal, 32)

            Spacer()
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
                iconScale = 1.0
            }
            withAnimation(.easeOut(duration: 0.5).delay(0.15)) {
                textOpacity = 1.0
            }
        }
    }
}

#Preview {
    OnboardingView()
}
