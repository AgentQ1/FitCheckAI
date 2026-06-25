import Foundation
import FirebaseAuth
import FirebaseFirestore

/// Community-safety plumbing for Apple Guideline 1.2 (User-Generated Content).
///
/// Two responsibilities:
///   1. **Terms / EULA acceptance** — records that the user agreed to the Terms of
///      Use + EULA (with the zero-tolerance policy) BEFORE they ever sign in. The
///      acceptance is stored locally the instant the box is ticked (so the gate is
///      enforced even for guests / before a Firebase account exists) and mirrored to
///      the user doc after login (`acceptedTermsVersion` / `acceptedTermsAt` /
///      `acceptedTermsByUid`).
///   2. **Reports** — writes a durable record to the top-level `reports` collection
///      for every report-content and block-user action, so the developer has a single
///      moderation queue to act on within 24 hours (remove content / eject users).
enum ModerationService {

    // MARK: - Terms / EULA acceptance

    private static let acceptedVersionKey = "legal.acceptedTermsVersion"
    private static let acceptedAtKey      = "legal.acceptedTermsAt"

    /// True once the user has accepted the CURRENT terms version (checked locally so
    /// the login gate works before any network/Firebase round-trip).
    static var hasAcceptedCurrentTerms: Bool {
        UserDefaults.standard.string(forKey: acceptedVersionKey) == Config.Legal.termsVersion
    }

    /// Record local acceptance the instant the user ticks the agreement box, before
    /// any sign-in. Captures the version + timestamp so it can be mirrored to the user
    /// doc once we have a uid.
    static func recordLocalAcceptance() {
        UserDefaults.standard.set(Config.Legal.termsVersion, forKey: acceptedVersionKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: acceptedAtKey)
        print("[Moderation] terms accepted locally version=\(Config.Legal.termsVersion)")
    }

    /// Mirror the recorded acceptance onto the signed-in user's Firestore doc so it
    /// follows the account (auditable: who accepted, which version, when). Best-effort.
    static func syncAcceptanceToFirestore() async {
        guard let uid = Auth.auth().currentUser?.uid, hasAcceptedCurrentTerms else { return }
        let acceptedAt = UserDefaults.standard.double(forKey: acceptedAtKey)
        let payload: [String: Any] = [
            "acceptedTermsVersion": Config.Legal.termsVersion,
            "acceptedTermsAt": acceptedAt > 0
                ? Timestamp(date: Date(timeIntervalSince1970: acceptedAt))
                : FieldValue.serverTimestamp(),
            "acceptedTermsByUid": uid,
        ]
        do {
            try await Firestore.firestore().collection("users").document(uid)
                .setData(payload, merge: true)
            print("[Moderation] terms acceptance mirrored to users/\(uid)")
        } catch {
            print("[Moderation] terms acceptance mirror failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Reports (developer moderation queue)

    enum ContentType: String { case arenaFit, arenaComment, user }

    /// File a content report into the top-level `reports` queue. The reporting client
    /// also hides the content locally at once (caller's responsibility). Status starts
    /// `open`; the developer reviews + actions it within 24h. Create-only by rules.
    static func reportContent(
        reportedUid: String,
        contentId: String,
        contentType: ContentType,
        reason: String,
        details: String? = nil
    ) {
        write(type: "report", reportedUid: reportedUid, contentId: contentId,
              contentType: contentType.rawValue, reason: reason, details: details)
    }

    /// File a block as a developer notification (Guideline 1.2 requires blocking to
    /// notify the developer). The actual hide/prevent-interaction is handled locally +
    /// in `users/{uid}.blockedUserIDs` by `BlockedUsers`.
    static func reportBlock(reportedUid: String) {
        write(type: "block", reportedUid: reportedUid, contentId: reportedUid,
              contentType: ContentType.user.rawValue, reason: "User blocked", details: nil)
    }

    private static func write(
        type: String, reportedUid: String, contentId: String,
        contentType: String, reason: String, details: String?
    ) {
        guard let reporterUid = Auth.auth().currentUser?.uid else {
            print("[Moderation] \(type) skipped — no signed-in user")
            return
        }
        var data: [String: Any] = [
            "type": type,
            "reporterUid": reporterUid,
            "reportedUid": reportedUid,
            "contentId": contentId,
            "contentType": contentType,
            "reason": reason,
            "status": "open",
            "createdAt": FieldValue.serverTimestamp(),
        ]
        if let details, !details.isEmpty { data["details"] = details }
        Firestore.firestore().collection("reports").addDocument(data: data) { error in
            if let error {
                print("[Moderation] \(type) write failed: \(error.localizedDescription)")
            } else {
                print("[Moderation] \(type) filed → reports (reported=\(reportedUid) content=\(contentId))")
            }
        }
    }
}
