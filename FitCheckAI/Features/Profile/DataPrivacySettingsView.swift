import SwiftUI
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage

struct DataPrivacySettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var showExportAlert = false
    @State private var showDeleteFitsAlert = false
    @State private var showDeleteImagesAlert = false
    @State private var showDeleteAccountAlert = false
    @State private var showDeleteAccountConfirm = false
    @State private var showSignOutAlert = false

    @State private var isExporting = false
    @State private var isDeletingFits = false
    @State private var isDeletingImages = false
    @State private var isDeletingAccount = false

    /// Public Arena/leaderboard participation. Mirrors `users/{uid}.isPublic`
    /// (default on); the backend only publishes fits when this is not false.
    @State private var isPublicArena = true
    @State private var isSavingVisibility = false

    @State private var exportedJSON: String?
    @State private var showExportShare = false
    @State private var successMessage: String?
    @State private var errorMessage: String?
    @State private var showToS = false
    @State private var showPrivacyPolicy = false

    private let db = Firestore.firestore()

    var body: some View {
        ZStack {
            Color.fcBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Privacy info cards
                    infoSection

                    // Data actions
                    sectionCard(title: "Your Data") {
                        VStack(spacing: 0) {
                            actionRow(
                                icon: "square.and.arrow.up.fill",
                                label: "Export My Data as JSON",
                                sublabel: "Download everything: profile, scores, saved looks",
                                iconColor: .fcAccent,
                                isLoading: isExporting
                            ) { showExportAlert = true }

                            Divider().background(Color.fcTextSecondary.opacity(0.15))

                            actionRow(
                                icon: "trash.fill",
                                label: "Delete All Fit Checks",
                                sublabel: "Removes all outfit analysis history",
                                iconColor: .fcWarning,
                                isLoading: isDeletingFits
                            ) { showDeleteFitsAlert = true }

                            Divider().background(Color.fcTextSecondary.opacity(0.15))

                            actionRow(
                                icon: "photo.slash.fill",
                                label: "Delete Generated Images",
                                sublabel: "Removes all AI-generated outfit images",
                                iconColor: .fcWarning,
                                isLoading: isDeletingImages
                            ) { showDeleteImagesAlert = true }
                        }
                    }

                    // Public visibility — explicit control over Arena/leaderboard participation
                    sectionCard(title: "Public Visibility") {
                        VStack(spacing: 0) {
                            Toggle(isOn: Binding(
                                get: { isPublicArena },
                                set: { newValue in
                                    isPublicArena = newValue
                                    Task { await saveVisibility(newValue) }
                                }
                            )) {
                                HStack(spacing: 12) {
                                    Image(systemName: "flame.fill")
                                        .foregroundColor(.fcAccent)
                                        .frame(width: 20)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Show my fits in the Arena")
                                            .font(.fcBody)
                                            .foregroundColor(.fcTextPrimary)
                                        Text("When on, your top-scoring fits can appear publicly in the Arena and leaderboards — your name, avatar, outfit photo, and AI score become visible to other users. Turn off to keep everything private.")
                                            .font(.system(size: 12))
                                            .foregroundColor(.fcTextSecondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                            .tint(.fcAccent)
                            .disabled(isSavingVisibility)
                            .padding(.vertical, 14)
                            .padding(.horizontal, 16)
                        }
                    }

                    // Permissions & legal
                    sectionCard(title: "Privacy & Legal") {
                        VStack(spacing: 0) {
                            actionRow(
                                icon: "camera.fill",
                                label: "Manage Photo Permissions",
                                sublabel: "Open iOS Settings to change camera & photo access",
                                iconColor: .fcAccent,
                                isLoading: false
                            ) { openSystemSettings() }

                            Divider().background(Color.fcTextSecondary.opacity(0.15))

                            actionRow(
                                icon: "hand.raised.fill",
                                label: "Privacy Policy",
                                sublabel: "How we collect, use, and protect your data",
                                iconColor: .fcAccent,
                                isLoading: false
                            ) { showPrivacyPolicy = true }

                            Divider().background(Color.fcTextSecondary.opacity(0.15))

                            actionRow(
                                icon: "doc.text.fill",
                                label: "Terms of Service",
                                sublabel: "The terms you agree to by using FitCheck",
                                iconColor: .fcAccent,
                                isLoading: false
                            ) { showToS = true }
                        }
                    }

                    if let msg = successMessage {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.fcSuccess)
                            Text(msg)
                                .font(.fcCaption)
                                .foregroundColor(.fcSuccess)
                        }
                        .padding(14)
                        .background(Color.fcSuccess.opacity(0.1))
                        .cornerRadius(12)
                        .padding(.horizontal, 20)
                    }

                    // Danger zone
                    sectionCard(title: "⚠️ Danger Zone") {
                        VStack(spacing: 0) {
                            actionRow(
                                icon: "rectangle.portrait.and.arrow.right",
                                label: "Sign Out",
                                sublabel: "You can sign back in at any time",
                                iconColor: .fcTextSecondary,
                                isLoading: false
                            ) { showSignOutAlert = true }

                            Divider().background(Color.fcTextSecondary.opacity(0.15))

                            actionRow(
                                icon: "person.crop.circle.badge.xmark",
                                label: "Delete Account",
                                sublabel: "Permanently delete account and all data",
                                iconColor: .fcError,
                                isLoading: isDeletingAccount
                            ) { showDeleteAccountAlert = true }
                        }
                    }

                    Spacer(minLength: 60)
                }
                .padding(.top, 16)
            }
        }
        .navigationTitle("Privacy & Data")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(isPresented: $showToS) { TermsOfServiceView() }
        .navigationDestination(isPresented: $showPrivacyPolicy) { PrivacyPolicyView() }
        // Hide the floating tab bar while this pushed detail screen is up so it
        // doesn't overlap the bottom content.
        .onAppear {
            appState.hideTabBar = true
            isPublicArena = appState.currentUser?.isArenaPublic ?? true
        }
        .onDisappear { appState.hideTabBar = false }
        .sheet(isPresented: $showExportShare) {
            if let json = exportedJSON,
               let url = writeJSONToTmp(json: json) {
                ShareSheet(items: [url])
            }
        }
        .alert("Export Your Data?", isPresented: $showExportAlert) {
            Button("Export") { Task { await exportData() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Downloads all your profile data, fit checks, and saved looks as a JSON file.")
        }
        .alert("Delete All Fit Checks?", isPresented: $showDeleteFitsAlert) {
            Button("Delete All", role: .destructive) { Task { await deleteAllFitChecks() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all outfit analysis history. Your account and profile will remain.")
        }
        .alert("Delete Generated Images?", isPresented: $showDeleteImagesAlert) {
            Button("Delete Images", role: .destructive) { Task { await deleteGeneratedImages() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all AI-generated outfit images from storage.")
        }
        .alert("Delete Account?", isPresented: $showDeleteAccountAlert) {
            Button("Yes, Delete My Account", role: .destructive) { showDeleteAccountConfirm = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes your profile, outfit checks, uploaded photos, AI analysis & feedback, history, and account. This cannot be undone.")
        }
        .alert("Final Confirmation", isPresented: $showDeleteAccountConfirm) {
            Button("Delete Forever", role: .destructive) { Task { await deleteAccount() } }
            Button("Keep My Account", role: .cancel) {}
        } message: {
            Text("Your account and all associated data will be permanently deleted. This is irreversible.")
        }
        .alert("Sign Out", isPresented: $showSignOutAlert) {
            Button("Sign Out", role: .destructive) {
                Task { await appState.signOut() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to sign out?")
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - Subviews

    private var infoSection: some View {
        VStack(spacing: 10) {
            infoCard(icon: "lock.shield.fill", text: "Your data is stored securely in Google Firebase with encryption at rest.")
            infoCard(icon: "eye.slash.fill", text: "Photos are sent to our AI providers (OpenAI for scoring, Google Gemini for outfit upgrades) only through our secure backend — never directly from your device.")
            infoCard(icon: "hand.raised.fill", text: "We never sell your data to third parties, advertisers, or brands.")
        }
        .padding(.horizontal, 20)
    }

    private func infoCard(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(.fcAccent)
                .frame(width: 20)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(.fcTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.fcSurface)
        .cornerRadius(12)
        .shadow(color: Color.fcShadow, radius: 8, y: 3)
    }

    private func sectionCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.fcTextSecondary)
                .padding(.horizontal, 20)
            content()
                .background(Color.fcSurface)
                .cornerRadius(16)
                .shadow(color: Color.fcShadow, radius: 10, y: 4)
        }
        .padding(.horizontal, 20)
    }

    private func actionRow(icon: String, label: String, sublabel: String, iconColor: Color, isLoading: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundColor(iconColor)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.fcBody)
                        .foregroundColor(.fcTextPrimary)
                    Text(sublabel)
                        .font(.system(size: 12))
                        .foregroundColor(.fcTextSecondary)
                }
                Spacer()
                if isLoading {
                    ProgressView().tint(.fcAccent).scaleEffect(0.8)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12))
                        .foregroundColor(.fcTextSecondary)
                }
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
        }
        .disabled(isLoading)
    }

    // MARK: - Actions

    private func exportData() async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        isExporting = true

        var exportData: [String: Any] = [:]

        // User profile
        if let userSnap = try? await db.collection("users").document(uid).getDocument() {
            exportData["profile"] = userSnap.data() ?? [:]
        }

        // Fit checks
        if let fitSnap = try? await db.collection("users/\(uid)/fit_checks").getDocuments() {
            exportData["fit_checks"] = fitSnap.documents.map { $0.data() }
        }

        // Saved looks
        if let savedSnap = try? await db.collection("users/\(uid)/saved_looks").getDocuments() {
            exportData["saved_looks"] = savedSnap.documents.map { $0.data() }
        }

        exportData["exported_at"] = ISO8601DateFormatter().string(from: Date())

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: exportData, options: .prettyPrinted)
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
            await MainActor.run {
                exportedJSON = jsonString
                isExporting = false
                showExportShare = true
            }
        } catch {
            await MainActor.run {
                isExporting = false
                errorMessage = "Couldn't export your data. Please try again."
            }
        }
    }

    /// Persist the Arena/leaderboard visibility choice to the user's Firestore doc.
    /// `isPublic` isn't a protected field, so the client may write it under the
    /// security rules; the Arena/leaderboard backend reads it on the next recompute.
    private func saveVisibility(_ isPublic: Bool) async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        isSavingVisibility = true
        defer { isSavingVisibility = false }
        do {
            try await db.collection("users").document(uid).setData(["isPublic": isPublic], merge: true)
            await appState.refreshUser()
            successMessage = isPublic
                ? "Your fits can now appear in the public Arena."
                : "Your fits are now private and won't appear publicly."
        } catch {
            // Revert the toggle on failure so the UI reflects the true state.
            isPublicArena = !isPublic
            errorMessage = "Couldn't update your visibility setting. Please try again."
        }
    }

    private func deleteAllFitChecks() async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        isDeletingFits = true

        do {
            let snapshot = try await db.collection("users/\(uid)/fit_checks").getDocuments()
            let batch = db.batch()
            for doc in snapshot.documents {
                batch.updateData(["isDeleted": true], forDocument: doc.reference)
            }
            try await batch.commit()
            try? await db.collection("users").document(uid).updateData([
                "totalFitChecks": 0,
                "averageScore": 0.0,
                "bestScore": 0.0
            ])
            await appState.refreshUser()
            await MainActor.run {
                isDeletingFits = false
                successMessage = "All fit checks deleted."
            }
        } catch {
            await MainActor.run {
                isDeletingFits = false
                errorMessage = "Couldn't delete your fit checks. Please try again."
            }
        }
    }

    private func deleteGeneratedImages() async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        isDeletingImages = true

        let storage = Storage.storage()
        do {
            let result = try await storage.reference()
                .child("users/\(uid)/fit-checks")
                .listAll()
            // List generated subdirectories
            for prefix in result.prefixes {
                let genPath = prefix.fullPath + "/generated"
                if let genResult = try? await storage.reference().child(genPath).listAll() {
                    for file in genResult.items {
                        try? await file.delete()
                    }
                }
            }
            await MainActor.run {
                isDeletingImages = false
                successMessage = "Generated images deleted."
            }
        } catch {
            await MainActor.run {
                isDeletingImages = false
                errorMessage = "Couldn't delete generated images. Please try again."
            }
        }
    }

    private func deleteAccount() async {
        guard let token = try? await Auth.auth().currentUser?.getIDToken() else {
            errorMessage = "You need to be signed in to delete your account."
            return
        }
        isDeletingAccount = true

        // Delegate all deletion to the Cloud Function (Admin SDK bypasses the
        // re-auth requirement and removes Auth + Firestore + Storage atomically).
        var req = URLRequest(url: URL(string: Config.API.deleteAccount)!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 60

        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                await MainActor.run {
                    isDeletingAccount = false
                    errorMessage = "We couldn't delete your account (HTTP \(status)). Please try again or contact \(Config.supportEmail)."
                }
                return
            }
            // Success — sign the (now-deleted) user out and return to onboarding.
            await appState.signOut()
        } catch {
            await MainActor.run {
                isDeletingAccount = false
                errorMessage = "Network error deleting your account. Please try again."
            }
        }
    }

    private func writeJSONToTmp(json: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fitcheck_data.json")
        try? json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
