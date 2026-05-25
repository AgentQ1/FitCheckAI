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

    @State private var exportedJSON: String?
    @State private var showExportShare = false
    @State private var successMessage: String?

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
                                sublabel: "Removes all DALL-E generated outfit images",
                                iconColor: .fcWarning,
                                isLoading: isDeletingImages
                            ) { showDeleteImagesAlert = true }
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
            Text("Are you sure? This permanently deletes your account, all fit checks, and all data. This cannot be undone.")
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
    }

    // MARK: - Subviews

    private var infoSection: some View {
        VStack(spacing: 10) {
            infoCard(icon: "lock.shield.fill", text: "Your data is stored securely in Google Firebase with encryption at rest.")
            infoCard(icon: "eye.slash.fill", text: "Photos are sent to OpenAI only through our secure backend — never directly from your device.")
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
            await MainActor.run { isExporting = false }
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
            await MainActor.run { isDeletingFits = false }
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
            await MainActor.run { isDeletingImages = false }
        }
    }

    private func deleteAccount() async {
        guard let token = try? await Auth.auth().currentUser?.getIDToken() else { return }
        isDeletingAccount = true

        // Delegate all deletion to the Cloud Function (Admin SDK bypasses re-auth requirement)
        var req = URLRequest(url: URL(string: Config.API.deleteAccount)!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 60

        _ = try? await URLSession.shared.data(for: req)

        // Sign out regardless of response — the account may already be gone
        await appState.signOut()
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
