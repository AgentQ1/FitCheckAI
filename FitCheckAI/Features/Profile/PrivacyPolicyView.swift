import SwiftUI

struct PrivacyPolicyView: View {
    var body: some View {
        ZStack {
            Color.fcBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Last updated: May 2026")
                        .font(.fcCaption)
                        .foregroundColor(.fcTextSecondary)

                    policySection(
                        icon: "camera.fill",
                        title: "Photos & AI Analysis",
                        body: "Photos you upload are used solely for AI outfit analysis. Images are sent to OpenAI's API through our secure Firebase backend — your device never communicates directly with OpenAI. We do not store photos longer than your selected retention period (default: 7 days after analysis)."
                    )

                    policySection(
                        icon: "server.rack",
                        title: "Data Storage",
                        body: "All data — including your profile, outfit scores, and saved looks — is stored in Google Firebase (Firestore and Cloud Storage). Firebase is hosted in Google Cloud data centers with industry-standard security and encryption at rest and in transit."
                    )

                    policySection(
                        icon: "person.fill.xmark",
                        title: "No Face Data",
                        body: "FitCheck AI does not perform facial recognition. Our AI models analyze clothing, colors, fit, and style — never your face or biometric data. No face data is ever stored or processed."
                    )

                    policySection(
                        icon: "hand.raised.fill",
                        title: "Your Rights",
                        body: "You can export all your data as JSON, delete individual fit checks, delete all generated images, or permanently delete your account — all from the Privacy & Data Settings in your profile. Deleting your account removes all stored data from our systems within 30 days."
                    )

                    policySection(
                        icon: "dollarsign.circle.fill",
                        title: "No Data Selling",
                        body: "We do not sell, rent, or share your personal data, photos, or outfit analysis results with advertisers, brands, retailers, or third parties. Your data is used only to provide and improve the FitCheck AI service."
                    )

                    policySection(
                        icon: "chart.bar.fill",
                        title: "Analytics",
                        body: "We collect anonymized usage data (screen views, feature usage, error rates) to improve the app. This data cannot be linked to your identity. You can opt out of analytics in your device settings."
                    )

                    policySection(
                        icon: "envelope.fill",
                        title: "Contact",
                        body: "For privacy questions or data requests, contact us at privacy@fitcheckai.app. We respond to all privacy inquiries within 7 business days."
                    )

                    Spacer(minLength: 60)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
            }
        }
        .navigationTitle("Privacy Policy")
        .navigationBarTitleDisplayMode(.large)
    }

    private func policySection(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.fcAccent.opacity(0.12))
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(.fcAccent)
            }
            .padding(.top, 4)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.fcTextPrimary)
                Text(body)
                    .font(.fcBody)
                    .foregroundColor(.fcTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(Color.fcSurface)
        .cornerRadius(14)
    }
}
