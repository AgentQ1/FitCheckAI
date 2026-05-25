import Foundation

// Thin wrapper around PostHog — swap implementation as needed
final class AnalyticsService {
    func identify(userID: String, properties: [String: Any] = [:]) {
        // PostHog.shared.identify(userID, userProperties: properties)
        log("identify: \(userID)")
    }

    func track(_ event: AnalyticsEvent, properties: [String: Any] = [:]) {
        // PostHog.shared.capture(event.rawValue, properties: properties)
        log("track: \(event.rawValue) \(properties)")
    }

    func screen(_ name: String) {
        // PostHog.shared.screen(name)
        log("screen: \(name)")
    }

    private func log(_ msg: String) {
        #if DEBUG
        print("[Analytics] \(msg)")
        #endif
    }
}

enum AnalyticsEvent: String {
    case photoTaken            = "fitcheck_photo_taken"
    case styleGoalSelected     = "fitcheck_style_goal_selected"
    case analysisStarted       = "fitcheck_analysis_started"
    case analysisCompleted     = "fitcheck_analysis_completed"
    case resultViewed          = "fitcheck_result_viewed"
    case scoreBreakdownViewed  = "fitcheck_score_breakdown_viewed"
    case tipsViewed            = "fitcheck_tips_viewed"
    case outfitOptionsViewed   = "fitcheck_outfit_options_viewed"
    case beforeAfterViewed     = "fitcheck_before_after_viewed"
    case lookSaved             = "fitcheck_look_saved"
    case lookLiked             = "fitcheck_look_liked"
    case shareTapped           = "fitcheck_share_tapped"
    case premiumUpgradeTapped  = "fitcheck_premium_upgrade_tapped"
    case subscriptionStarted   = "fitcheck_subscription_started"
    case subscriptionCancelled = "fitcheck_subscription_cancelled"
    case deletePhotoTapped     = "fitcheck_delete_photo_tapped"
    case streakMilestone       = "fitcheck_streak_milestone"
    case signUp                = "fitcheck_sign_up"
    case signIn                = "fitcheck_sign_in"
}
