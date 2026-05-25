import SwiftUI

struct ImprovementTipsView: View {
    let analysis: OutfitAnalysis
    let outfitImage: UIImage?

    @EnvironmentObject var appState: AppState
    @State private var showOutfitOptions = false

    var body: some View {
        ZStack {
            Color.fcBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Header
                    HStack(spacing: 10) {
                        Image(systemName: "note.text")
                            .foregroundColor(.fcAccent)
                        Text("Style Notes")
                            .font(.fcHeading)
                            .foregroundColor(.fcTextPrimary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                    // What's working
                    tipsSection(
                        title: "What's Working ✅",
                        items: analysis.whatWorks,
                        iconName: "checkmark.circle.fill",
                        iconColor: .fcSuccess
                    )

                    // What to improve
                    tipsSection(
                        title: "What to Improve 🛠️",
                        items: analysis.whatToImprove,
                        iconName: "exclamationmark.triangle.fill",
                        iconColor: .fcWarning
                    )

                    // Best one change
                    bestChangeCard

                    // Style personality
                    personalityCard

                    // AI upgrades CTA
                    if appState.isPremium {
                        Button("See AI Outfit Upgrades →") {
                            showOutfitOptions = true
                            appState.analyticsService.track(.outfitOptionsViewed)
                        }
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.fcBackground)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.fcAccent)
                        .cornerRadius(16)
                        .buttonStyle(HapticButtonStyle())
                        .padding(.horizontal, 20)
                    } else {
                        premiumUpgradeCard
                    }

                    Spacer(minLength: 50)
                }
                .padding(.top, 8)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showOutfitOptions) {
            OutfitOptionsView(analysis: analysis, outfitImage: outfitImage)
                .environmentObject(appState)
        }
        .onAppear {
            appState.analyticsService.track(.tipsViewed)
        }
    }

    private func tipsSection(title: String, items: [String], iconName: String, iconColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.fcBodyBold)
                .foregroundColor(.fcTextPrimary)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: iconName)
                            .foregroundColor(iconColor)
                            .font(.system(size: 14))
                            .padding(.top, 2)
                        Text(item)
                            .font(.fcBody)
                            .foregroundColor(.fcTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(16)
        .background(Color.fcSurface)
        .cornerRadius(16)
        .padding(.horizontal, 20)
    }

    private var bestChangeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "target")
                    .foregroundColor(.fcAccent)
                Text("Best One Change 🎯")
                    .font(.fcBodyBold)
                    .foregroundColor(.fcTextPrimary)
            }

            Text(analysis.bestOneChange)
                .font(.fcBody)
                .foregroundColor(.fcTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(Color.fcSurface)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.fcAccent, lineWidth: 1.5)
        )
        .cornerRadius(16)
        .padding(.horizontal, 20)
    }

    private var personalityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("🪞")
                Text("Style Personality")
                    .font(.fcBodyBold)
                    .foregroundColor(.fcTextPrimary)
            }

            Text(analysis.stylePersonality)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(.fcAccent)

            Text("You dress with intention. Your choices suggest someone who knows what they want from a look.")
                .font(.fcBody)
                .foregroundColor(.fcTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(Color.fcSurface)
        .cornerRadius(16)
        .padding(.horizontal, 20)
    }

    private var premiumUpgradeCard: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.fcGold.opacity(0.15))
                        .frame(width: 50, height: 50)
                    Text("✨")
                        .font(.system(size: 24))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("See 3 AI Outfit Upgrades")
                        .font(.fcBodyBold)
                        .foregroundColor(.fcTextPrimary)
                    Text("Watch your outfit transform with AI-generated looks.")
                        .font(.fcCaption)
                        .foregroundColor(.fcTextSecondary)
                }
            }

            Button("Go Premium — $4.99/mo →") {
                appState.showPremiumSheet = true
                appState.analyticsService.track(.premiumUpgradeTapped)
            }
            .font(.system(size: 16, weight: .bold))
            .foregroundColor(.fcBackground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.fcGold)
            .cornerRadius(14)
            .buttonStyle(HapticButtonStyle())
        }
        .padding(16)
        .background(Color.fcGold.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.fcGold.opacity(0.3), lineWidth: 1)
        )
        .cornerRadius(16)
        .padding(.horizontal, 20)
    }
}
