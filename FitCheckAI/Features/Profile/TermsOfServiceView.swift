import SwiftUI

struct TermsOfServiceView: View {
    var body: some View {
        ZStack {
            Color.fcBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Last updated: June 2026")
                        .font(.fcCaption)
                        .foregroundColor(.fcTextSecondary)

                    tosSection(title: "1. Acceptance of Terms") {
                        "By downloading or using FitCheck, you agree to be bound by these Terms of Service. If you do not agree, please do not use the app. You must be 13 years or older to use FitCheck."
                    }

                    tosSection(title: "2. What FitCheck Is") {
                        "FitCheck provides AI-generated style and fashion feedback on outfit photos you upload, for personal, non-commercial use. It is a styling and entertainment tool."
                    }

                    tosSection(title: "3. AI Feedback Is Subjective") {
                        "Outfit scores, style lenses, and suggestions are generated automatically and are subjective opinions intended for entertainment and style guidance only. They are NOT professional, medical, legal, financial, dietary, or body-image advice, and should not be relied on as such. FitCheck does not guarantee the accuracy of any analysis; results vary with photo quality and lighting."
                    }

                    tosSection(title: "4. Your Photos & Content") {
                        "You must own, or have the rights to use, every photo you upload. You retain ownership of your photos. By uploading, you grant FitCheck a limited license to process and store the image solely to operate the app — to analyze it, generate feedback and upgrades, and show it back to you in your history. We do not use this license for anything beyond running the service. Photos are handled per our Privacy Policy and your retention settings."
                    }

                    tosSection(title: "5. Acceptable Use") {
                        "You may not upload content that is abusive, harassing, sexually explicit, hateful, illegal, or that depicts other people without their consent, and you may not reverse-engineer, scrape, or abuse the service. We may remove content or suspend accounts that violate these terms."
                    }

                    tosSection(title: "6. Community Features & Moderation") {
                        "FitCheck includes public community features (the Arena and leaderboards). When public visibility is enabled, your top-scoring fits — including your display name, avatar, outfit photo, and AI score — may be shown to other users, who can vote and leave outfit-focused comments. You can turn public visibility off at any time in Profile → Privacy & Data Settings, and you can delete any fit. There is no tolerance for objectionable content or abusive behavior: you can report any fit and block any user from inside the app, and we remove flagged content and may suspend offending accounts. By using the community features you agree to this policy."
                    }

                    tosSection(title: "7. Premium Subscription") {
                        "FitCheck Premium unlocks unlimited outfit checks and all 8 style lenses. Premium is an auto-renewable subscription sold through Apple In-App Purchase. Payment is charged to your Apple ID at confirmation. The subscription renews automatically for the same period and price unless you cancel at least 24 hours before the current period ends. Manage or cancel your subscription anytime in your Apple App Store account settings. Any unused portion of a free trial is forfeited when you purchase a subscription. Refunds, where applicable, are handled by Apple under Apple's Media Services terms — FitCheck cannot issue App Store refunds directly."
                    }

                    tosSection(title: "8. Account & Data Deletion") {
                        "You can delete your account at any time from Profile → Privacy & Data Settings → Delete Account. Deleting your account permanently removes your profile, outfit checks, uploaded photos, AI analysis, and history from our systems. Deleting your FitCheck account does not cancel an active subscription — cancel it separately in your Apple App Store settings."
                    }

                    tosSection(title: "9. Disclaimer & Limitation of Liability") {
                        "FitCheck is provided 'as is' and 'as available' without warranties of any kind. To the maximum extent permitted by law, FitCheck and its operators are not liable for any indirect, incidental, special, or consequential damages, or for any styling decisions you make based on the app."
                    }

                    tosSection(title: "10. Changes to These Terms") {
                        "We may update these terms from time to time. Continued use of the app after changes take effect constitutes acceptance of the updated terms."
                    }

                    tosSection(title: "11. Contact") {
                        "Questions about these terms? Contact us at \(Config.supportEmail)."
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 110) // clear the floating tab bar when pushed in a tab
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
