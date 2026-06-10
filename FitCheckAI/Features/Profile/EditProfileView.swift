import SwiftUI
import PhotosUI
import UIKit
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
    @State private var photoPreview: UIImage?      // the cropped image awaiting save
    @State private var cropCandidate: UIImage?     // raw pick awaiting crop
    @State private var showCrop = false
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
        .fullScreenCover(isPresented: $showCrop) {
            if let candidate = cropCandidate {
                AvatarCropView(image: candidate) { cropped in
                    photoPreview = cropped
                    finishCrop()
                } onCancel: {
                    finishCrop()
                }
            }
        }
    }

    // MARK: - Sections

    private var photoSection: some View {
        VStack(spacing: 12) {
            ZStack {
                avatarPreview
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

    /// Newly-cropped pick wins; otherwise show the saved remote avatar so the
    /// editor reflects the user's actual current photo, falling back to initials.
    @ViewBuilder
    private var avatarPreview: some View {
        if let img = photoPreview {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .frame(width: 90, height: 90)
                .clipShape(Circle())
        } else if let urlString = appState.currentUser?.photoURL, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    initialsCircle
                }
            }
            .frame(width: 90, height: 90)
            .clipShape(Circle())
        } else {
            initialsCircle
        }
    }

    private var initialsCircle: some View {
        ZStack {
            Circle()
                .fill(Color.fcAccent.opacity(0.15))
                .frame(width: 90, height: 90)
            Text(String(displayName.prefix(1).uppercased()))
                .font(.system(size: 36, weight: .bold, design: .rounded))
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
            // Hand the raw pick to the crop editor instead of using it directly.
            await MainActor.run {
                cropCandidate = image
                showCrop = true
            }
        }
    }

    private func finishCrop() {
        showCrop = false
        cropCandidate = nil
        selectedPhoto = nil   // reset so re-picking the same photo retriggers onChange
    }

    private func saveProfile() async {
        guard let firebaseUser = Auth.auth().currentUser else { return }
        let uid = firebaseUser.uid

        let oldPhotoURL = await MainActor.run { () -> String in
            isSaving = true
            errorMessage = nil
            return appState.currentUser?.photoURL ?? "<nil>"
        }

        let trimmedName = displayName.trimmingCharacters(in: .whitespaces)
        // Single timestamp shared by the storage URL cache-buster and the
        // profileImageUpdatedAt field, so they always agree.
        let photoVersion = Int(Date().timeIntervalSince1970 * 1000)
        print("[EditProfile] save start uid=\(uid) oldPhotoURL=\(oldPhotoURL) newName=\(trimmedName)")

        var updates: [String: Any] = [
            "displayName": trimmedName,
            "defaultStyleGoal": preferredMode,
            "stylePreferences": selectedPreferences.map { $0.rawValue }
        ]

        // Upload a newly-picked photo, if any. A failure here is surfaced to the
        // user rather than silently dropped (the old code swallowed it and saved
        // the rest, so the photo just "didn't take" with no explanation).
        var newPhotoURL: String?
        if let image = photoPreview {
            do {
                newPhotoURL = try await uploadProfilePhoto(image, uid: uid, version: photoVersion)
                updates["photoURL"] = newPhotoURL
                updates["avatarURL"] = newPhotoURL
                updates["profileImageUpdatedAt"] = photoVersion
                print("[EditProfile] uploaded photo downloadURL=\(newPhotoURL ?? "<nil>")")
            } catch {
                print("[EditProfile] photo upload failed: \(error)")
                await MainActor.run {
                    isSaving = false
                    errorMessage = "Couldn't upload photo. Check your connection and try again."
                }
                return
            }
        }

        do {
            // 1. Persist to Firestore — the source of truth the app reads on launch.
            try await db.collection("users").document(uid).updateData(updates)
            print("[EditProfile] firestore saved: \(updates)")

            // 2. Keep Firebase Auth's profile in sync. Without this, the next login
            //    re-runs upsertFirestoreUser, which would resurrect the provider's
            //    original name/photo over the user's edits.
            let change = firebaseUser.createProfileChangeRequest()
            change.displayName = trimmedName
            if let newPhotoURL, let url = URL(string: newPhotoURL) {
                change.photoURL = url
            }
            try await change.commitChanges()

            // 3. Mirror the public fields so leaderboards show the fresh name/photo
            //    for everyone (clients can't read each other's users/{uid} doc).
            //    photoURL stays nil on a name-only edit → merge keeps the old photo.
            await PublicProfileService.write(
                uid: uid,
                displayName: trimmedName,
                photoURL: newPhotoURL,
                profileImageUpdatedAt: newPhotoURL != nil ? photoVersion : nil
            )

            // 4. Refetch from Firestore so in-memory state matches what's stored
            //    (also instantly updates the current user's own leaderboard row).
            await appState.refreshUser()
            await MainActor.run { isSaving = false; dismiss() }
        } catch {
            print("[EditProfile] save failed: \(error)")
            await MainActor.run {
                isSaving = false
                errorMessage = "Save failed. Please try again."
            }
        }
    }

    /// Uploads `image` to the user's avatar path and returns a cache-busted
    /// download URL. The `&v=<timestamp>` suffix forces AsyncImage / URLSession to
    /// refetch instead of serving the previously cached avatar after a photo swap.
    private func uploadProfilePhoto(_ image: UIImage, uid: String, version: Int) async throws -> String {
        guard let jpeg = image.jpegData(compressionQuality: 0.8) else {
            throw NSError(domain: "EditProfile", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not encode image."])
        }
        let ref = Storage.storage().reference(withPath: "users/\(uid)/profile/avatar.jpg")
        let meta = StorageMetadata(); meta.contentType = "image/jpeg"
        _ = try await ref.putDataAsync(jpeg, metadata: meta)
        let base = try await ref.downloadURL().absoluteString
        return base.contains("?") ? "\(base)&v=\(version)" : "\(base)?v=\(version)"
    }
}

