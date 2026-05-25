import SwiftUI

struct StyleGoalScreen: View {
    @ObservedObject var vm: CheckFlowViewModel
    @EnvironmentObject var appState: AppState

    var body: some View {
        ZStack {
            Color.fcBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                VStack(spacing: 6) {
                    Text("What's the vibe today?")
                        .font(.fcHeading)
                        .foregroundColor(.fcTextPrimary)
                    Text("We'll score your look through this lens first.")
                        .font(.fcBody)
                        .foregroundColor(.fcTextSecondary)
                }
                .multilineTextAlignment(.center)
                .padding(.top, 32)
                .padding(.horizontal, 24)
                .padding(.bottom, 28)

                // Goal grid
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(StyleGoal.allCases, id: \.self) { goal in
                        StyleGoalCard(
                            goal: goal,
                            isSelected: vm.selectedGoal == goal
                        ) {
                            withAnimation(.spring(response: 0.3)) {
                                vm.selectedGoal = goal
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)

                // Free tier note
                if !appState.isPremium {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                            .foregroundColor(.fcTextSecondary)
                            .font(.system(size: 13))
                        Text("Free: scored through your selected goal + Gen Z. ")
                            .font(.fcCaption)
                            .foregroundColor(.fcTextSecondary)
                        + Text("Unlock all 8 →")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.fcGold)
                    }
                    .padding(12)
                    .background(Color.fcSurface)
                    .cornerRadius(12)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .onTapGesture { appState.showPremiumSheet = true }
                }

                Spacer()

                // CTA
                Button("Analyze My Fit →") {
                    appState.analyticsService.track(.styleGoalSelected, properties: ["goal": vm.selectedGoal.rawValue])
                    vm.startAnalysis()
                }
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(.fcBackground)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.fcAccent)
                .cornerRadius(16)
                .buttonStyle(HapticButtonStyle())
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
        }
    }
}

struct StyleGoalCard: View {
    let goal: StyleGoal
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                Text(goal.emoji)
                    .font(.system(size: 32))
                Text(goal.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.fcTextPrimary)
                Text(goal.description)
                    .font(.system(size: 11))
                    .foregroundColor(.fcTextSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(isSelected ? Color.fcAccent.opacity(0.15) : Color.fcSurface)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isSelected ? Color.fcAccent : Color.clear, lineWidth: 1.5)
            )
            .cornerRadius(16)
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.fcAccent)
                        .font(.system(size: 18))
                        .padding(8)
                }
            }
        }
        .buttonStyle(HapticButtonStyle(style: .light))
    }
}
