import SwiftUI

struct PrivacyPolicyView: View {
    var body: some View {
        ZStack {
            Color.fcBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Last updated: June 2026")
                        .font(.fcCaption)
                        .foregroundColor(.fcTextSecondary)

                    policySection(
                        icon: "person.text.rectangle.fill",
                        title: "Information We Collect",
                        body: "• Account info: your name, email, and profile photo.\n• Outfit photos you upload for analysis.\n• AI results: style scores, lens breakdowns, and feedback generated for your outfits.\n• Subscription status: whether you have Premium (we never see your card number — Apple handles payment)."
                    )

                    policySection(
                        icon: "target",
                        title: "How We Use Your Data",
                        body: "We use your data to analyze your outfits, track your style history and progress, manage your account, provide Premium subscription access, and improve the app. We do not use it for third-party advertising."
                    )

                    policySection(
                        icon: "camera.fill",
                        title: "Photos & AI Processing",
                        body: "To give you feedback, your outfit photos are sent to third-party AI providers — they are not analyzed only on your device. Outfit scoring is processed by OpenAI through our secure Firebase backend, and AI outfit upgrades are processed by Google Gemini. By uploading a photo you consent to this processing. We do not permit these providers to use your photos to train their models."
                    )

                    policySection(
                        icon: "server.rack",
                        title: "Third-Party Services",
                        body: "• Google Firebase — Authentication, Firestore database, and Cloud Storage (data hosting, encrypted at rest and in transit).\n• Apple — App Store & StoreKit handle all subscription purchases and billing.\n• OpenAI and Google Gemini — AI providers that analyze your outfit photos as described above.\nEach provider processes your data under its own privacy policy."
                    )

                    policySection(
                        icon: "flame.fill",
                        title: "Public Features (Arena & Leaderboards)",
                        body: "FitCheck includes an Arena and Today/Week leaderboards. Public visibility is off by default — your fits stay private until you opt in. If you turn it on in Privacy & Data Settings, your top-scoring fits may be shown publicly to other signed-in users — including your display name, avatar, outfit photo, and AI score — where other users can vote and leave outfit-focused comments. You can turn it back off anytime. We never show your email or other account details publicly."
                    )

                    policySection(
                        icon: "clock.arrow.circlepath",
                        title: "Data Retention",
                        body: "Outfit photos are deleted from our servers according to your retention setting (default: 7 days after analysis). Your analysis history is kept to show your progress and is capped to your most recent checks. Account data is retained until you delete your account."
                    )

                    policySection(
                        icon: "hand.raised.fill",
                        title: "Your Controls",
                        body: "From Profile → Privacy & Data Settings you can export all your data as JSON, delete your outfit history, delete AI-generated images, and permanently delete your account and all associated data. Deletion is irreversible."
                    )

                    policySection(
                        icon: "lock.shield.fill",
                        title: "Security & No Data Selling",
                        body: "Your data is stored with industry-standard encryption. Aside from the public Arena and leaderboard features described above (which you control), your account data is private to you. We never sell, rent, or share your personal data, photos, or outfit results with advertisers, brands, or data brokers."
                    )

                    policySection(
                        icon: "envelope.fill",
                        title: "Contact",
                        body: "For privacy questions or data requests, email \(Config.privacyEmail). We respond to all privacy inquiries within 7 business days."
                    )
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 110) // clear the floating tab bar when pushed in a tab
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
