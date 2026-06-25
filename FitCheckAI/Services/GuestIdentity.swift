import Foundation

/// Deterministic, safe display identity for users who have no usable name yet:
///   • Guests (anonymous Firebase sessions)
///   • Apple Sign-In users who hid their email (private relay) and gave no name
///   • Any account whose provider returned no name
///
/// Everything is derived from a stable seed (the Firebase uid), so the SAME user
/// always gets the SAME nickname + avatar across launches/devices — with no network
/// call, no IDFA, and no tracking. The word lists are intentionally wholesome:
/// friendly adjectives + animals only, nothing sexual, political, religious, or
/// insulting.
enum GuestIdentity {

    // MARK: - Word lists (adjective + animal → "Velvet Panda")

    /// Friendly, neutral adjectives. No insults / slurs / sensitive themes.
    static let adjectives: [String] = [
        "Tipsy", "Velvet", "Lucky", "Cosmic", "Sunny", "Mellow", "Brave", "Clever",
        "Swift", "Gentle", "Jolly", "Breezy", "Nimble", "Cozy", "Daring", "Dapper",
        "Snazzy", "Plucky", "Spry", "Witty", "Radiant", "Golden", "Silver", "Royal",
        "Frosty", "Amber", "Coral", "Maple", "Misty", "Pebble", "Sandy", "Stellar",
    ]

    /// Animals paired with a matching emoji for the generated avatar.
    static let animals: [(name: String, emoji: String)] = [
        ("Cheetah", "🐆"), ("Panda", "🐼"), ("Falcon", "🦅"), ("Tiger", "🐯"),
        ("Leopard", "🐆"), ("Otter", "🦦"), ("Fox", "🦊"), ("Koala", "🐨"),
        ("Lion", "🦁"), ("Wolf", "🐺"), ("Bear", "🐻"), ("Owl", "🦉"),
        ("Hawk", "🦅"), ("Dolphin", "🐬"), ("Penguin", "🐧"), ("Rabbit", "🐰"),
        ("Deer", "🦌"), ("Horse", "🐴"), ("Eagle", "🦅"), ("Whale", "🐳"),
        ("Seal", "🦭"), ("Raccoon", "🦝"), ("Hedgehog", "🦔"), ("Swan", "🦢"),
    ]

    /// Gradient pairs (top → bottom) for the avatar background, as hex strings.
    static let gradients: [(String, String)] = [
        ("#FF9A8B", "#FF6A88"), ("#A18CD1", "#FBC2EB"), ("#84FAB0", "#8FD3F4"),
        ("#FFD26F", "#F09819"), ("#43E97B", "#38F9D7"), ("#667EEA", "#764BA2"),
        ("#F6D365", "#FDA085"), ("#5EE7DF", "#B490CA"), ("#C79081", "#DFA579"),
        ("#FBAB7E", "#F7CE68"), ("#74EBD5", "#9FACE6"), ("#FF9A9E", "#FECFEF"),
    ]

    // MARK: - Stable hashing
    //
    // Swift's built-in Hasher is randomized per process, so it can't be used for a
    // value that must stay the same across launches. FNV-1a is a tiny, stable hash.
    static func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x00000100000001B3
        }
        return hash
    }

    // MARK: - Public API

    /// Deterministic "Adjective Animal" nickname from a seed (uid).
    static func nickname(seed: String) -> String {
        let h = stableHash(seed)
        let adj = adjectives[Int(h % UInt64(adjectives.count))]
        let animal = animals[Int((h / 31) % UInt64(animals.count))].name
        return "\(adj) \(animal)"
    }

    /// Emoji for the seed's animal (used on the generated avatar).
    static func avatarEmoji(seed: String) -> String {
        let h = stableHash(seed)
        return animals[Int((h / 31) % UInt64(animals.count))].emoji
    }

    /// The two-stop gradient (hex strings) for the seed's avatar background.
    static func gradientHex(seed: String) -> (String, String) {
        let h = stableHash(seed)
        return gradients[Int((h / 7) % UInt64(gradients.count))]
    }

    // MARK: - Email helpers

    /// True for Apple's private-relay address, which must NEVER be shown as a name.
    static func isMaskedAppleEmail(_ email: String?) -> Bool {
        guard let email = email?.lowercased() else { return false }
        return email.hasSuffix("@privaterelay.appleid.com")
    }

    /// Resolve the best display name for an account:
    ///   1. a real provider/saved name, if present and not a masked email
    ///   2. otherwise a generated nickname from the uid
    ///
    /// `providerName` is whatever Apple/Google/Firestore handed us (may be nil/empty).
    /// `email` is the account email (used only to reject masked relay addresses).
    static func resolvedDisplayName(uid: String, providerName: String?, email: String?) -> String {
        if let name = providerName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty,
           !isMaskedAppleEmail(name) {
            return name
        }
        return nickname(seed: uid)
    }
}
