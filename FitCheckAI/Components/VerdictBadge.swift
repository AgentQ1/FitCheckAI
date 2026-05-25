import SwiftUI

struct VerdictBadge: View {
    let verdict: String

    private var emoji: String {
        switch verdict {
        case "Iconic":       return "👑"
        case "Chef's Kiss":  return "💋"
        case "Fire Fit":     return "🔥"
        case "Clean AF":     return "✨"
        case "Solid Look":   return "💪"
        case "Good Energy":  return "⚡"
        case "Almost There": return "🎯"
        case "Needs Work":   return "🛠️"
        default:             return "🌱"
        }
    }

    private var bg: Color {
        switch verdict {
        case "Iconic", "Chef's Kiss":           return .fcGold
        case "Fire Fit", "Clean AF":            return .fcAccent
        case "Solid Look", "Good Energy":       return Color(hex: "#3DFF8F")
        case "Almost There":                    return .fcWarning
        default:                                return Color(hex: "#FF6B6B")
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(emoji)
                .font(.system(size: 20))
            Text(verdict)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.fcBackground)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(bg)
        .clipShape(Capsule())
        .shadow(color: bg.opacity(0.5), radius: 10)
    }
}

#Preview {
    ZStack {
        Color.fcBackground
        VStack(spacing: 12) {
            VerdictBadge(verdict: "Fire Fit")
            VerdictBadge(verdict: "Iconic")
            VerdictBadge(verdict: "Almost There")
        }
    }
}
