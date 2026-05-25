import SwiftUI

struct PrivacyView: View {
    @EnvironmentObject var appState: AppState
    @State private var retentionDays: Int = 7
    @State private var showDeleteAllAlert = false
    @State private var showDeleteConfirmation = false
    @State private var isDeleting = false

    private let retentionOptions: [(Int, String)] = [
        (0,  "After analysis (most private)"),
        (7,  "After 7 days (recommended)"),
        (30, "After 30 days"),
        (-1, "Keep forever")
    ]

    var body: some View {
        ZStack {
            Color.fcBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Info cards
                    VStack(spacing: 12) {
                        privacyInfoCard(
                            icon: "camera.fill",
                            title: "How we handle your photos",
                            body: "Photos are processed by AI and then deleted from our servers based on your retention setting. We never use your photos to train AI models without your explicit consent."
                        )
                        privacyInfoCard(
                            icon: "person.fill.xmark",
                            title: "No face data stored",
                            body: "We never store or process facial recognition data. Face analysis is never performed — only your outfit is evaluated."
                        )
                        privacyInfoCard(
                            icon: "lock.shield.fill",
                            title: "Your data stays yours",
                            body: "We never sell your photos or personal data to third parties, brands, or retailers."
                        )
                    }
                    .padding(.horizontal, 20)

                    // Retention picker
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Photo Retention")
                            .font(.fcBodyBold)
                            .foregroundColor(.fcTextPrimary)

                        VStack(spacing: 8) {
                            ForEach(retentionOptions, id: \.0) { option in
                                Button(action: { retentionDays = option.0 }) {
                                    HStack(spacing: 12) {
                                        ZStack {
                                            Circle()
                                                .stroke(retentionDays == option.0 ? Color.fcAccent : Color.fcTextSecondary.opacity(0.3), lineWidth: 2)
                                                .frame(width: 20, height: 20)
                                            if retentionDays == option.0 {
                                                Circle()
                                                    .fill(Color.fcAccent)
                                                    .frame(width: 12, height: 12)
                                            }
                                        }
                                        Text(option.1)
                                            .font(.fcBody)
                                            .foregroundColor(retentionDays == option.0 ? .fcTextPrimary : .fcTextSecondary)
                                        Spacer()
                                    }
                                    .padding(14)
                                    .background(retentionDays == option.0 ? Color.fcAccent.opacity(0.08) : Color.fcSurface)
                                    .cornerRadius(12)
                                }
                                .buttonStyle(HapticButtonStyle(style: .light))
                            }
                        }
                    }
                    .padding(.horizontal, 20)

                    // Danger zone
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Danger Zone")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.fcError)

                        VStack(alignment: .leading, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Delete All My Photos")
                                    .font(.fcBodyBold)
                                    .foregroundColor(.fcTextPrimary)
                                Text("Permanently removes all outfit photos from FitCheck servers. This cannot be undone.")
                                    .font(.fcCaption)
                                    .foregroundColor(.fcTextSecondary)
                            }
                            Button(action: { showDeleteAllAlert = true }) {
                                HStack {
                                    if isDeleting {
                                        ProgressView().tint(.white)
                                    } else {
                                        Image(systemName: "trash.fill")
                                        Text("Delete All Photos")
                                    }
                                }
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.fcError)
                                .cornerRadius(12)
                            }
                            .disabled(isDeleting)
                        }
                        .padding(16)
                        .background(Color.fcError.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.fcError.opacity(0.3), lineWidth: 1)
                        )
                        .cornerRadius(16)
                    }
                    .padding(.horizontal, 20)

                    Spacer(minLength: 80)
                }
                .padding(.top, 16)
            }
        }
        .navigationTitle("Your Privacy 🔒")
        .navigationBarTitleDisplayMode(.large)
        .alert("Delete All Photos?", isPresented: $showDeleteAllAlert) {
            Button("Yes, Delete Everything", role: .destructive) {
                deleteAllPhotos()
            }
            Button("Keep My Photos", role: .cancel) {}
        } message: {
            Text("This permanently removes all outfit photos from FitCheck servers. Your analysis scores will be kept but photos will be gone forever.")
        }
        .onAppear {
            retentionDays = appState.currentUser?.photoRetentionDays ?? 7
            appState.analyticsService.track(.deletePhotoTapped)
        }
    }

    private func privacyInfoCard(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.fcAccent)
                .font(.system(size: 18))
                .frame(width: 24)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.fcTextPrimary)
                Text(body)
                    .font(.system(size: 13))
                    .foregroundColor(.fcTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(Color.fcSurface)
        .cornerRadius(14)
    }

    private func deleteAllPhotos() {
        isDeleting = true
        // In real build: call delete-all endpoint
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            isDeleting = false
        }
    }
}
