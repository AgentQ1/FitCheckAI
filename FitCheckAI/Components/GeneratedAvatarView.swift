import SwiftUI

/// Remembers the last REAL avatar URL per seed (uid), so a relaunch can show the real
/// photo immediately — before the user profile re-hydrates from Firestore — instead of
/// flashing the generated emoji avatar for a few frames (the "tri-state" the avatar
/// needs: unknown/loading → remote photo → generated fallback).
enum AvatarURLCache {
    private static let prefix = "avatarURL."

    static func cached(for seed: String) -> String? {
        let v = UserDefaults.standard.string(forKey: prefix + seed)
        return (v?.isEmpty == false) ? v : nil
    }

    static func store(_ url: String?, for seed: String) {
        guard let url, !url.isEmpty else { return }
        guard cached(for: seed) != url else { return }   // skip redundant writes
        UserDefaults.standard.set(url, forKey: prefix + seed)
    }
}

/// A profile avatar that is NEVER blank.
///
/// If the user has a real photo (Google/Apple photo or an uploaded one) it shows that.
/// Otherwise it renders a deterministic, friendly fallback: a gradient circle with the
/// user's animal emoji (from `GuestIdentity`). The same `seed` (the uid) always yields
/// the same avatar, so a guest / masked-Apple-email user has a stable identity
/// everywhere — Profile, Arena, leaderboards, comments.
struct GeneratedAvatarView: View {
    /// A real photo URL, if any. When present and loadable it wins.
    let photoURL: String?
    /// Stable seed — pass the uid when available, else the display name.
    let seed: String
    /// Optional name, used for an initial when there is no emoji match (rare).
    let name: String?
    var size: CGFloat = 44

    init(photoURL: String?, seed: String, name: String? = nil, size: CGFloat = 44) {
        self.photoURL = photoURL
        self.seed = seed
        self.name = name
        self.size = size
        // Persist a real URL so future renders (and the next launch) can show it before
        // the profile re-hydrates. Guarded internally against redundant writes.
        AvatarURLCache.store(photoURL, for: seed)
    }

    /// The URL to display: the live `photoURL` if present, else the last REAL URL cached
    /// for this seed. Falling back to the cache means a still-resolving profile (nil
    /// photoURL) shows the real photo, not the generated emoji — no flicker.
    private var effectiveURL: String? {
        if let photoURL, !photoURL.isEmpty { return photoURL }
        return AvatarURLCache.cached(for: seed)
    }

    var body: some View {
        Group {
            if let effectiveURL, let url = URL(string: effectiveURL) {
                // A real photo exists. While it loads we show a NEUTRAL placeholder, never
                // the generated avatar — otherwise the generated emoji flashes for a frame
                // before the real photo resolves (the "buggy/unfinished" flicker). The
                // generated avatar is only a fallback when the photo genuinely fails to load.
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        placeholder
                    case .success(let img):
                        img.resizable().scaledToFill()
                    case .failure:
                        generated
                    @unknown default:
                        generated
                    }
                }
            } else {
                // No photo at all → the deterministic generated avatar is the real answer.
                generated
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.white.opacity(0.5), lineWidth: max(1, size * 0.03)))
    }

    /// Neutral loading circle shown while a real photo loads — a calm placeholder, not the
    /// generated avatar, so an existing-photo user never sees the generated emoji flash.
    private var placeholder: some View {
        ZStack {
            Color.fcSurface
            ProgressView()
                .tint(.fcTextSecondary)
                .scaleEffect(min(1, size / 80))
        }
    }

    private var generated: some View {
        let stops = GuestIdentity.gradientHex(seed: seed)
        let emoji = GuestIdentity.avatarEmoji(seed: seed)
        return ZStack {
            LinearGradient(
                colors: [Color(hex: stops.0), Color(hex: stops.1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Text(emoji)
                .font(.system(size: size * 0.5))
        }
    }
}

#Preview {
    HStack(spacing: 12) {
        GeneratedAvatarView(photoURL: nil, seed: "abc123", size: 80)
        GeneratedAvatarView(photoURL: nil, seed: "xyz789", size: 56)
        GeneratedAvatarView(photoURL: nil, seed: "user-42", size: 44)
    }
    .padding()
    .background(Color.fcBackground)
}
