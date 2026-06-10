import SwiftUI
import FirebaseAuth
import FirebaseFirestore

struct ProfileSetupView: View {
    @EnvironmentObject var appState: AppState
    @State private var step = 1
    @State private var firstName = ""
    // Uses the same StyleGoal vocabulary as EditProfileView so onboarding and
    // editing store identical raw values (e.g. "gen_z", "streetwear", "luxury").
    @State private var selectedPreferences: Set<StyleGoal> = []
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let db = Firestore.firestore()

    var body: some View {
        ZStack {
            Color.fcBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Step indicator
                HStack(spacing: 8) {
                    ForEach(1...2, id: \.self) { s in
                        Capsule()
                            .fill(step >= s ? Color.fcAccent : Color.fcTextSecondary.opacity(0.25))
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
        .onAppear(perform: prefillFromCurrentUser)
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
                if !trimmedName.isEmpty {
                    withAnimation(.spring()) { step = 2 }
                }
            }
            .font(.system(size: 17, weight: .bold))
            .foregroundColor(.fcBackground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(trimmedName.isEmpty ? Color.fcAccent.opacity(0.4) : Color.fcAccent)
            .cornerRadius(16)
            .disabled(trimmedName.isEmpty)
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
                ForEach(StyleGoal.allCases, id: \.self) { goal in
                    Button(action: {
                        togglePreference(goal)
                    }) {
                        HStack(spacing: 10) {
                            Text(goal.emoji).font(.system(size: 20))
                            Text(goal.displayName)
                                .font(.fcBodyBold)
                                .foregroundColor(.fcTextPrimary)
                            Spacer()
                            if selectedPreferences.contains(goal) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.fcAccent)
                            }
                        }
                        .padding(14)
                        .background(selectedPreferences.contains(goal) ? Color.fcAccent.opacity(0.15) : Color.fcSurface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(selectedPreferences.contains(goal) ? Color.fcAccent : Color.clear, lineWidth: 1.5)
                        )
                        .cornerRadius(14)
                    }
                    .buttonStyle(HapticButtonStyle(style: .light))
                }
            }
            .padding(.horizontal, 24)

            Spacer()

            VStack(spacing: 12) {
                Button(action: { finishSetup() }) {
                    Group {
                        if isSaving {
                            ProgressView().tint(.fcBackground)
                        } else {
                            Text("Start Checking Fits →")
                        }
                    }
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.fcBackground)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.fcAccent)
                    .cornerRadius(16)
                }
                .buttonStyle(HapticButtonStyle())
                .disabled(isSaving)

                Button("Skip for now") {
                    finishSetup()
                }
                .font(.fcBody)
                .foregroundColor(.fcTextSecondary)
                .disabled(isSaving)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.fcCaption)
                        .foregroundColor(.fcError)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }

    // MARK: - State

    private var trimmedName: String {
        firstName.trimmingCharacters(in: .whitespaces)
    }

    private func prefillFromCurrentUser() {
        guard let user = appState.currentUser else { return }
        // Providers like Google hand back a name — start from it instead of blank.
        if firstName.isEmpty { firstName = user.displayName ?? "" }
        if selectedPreferences.isEmpty {
            selectedPreferences = Set(user.stylePreferences.compactMap { StyleGoal(rawValue: $0) })
        }
    }

    private func togglePreference(_ goal: StyleGoal) {
        if selectedPreferences.contains(goal) {
            selectedPreferences.remove(goal)
        } else if selectedPreferences.count < 3 {
            selectedPreferences.insert(goal)
        }
    }

    // MARK: - Persistence

    /// Persists the onboarding input to Firestore (the source of truth), syncs
    /// Firebase Auth, then refreshes in-memory state. Marking
    /// `profileSetupComplete = true` flips `appState.needsProfileSetup` to false
    /// (via applyUser), which lets RootView swap from this screen to the app.
    private func finishSetup() {
        guard let firebaseUser = Auth.auth().currentUser else {
            // No signed-in user to attach the profile to — just leave the gate.
            appState.needsProfileSetup = false
            return
        }
        let uid = firebaseUser.uid
        let name = trimmedName
        isSaving = true
        errorMessage = nil

        let prefs = selectedPreferences.map { $0.rawValue }
        let updates: [String: Any] = [
            "displayName": name,
            "stylePreferences": prefs,
            "profileSetupComplete": true
        ]
        print("[ProfileSetup] save start uid=\(uid) name=\(name) prefs=\(prefs)")

        Task {
            do {
                // 1. Firestore — what the app reads on launch / after login.
                try await db.collection("users").document(uid).updateData(updates)
                print("[ProfileSetup] firestore saved: \(updates)")

                // 2. Keep Firebase Auth's displayName in sync so a later login
                //    doesn't resurrect a blank/provider name over this one.
                if !name.isEmpty {
                    let change = firebaseUser.createProfileChangeRequest()
                    change.displayName = name
                    try await change.commitChanges()
                }

                // 3. Mirror the chosen name for leaderboards. photoURL stays nil so
                //    the merge keeps whatever photo upsert already seeded.
                await PublicProfileService.write(uid: uid, displayName: name, photoURL: nil)

                // 4. Refetch from Firestore → applyUser updates currentUser and
                //    clears needsProfileSetup, transitioning into the app.
                await appState.refreshUser()
                await MainActor.run { isSaving = false }
            } catch {
                print("[ProfileSetup] save failed: \(error)")
                await MainActor.run {
                    isSaving = false
                    errorMessage = "Couldn't save your profile. Please try again."
                }
            }
        }
    }
}
