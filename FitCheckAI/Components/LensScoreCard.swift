import SwiftUI

struct LensScoreCard: View {
    let goal: StyleGoal
    let score: Double?
    var isSelected: Bool = false
    var isLocked: Bool = false
    var onUnlock: (() -> Void)?

    var body: some View {
        ZStack {
            VStack(spacing: 6) {
                Text(goal.emoji)
                    .font(.system(size: 28))
                Text(goal.shortName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.fcTextSecondary)
                if let score {
                    Text(String(format: "%.1f", score))
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(Color.scoreColor(for: score))
                } else {
                    Text("—")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.fcTextSecondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(isSelected ? Color.fcAccent.opacity(0.12) : Color.fcSurface)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? Color.fcAccent : Color.clear, lineWidth: 1.5)
            )
            .cornerRadius(14)

            if isLocked {
                PremiumLockOverlay(label: "Premium", onUpgrade: onUnlock)
                    .cornerRadius(14)
            }
        }
    }
}

#Preview {
    ZStack {
        Color.fcBackground
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            LensScoreCard(goal: .genZ, score: 8.8, isSelected: true)
            LensScoreCard(goal: .professional, score: 6.1, isLocked: true)
            LensScoreCard(goal: .campus, score: 9.1)
            LensScoreCard(goal: .luxury, score: nil, isLocked: true)
        }
        .padding()
    }
}
