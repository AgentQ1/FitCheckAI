import SwiftUI

struct ProfileSetupView: View {
    @EnvironmentObject var appState: AppState
    @State private var step = 1
    @State private var firstName = ""
    @State private var selectedPreferences: Set<String> = []

    private let styleOptions = [
        ("Streetwear", "🛹"), ("Minimal", "🤍"),
        ("Old Money", "👑"), ("Y2K", "💿"),
        ("Business Casual", "💼"), ("Cottagecore", "🌸"),
        ("Techwear", "⚙️"), ("Athleisure", "🏃")
    ]

    var body: some View {
        ZStack {
            Color.fcBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Step indicator
                HStack(spacing: 8) {
                    ForEach(1...2, id: \.self) { s in
                        Capsule()
                            .fill(step >= s ? Color.fcAccent : Color.white.opacity(0.15))
                            .frame(height: 4)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 32)

                if step == 1 {
                    stepOneView
                } else {
                    stepTwoView
                }
            }
        }
        .navigationBarBackButtonHidden(true)
    }

    private var stepOneView: some View {
        VStack(spacing: 28) {
            VStack(spacing: 8) {
                Text("What's your name?")
                    .font(.fcDisplay)
                    .foregroundColor(.fcTextPrimary)
                Text("We'll personalize your experience.")
                    .font(.fcBody)
                    .foregroundColor(.fcTextSecondary)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)

            FCTextField(placeholder: "First name", text: $firstName, icon: "person")
                .padding(.horizontal, 24)

            Spacer()

            Button("Continue →") {
                if !firstName.isEmpty {
                    withAnimation(.spring()) { step = 2 }
                }
            }
            .font(.system(size: 17, weight: .bold))
            .foregroundColor(.fcBackground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(firstName.isEmpty ? Color.fcAccent.opacity(0.4) : Color.fcAccent)
            .cornerRadius(16)
            .disabled(firstName.isEmpty)
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
            .buttonStyle(HapticButtonStyle())
        }
    }

    private var stepTwoView: some View {
        VStack(spacing: 28) {
            VStack(spacing: 8) {
                Text("What's your style vibe?")
                    .font(.fcDisplay)
                    .foregroundColor(.fcTextPrimary)
                Text("Choose up to 3.")
                    .font(.fcBody)
                    .foregroundColor(.fcTextSecondary)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(styleOptions, id: \.0) { option in
                    Button(action: {
                        togglePreference(option.0)
                    }) {
                        HStack(spacing: 10) {
                            Text(option.1).font(.system(size: 20))
                            Text(option.0)
                                .font(.fcBodyBold)
                                .foregroundColor(.fcTextPrimary)
                            Spacer()
                            if selectedPreferences.contains(option.0) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.fcAccent)
                            }
                        }
                        .padding(14)
                        .background(selectedPreferences.contains(option.0) ? Color.fcAccent.opacity(0.15) : Color.fcSurface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(selectedPreferences.contains(option.0) ? Color.fcAccent : Color.clear, lineWidth: 1.5)
                        )
                        .cornerRadius(14)
                    }
                    .buttonStyle(HapticButtonStyle(style: .light))
                }
            }
            .padding(.horizontal, 24)

            Spacer()

            VStack(spacing: 12) {
                Button("Start Checking Fits →") {
                    finishSetup()
                }
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(.fcBackground)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.fcAccent)
                .cornerRadius(16)
                .buttonStyle(HapticButtonStyle())

                Button("Skip for now") {
                    finishSetup()
                }
                .font(.fcBody)
                .foregroundColor(.fcTextSecondary)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }

    private func togglePreference(_ pref: String) {
        if selectedPreferences.contains(pref) {
            selectedPreferences.remove(pref)
        } else if selectedPreferences.count < 3 {
            selectedPreferences.insert(pref)
        }
    }

    private func finishSetup() {
        Task {
            await appState.refreshUser()
        }
    }
}
