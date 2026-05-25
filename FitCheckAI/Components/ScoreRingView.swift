import SwiftUI

struct ScoreRingView: View {
    let score: Double
    var size: CGFloat = 140
    var showLabel: Bool = true

    @State private var animatedScore: Double = 0

    private var ringColor: Color { .scoreColor(for: score) }
    private var lineWidth: CGFloat { size * 0.08 }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.08), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: animatedScore / 10.0)
                .stroke(
                    ringColor,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.spring(response: 1.2, dampingFraction: 0.7), value: animatedScore)
                .shadow(color: ringColor.opacity(0.6), radius: 8)

            if showLabel {
                VStack(spacing: 2) {
                    Text(String(format: "%.1f", animatedScore))
                        .font(.system(size: size * 0.28, weight: .bold, design: .rounded))
                        .foregroundColor(.fcTextPrimary)
                        .contentTransition(.numericText())
                    Text("/ 10")
                        .font(.system(size: size * 0.1, weight: .medium))
                        .foregroundColor(.fcTextSecondary)
                }
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(.spring(response: 1.2, dampingFraction: 0.7).delay(0.3)) {
                animatedScore = score
            }
        }
    }
}

// MARK: - Mini Score Badge
struct ScoreBadge: View {
    let score: Double
    var fontSize: CGFloat = 14

    var body: some View {
        Text(String(format: "%.1f", score))
            .font(.system(size: fontSize, weight: .bold, design: .rounded))
            .foregroundColor(.fcBackground)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.scoreColor(for: score))
            .clipShape(Capsule())
    }
}

#Preview {
    ZStack {
        Color.fcBackground
        VStack(spacing: 24) {
            ScoreRingView(score: 8.4)
            ScoreRingView(score: 6.2, size: 80)
            HStack { ScoreBadge(score: 8.4); ScoreBadge(score: 5.1); ScoreBadge(score: 9.6) }
        }
    }
}
