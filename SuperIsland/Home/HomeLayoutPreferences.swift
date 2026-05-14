import SwiftUI

enum HomePanel: String, CaseIterable, Identifiable {
    case none
    case nowPlaying
    case calendar
    case weather

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "Empty"
        case .nowPlaying: return "Now Playing"
        case .calendar: return "Calendar"
        case .weather: return "Weather"
        }
    }

    var iconName: String {
        switch self {
        case .none: return "minus.circle"
        case .nowPlaying: return "music.note"
        case .calendar: return "calendar"
        case .weather: return "cloud.sun.fill"
        }
    }

    var module: ModuleType? {
        switch self {
        case .none: return nil
        case .nowPlaying: return .nowPlaying
        case .calendar: return .calendar
        case .weather: return .weather
        }
    }
}

enum AnimationLevel: String, CaseIterable, Identifiable {
    case full
    case subtle
    case reduced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .full: return "Full"
        case .subtle: return "Subtle"
        case .reduced: return "Reduced"
        }
    }

    var bounceLimit: Double {
        switch self {
        case .full: return 0.5
        case .subtle: return 0.08
        case .reduced: return 0
        }
    }
}
