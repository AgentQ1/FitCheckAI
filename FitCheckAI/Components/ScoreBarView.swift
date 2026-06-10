import SwiftUI

struct ScoreBarView: View {
    let label: String
    let icon: String
    let score: Double
    var delay: Double = 0

    @State private var animatedFill: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(icon)
                    .font(.system(size: 16))
                Text(label)
                    .font(.fcBodyBold)
                    .foregroundColor(.fcTextPrimary)
                Spacer()
                Text(String(format: "%.1f", score))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(Color.scoreColor(for: score))
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.fcTextSecondary.opacity(0.15))
                        .frame(height: 6)
                    Capsule()
                        .fill(Color.scoreColor(for: score))
                        .frame(width: geo.size.width * (animatedFill / 10.0), height: 6)
                        .animation(.spring(response: 0.9, dampingFraction: 0.7).delay(delay), value: animatedFill)
                        .shadow(color: Color.scoreColor(for: score).opacity(0.5), radius: 4)
                }
            }
            .frame(height: 6)
        }
        .padding(16)
        .background(Color.fcSurface)
        .cornerRadius(14)
        .onAppear {
            withAnimation {
                animatedFill = score
            }
        }
    }
}

#Preview {
    ZStack {
        Color.fcBackground
        VStack(spacing: 12) {
            ScoreBarView(label: "Color Harmony", icon: "🎨", score: 8.2, delay: 0)
            ScoreBarView(label: "Fit & Proportion", icon: "📐", score: 6.5, delay: 0.1)
            ScoreBarView(label: "Trend Alignment", icon: "📈", score: 9.1, delay: 0.2)
        }
        .padding()
    }
}
