import SwiftUI
import PhotosUI
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage

struct EditProfileView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var displayName: String = ""
    @State private var selectedPreferences: Set<StyleGoal> = []
    @State private var preferredMode: String = "gen_z"
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var photoPreview: UIImage?
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let modes = [
        ("gen_z", "Gen Z", "🔥"),
        ("professional", "Professional", "💼"),
        ("date_night", "Date Night", "✨"),
        ("luxury", "Luxury", "💎"),
        ("campus", "Campus", "🎓")
    ]

    private let db = Firestore.firestore()

    var body: some View {
        NavigationStack {
            ZStack {
                Color.fcBackground.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 28) {
                        photoSection
                        nameSection
                        preferredModeSection
                        stylePrefsSection

                        if let error = errorMessage {
                            Text(error)
                                .font(.fcCaption)
                                .foregroundColor(.fcError)
                                .padding(.horizontal, 20)
                        }

                        Spacer(minLength: 40)
                    }
                    .padding(.top, 20)
                }
            }
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.fcTextSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView().tint(.fcAccent)
                    } else {
                        Button("Save") { Task { await saveProfile() } }
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.fcAccent)
                    }
                }
            }
        }
        .onAppear { loadCurrentValues() }
        .onChange(of: selectedPhoto) { _, newItem in
            Task { await loadSelectedPhoto(item: newItem) }
        }
    }

    // MARK: - Sections

    private var photoSection: some View {
        VStack(spacing: 12) {
            ZStack {
                if let img = photoPreview {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 90, height: 90)
                        .clipShape(Circle())
                } else {
                    Circle()
                        .fill(Color.fcAccent.opacity(0.15))
                        .frame(width: 90, height: 90)
                    Text(String(displayName.prefix(1).uppercased()))
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundColor(.fcAccent)
                }
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    ZStack {
                        Circle()
                            .fill(Color.fcBackground.opacity(0.7))
                            .frame(width: 30, height: 30)
                        Image(systemName: "camera.fill")
                            .font(.system(size: 13))
                            .foregroundColor(.fcTextPrimary)
                    }
                }
                .offset(x: 28, y: 28)
            }
            Text("Change Photo")
                .font(.fcCaption)
                .foregroundColor(.fcAccent)
        }
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Display Name")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.fcTextSecondary)
                .padding(.horizontal, 20)
            FCTextField(placeholder: "Your name", text: $displayName, icon: "person")
                .padding(.horizontal, 20)
        }
    }

    private var preferredModeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Preferred Fashion Mode")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.fcTextSecondary)
                .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(modes, id: \.0) { mode in
                        Button(action: { preferredMode = mode.0 }) {
                            HStack(spacing: 6) {
                                Text(mode.2)
                                Text(mode.1)
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .foregroundColor(preferredMode == mode.0 ? .fcBackground : .fcTextSecondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(preferredMode == mode.0 ? Color.fcAccent : Color.fcSurface)
                            .cornerRadius(20)
                        }
                        .buttonStyle(HapticButtonStyle(style: .light))
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private var stylePrefsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Style Preferences (pick up to 3)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.fcTextSecondary)
                .padding(.horizontal, 20)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(StyleGoal.allCases, id: \.self) { goal in
                    Button(action: { toggleGoal(goal) }) {
                        HStack(spacing: 8) {
                            Text(goal.emoji)
                                .font(.system(size: 18))
                            Text(goal.displayName)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(selectedPreferences.contains(goal) ? .fcBackground : .fcTextPrimary)
                            Spacer()
                            if selectedPreferences.contains(goal) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.fcBackground)
                            }
                        }
                        .padding(12)
                        .background(selectedPreferences.contains(goal) ? Color.fcAccent : Color.fcSurface)
                        .cornerRadius(12)
                    }
                    .buttonStyle(HapticButtonStyle(style: .light))
                }
            }
            .padding(.horizontal, 20)
        }
    }

    // MARK: - Actions

    private func toggleGoal(_ goal: StyleGoal) {
        if selectedPreferences.contains(goal) {
            selectedPreferences.remove(goal)
        } else if selectedPreferences.count < 3 {
            selectedPreferences.insert(goal)
        }
    }

    private func loadCurrentValues() {
        guard let user = appState.currentUser else { return }
        displayName = user.displayName ?? ""
        selectedPreferences = Set(user.stylePreferences.compactMap { StyleGoal(rawValue: $0) })
        preferredMode = user.defaultStyleGoal
    }

    private func loadSelectedPhoto(item: PhotosPickerItem?) async {
        guard let item else { return }
        if let data = try? await item.loadTransferable(type: Data.self),
           let image = UIImage(data: data) {
            await MainActor.run { photoPreview = image }
        }
    }

    private func saveProfile() async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        isSaving = true
        errorMessage = nil

        var updates: [String: Any] = [
            "displayName": displayName.trimmingCharacters(in: .whitespaces),
            "defaultStyleGoal": preferredMode,
            "stylePreferences": selectedPreferences.map { $0.rawValue }
        ]

        // Upload new photo if selected
        if let image = photoPreview, let jpeg = image.jpegData(compressionQuality: 0.8) {
            let path = "users/\(uid)/profile/avatar.jpg"
            let ref = Storage.storage().reference(withPath: path)
            let meta = StorageMetadata(); meta.contentType = "image/jpeg"
            if let _ = try? await ref.putDataAsync(jpeg, metadata: meta),
               let url = try? await ref.downloadURL() {
                updates["photoURL"] = url.absoluteString
                updates["avatarURL"] = url.absoluteString
            }
        }

        do {
            try await db.collection("users").document(uid).updateData(updates)
            await appState.refreshUser()
            await MainActor.run { isSaving = false; dismiss() }
        } catch {
            await MainActor.run {
                isSaving = false
                errorMessage = "Save failed. Please try again."
            }
        }
    }
}
