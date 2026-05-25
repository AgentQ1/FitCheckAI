import SwiftUI

extension Color {
    // MARK: - Brand Colors
    static let fcBackground   = Color(hex: "#0A0A0A")
    static let fcSurface      = Color(hex: "#1A1A1A")
    static let fcSurface2     = Color(hex: "#242424")
    static let fcAccent       = Color(hex: "#C8FF00")  // Electric lime
    static let fcAccent2      = Color(hex: "#FF3CAC")  // Hot pink
    static let fcGold         = Color(hex: "#FFD700")
    static let fcTextPrimary  = Color.white
    static let fcTextSecondary = Color(hex: "#A0A0A0")
    static let fcSuccess      = Color(hex: "#00E676")
    static let fcWarning      = Color(hex: "#FFB300")
    static let fcError        = Color(hex: "#FF5252")

    // MARK: - Score Colors
    static func scoreColor(for score: Double) -> Color {
        switch score {
        case 9.0...: return .fcGold
        case 8.5...: return .fcAccent
        case 7.0...: return .fcAccent
        case 5.0...: return .fcWarning
        default:     return .fcError
        }
    }

    // MARK: - Hex Init
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:(a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(.sRGB, red: Double(r)/255, green: Double(g)/255, blue: Double(b)/255, opacity: Double(a)/255)
    }
}
