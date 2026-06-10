import SwiftUI

struct VerdictBadge: View {
    let verdict: String

    private var emoji: String {
        switch verdict {
        case "Iconic":        return "👑"
        case "Chef's Kiss":   return "💋"
        case "Fire Fit":      return "🔥"
        case "Clean AF":      return "✨"
        case "Solid Look":    return "💪"
        case "Good Energy":   return "⚡"
        case "Almost There":  return "🎯"
        case "Needs Work":    return "🛠️"
        case "Room to Grow":  return "🌱"
        default:              return "💬"
        }
    }

    private var bg: Color {
        switch verdict {
        case "Iconic", "Chef's Kiss":       return .fcGold
        case "Fire Fit", "Clean AF":        return .fcAccent
        case "Solid Look", "Good Energy":   return .fcSuccess
        case "Almost There":                return .fcWarning
        case "Needs Work", "Room to Grow":  return .fcError
        default:                            return Color.fcTextSecondary
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(emoji)
                .font(.system(size: 20))
            Text(verdict)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(Color.fcAccentCream)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(bg)
        .clipShape(Capsule())
        .shadow(color: bg.opacity(0.35), radius: 10)
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
