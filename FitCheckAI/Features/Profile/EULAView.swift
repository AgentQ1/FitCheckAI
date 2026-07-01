import SwiftUI

/// End User License Agreement — referenced from the sign-in agreement gate and the
/// legal links. Leads with the zero-tolerance policy Apple Guideline 1.2 requires
/// for apps with user-generated content, and references Apple's standard EULA.
struct EULAView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            Color.fcBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Last updated: June 2026")
                        .font(.fcCaption)
                        .foregroundColor(.fcTextSecondary)

                    section(title: "Zero Tolerance for Objectionable Content") {
                        Config.Legal.zeroToleranceStatement
                    }

                    section(title: "Community Conduct") {
                        "FitCheck includes public community features (the Arena and leaderboards). By participating you agree to keep all content focused on outfits and styling and to treat other users respectfully. You may report any fit and block any user from inside the app. We review reported content and act within 24 hours — removing violating content and suspending or terminating abusive accounts. We may remove content or terminate accounts at our discretion for any violation of this agreement."
                    }

                    section(title: "Your Content & License") {
                        "You must own, or have the rights to use, every photo you upload, and you may not upload images of other people without their consent. You retain ownership of your content. By uploading you grant FitCheck a limited license to process, store, and display the content solely to operate the app (analyze it, generate feedback, and — only if you opt in to public visibility — show it in the community features)."
                    }

                    section(title: "Apple Standard EULA") {
                        "Unless you have signed a separate agreement with FitCheck, your use of this app is also governed by Apple's Licensed Application End User License Agreement (the standard Apple EULA). Where the two differ, the stricter content-and-conduct terms above apply."
                    }

                    Button {
                        if let url = URL(string: Config.Legal.appleStandardEULA) { openURL(url) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.right.square")
                            Text("View Apple's Standard EULA")
                        }
                        .font(.fcBodyBold)
                        .foregroundColor(.fcAccent)
                    }

                    section(title: "Subscriptions & Refunds") {
                        "FitCheck Premium is an auto-renewable subscription sold through Apple In-App Purchase, charged to your Apple ID and managed in your App Store account settings. Refunds, where applicable, are handled by Apple."
                    }

                    section(title: "Contact") {
                        "Questions or to report abuse: \(Config.supportEmail)."
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 110)
            }
        }
        .navigationTitle("EULA")
        .navigationBarTitleDisplayMode(.large)
    }

    private func section(title: String, content: () -> String) -> some View {
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
