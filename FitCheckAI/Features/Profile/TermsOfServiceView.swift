import SwiftUI

struct TermsOfServiceView: View {
    var body: some View {
        ZStack {
            Color.fcBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Last updated: May 2026")
                        .font(.fcCaption)
                        .foregroundColor(.fcTextSecondary)

                    tosSection(title: "1. Acceptance of Terms") {
                        "By downloading or using FitCheck AI, you agree to be bound by these Terms of Service. If you do not agree, please do not use the app."
                    }

                    tosSection(title: "2. Use of Service") {
                        "FitCheck AI provides AI-powered outfit analysis for personal, non-commercial use. You may not use the service to generate harmful, offensive, or deceptive content. You must be 13 years or older to use this service."
                    }

                    tosSection(title: "3. AI Analysis Disclaimer") {
                        "The AI outfit scores and suggestions are generated automatically and are intended for entertainment and style inspiration only. FitCheck AI does not guarantee the accuracy of any analysis. Results may vary based on photo quality and lighting conditions."
                    }

                    tosSection(title: "4. User Content") {
                        "You retain ownership of photos you upload. By uploading, you grant FitCheck AI a temporary license to process the image for AI analysis. Photos are handled according to our Privacy Policy and your selected retention settings."
                    }

                    tosSection(title: "5. Premium Subscription") {
                        "Premium features are available through a paid subscription billed monthly or annually. Subscriptions automatically renew unless cancelled at least 24 hours before the renewal date. Manage subscriptions in your device's App Store settings."
                    }

                    tosSection(title: "6. Prohibited Conduct") {
                        "You may not attempt to reverse engineer the app, scrape data, use automated tools to interact with the service, or upload content that violates the rights of others or applicable laws."
                    }

                    tosSection(title: "7. Termination") {
                        "We reserve the right to suspend or terminate accounts that violate these terms. You may delete your account at any time through the Privacy & Data Settings in your profile."
                    }

                    tosSection(title: "8. Limitation of Liability") {
                        "FitCheck AI is provided 'as is' without warranties of any kind. We are not liable for any indirect, incidental, or consequential damages arising from use of the service."
                    }

                    tosSection(title: "9. Changes to Terms") {
                        "We may update these terms from time to time. Continued use of the app after changes constitutes acceptance of the updated terms."
                    }

                    tosSection(title: "10. Contact") {
                        "Questions about these terms? Contact us at support@fitcheckai.app"
                    }

                    Spacer(minLength: 60)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
            }
        }
        .navigationTitle("Terms of Service")
        .navigationBarTitleDisplayMode(.large)
    }

    private func tosSection(title: String, content: () -> String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.fcTextPrimary)
            Text(content())
                .font(.fcBody)
                .foregroundColor(.fcTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(Color.fcSurface)
        .cornerRadius(14)
    }
}