// MARK: - Avatar Crop Editor

/// Full-screen circular-mask cropper. The user pinches to zoom and drags to
/// reposition a freshly-picked photo; `onApply` receives a square 1024×1024
/// render of exactly what's framed inside the circle (all avatar views clip to
/// a circle, so a square image is correct). `onCancel` discards the pick.
struct AvatarCropView: View {
    let image: UIImage
    let onApply: (UIImage) -> Void
    let onCancel: () -> Void

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private let outputSize: CGFloat = 1024
    private let minScale: CGFloat = 1
    private let maxScale: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            let cropDiameter = min(geo.size.width, geo.size.height) - 48
            let base = baseSize(for: cropDiameter)

            ZStack {
                Color.black.ignoresSafeArea()

                Image(uiImage: image)
                    .resizable()
                    .frame(width: base.width, height: base.height)
                    .scaleEffect(scale)
                    .offset(offset)

                dimOverlay(cropDiameter: cropDiameter)

                Circle()
                    .stroke(Color.white.opacity(0.9), lineWidth: 2)
                    .frame(width: cropDiameter, height: cropDiameter)
                    .allowsHitTesting(false)

                // Transparent catcher: handles pan/zoom in the open area while the
                // control bars below stay tappable (they sit above this layer).
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(dragGesture(base: base, cropDiameter: cropDiameter))
                    .simultaneousGesture(magnifyGesture(base: base, cropDiameter: cropDiameter))

                VStack {
                    topBar
                    Spacer()
                    bottomBar(base: base, cropDiameter: cropDiameter)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private var topBar: some View {
        HStack {
            Button("Cancel") { onCancel() }
            Spacer()
            Button("Reset") { reset() }
        }
        .font(.system(size: 16, weight: .semibold))
        .foregroundColor(.white)
        .padding(.horizontal, 20)
        .padding(.top, 20)
    }

    private func bottomBar(base: CGSize, cropDiameter: CGFloat) -> some View {
        VStack(spacing: 10) {
            Text("Pinch to zoom · drag to reposition")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.7))
            Button(action: { onApply(renderCrop(base: base, cropDiameter: cropDiameter)) }) {
                Text("Apply")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.fcBackground)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.fcAccent)
                    .cornerRadius(16)
            }
            .padding(.horizontal, 24)
        }
        .padding(.bottom, 40)
    }

    private func dimOverlay(cropDiameter: CGFloat) -> some View {
        Rectangle()
            .fill(Color.black.opacity(0.55))
            .mask(
                ZStack {
                    Rectangle()
                    Circle()
                        .frame(width: cropDiameter, height: cropDiameter)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }

    // MARK: - Gestures

    private func dragGesture(base: CGSize, cropDiameter: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(width: lastOffset.width + value.translation.width,
                                height: lastOffset.height + value.translation.height)
            }
            .onEnded { _ in
                offset = clampedOffset(offset, base: base, cropDiameter: cropDiameter)
                lastOffset = offset
            }
    }

    private func magnifyGesture(base: CGSize, cropDiameter: CGFloat) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(max(lastScale * value.magnification, minScale), maxScale)
            }
            .onEnded { _ in
                lastScale = scale
                offset = clampedOffset(offset, base: base, cropDiameter: cropDiameter)
                lastOffset = offset
            }
    }

    // MARK: - Layout / crop math

    /// Size at which the image fills the crop circle at scale 1 (aspect-fill).
    private func baseSize(for cropDiameter: CGFloat) -> CGSize {
        let aspect = image.size.width / max(image.size.height, 1)
        return aspect >= 1
            ? CGSize(width: cropDiameter * aspect, height: cropDiameter)
            : CGSize(width: cropDiameter, height: cropDiameter / aspect)
    }

    /// Keeps the image covering the crop square (no empty gaps inside the circle).
    private func clampedOffset(_ offset: CGSize, base: CGSize, cropDiameter: CGFloat) -> CGSize {
        let displayedW = base.width * scale
        let displayedH = base.height * scale
        let maxX = max(0, (displayedW - cropDiameter) / 2)
        let maxY = max(0, (displayedH - cropDiameter) / 2)
        return CGSize(width: min(max(offset.width, -maxX), maxX),
                      height: min(max(offset.height, -maxY), maxY))
    }

    private func reset() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero
        }
    }

    /// Renders the framed region to a square image. The on-screen image is
    /// centered at (cropCenter + offset) and sized base×scale, so we map that
    /// same geometry into the output canvas scaled by outputSize / cropDiameter.
    private func renderCrop(base: CGSize, cropDiameter: CGFloat) -> UIImage {
        let k = outputSize / cropDiameter
        let displayed = CGSize(width: base.width * scale, height: base.height * scale)
        let topLeft = CGPoint(x: cropDiameter / 2 + offset.width - displayed.width / 2,
                              y: cropDiameter / 2 + offset.height - displayed.height / 2)
        let drawRect = CGRect(x: topLeft.x * k, y: topLeft.y * k,
                              width: displayed.width * k, height: displayed.height * k)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: outputSize, height: outputSize), format: format)
        return renderer.image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: outputSize, height: outputSize))
            image.draw(in: drawRect)
        }
    }
}
