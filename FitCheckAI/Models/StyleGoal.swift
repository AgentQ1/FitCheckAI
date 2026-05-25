import SwiftUI

enum StyleGoal: String, CaseIterable, Codable {
    case campus       = "campus"
    case professional = "professional"
    case dateNight    = "date_night"
    case luxury       = "luxury"
    case streetwear   = "streetwear"
    case gym          = "gym"
    case genZ         = "gen_z"
    case interview    = "interview"

    var displayName: String {
        switch self {
        case .campus:       return "Campus"
        case .professional: return "Professional"
        case .dateNight:    return "Date Night"
        case .luxury:       return "Luxury"
        case .streetwear:   return "Streetwear"
        case .gym:          return "Gym Fit"
        case .genZ:         return "Gen Z"
        case .interview:    return "Interview"
        }
    }

    var shortName: String {
        switch self {
        case .campus:       return "Campus"
        case .professional: return "Pro"
        case .dateNight:    return "Date"
        case .luxury:       return "Luxury"
        case .streetwear:   return "Street"
        case .gym:          return "Gym"
        case .genZ:         return "Gen Z"
        case .interview:    return "Interview"
        }
    }

    var emoji: String {
        switch self {
        case .campus:       return "🎓"
        case .professional: return "💼"
        case .dateNight:    return "🌙"
        case .luxury:       return "👑"
        case .streetwear:   return "🛹"
        case .gym:          return "🏋️"
        case .genZ:         return "🎤"
        case .interview:    return "📋"
        }
    }

    var description: String {
        switch self {
        case .campus:       return "Class, clubs, everyday"
        case .professional: return "Work, meetings, offices"
        case .dateNight:    return "Dinner, events, nights out"
        case .luxury:       return "Old money, elevated, polished"
        case .streetwear:   return "Hype, drops, culture"
        case .gym:          return "Athleisure, performance"
        case .genZ:         return "Trend-forward, expressive"
        case .interview:    return "Conservative, sharp, confident"
        }
    }
}

enum SubscriptionTier: String, Codable {
    case free     = "free"
    case student  = "student"
    case monthly  = "monthly"
    case yearly   = "yearly"

    var isPremium: Bool { self != .free }
    var displayName: String {
        switch self {
        case .free:    return "Free"
        case .student: return "Student"
        case .monthly: return "Premium"
        case .yearly:  return "Premium Annual"
        }
    }
}
