import SwiftUI

struct LoadingQuipView: View {
    private let quips = [
        "The AI is judging your shoes rn 👀",
        "Checking if that's giving what it's supposed to give...",
        "Consulting the algorithm overlords...",
        "Scanning for drip levels...",
        "Counting the outfit's sins and blessings...",
        "Asking Rihanna (virtually) for a second opinion...",
        "Analyzing your color palette like it owes rent...",
        "Searching 10M outfit references...",
        "Computing your style personality...",
        "Trend database: loading... ████░ 90%"
    ]

    @State private var currentIndex = 0
    private let timer = Timer.publish(every: 2.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(quips[currentIndex])
            .font(.system(size: 14, weight: .medium, design: .rounded))
            .foregroundColor(.fcTextSecondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .id(currentIndex)
            .animation(.easeInOut(duration: 0.4), value: currentIndex)
            .onReceive(timer) { _ in
                currentIndex = (currentIndex + 1) % quips.count
            }
    }
}
