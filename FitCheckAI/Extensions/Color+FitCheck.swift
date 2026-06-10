import SwiftUI

extension Color {
    // MARK: - Brand Colors
    static let fcBackground    = Color(hex: "#EFE3D1")  // Warm beige
    static let fcSurface       = Color(hex: "#E6D8C6")  // Lighter beige card surface
    static let fcSurface2      = Color(hex: "#D8CDB8")  // Warm taupe (tab bar)
    static let fcAccent        = Color(hex: "#6F7752")  // Muted olive (primary interactive)
    static let fcAccent2       = Color(hex: "#C5C2A5")  // Muted sage (CTA card background)
    static let fcAccentCream   = Color(hex: "#EADDCB")  // Cream (button bg, plus circle)
    static let fcGold          = Color(hex: "#B8962E")  // Warm antique gold
    static let fcTextPrimary   = Color(hex: "#202414")  // Dark olive-black
    static let fcTextSecondary = Color(hex: "#7A6F5D")  // Taupe gray
    static let fcSuccess       = Color(hex: "#5C7A52")  // Muted olive green
    static let fcWarning       = Color(hex: "#9B7A3C")  // Warm amber
    static let fcError         = Color(hex: "#8B4040")  // Muted red

    // MARK: - Shadow
    static let fcShadow = Color(red: 95/255, green: 75/255, blue: 45/255).opacity(0.18)

    // MARK: - Score Colors
    static func scoreColor(for score: Double) -> Color {
        switch score {
        case 9.0...: return .fcGold
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
