import AppKit

enum EnergySuggestionReason {
    case battery
    case sustainedActivity

    var message: String {
        switch self {
        case .battery:
            return "Your Mac switched to battery power. SuperIsland can reduce background refresh and pause inactive extension work until you switch back."
        case .sustainedActivity:
            return "SuperIsland has been doing sustained background refresh work. Low Power mode can slow non-essential refresh until you need it again."
        }
    }
}

@MainActor
final class EnergySuggestionPresenter {
    static let shared = EnergySuggestionPresenter()

    private let lastPromptKey = "energy.lowPowerSuggestion.lastPromptAt"
    private var isShowing = false

    private init() {}

    func suggestLowPower(reason: EnergySuggestionReason) {
        let appState = AppState.shared
        guard appState.energyMode != .lowPower else { return }
        guard !appState.lowPowerSuggestionDoNotAskAgain else { return }
        guard !isShowing else { return }

        let lastPrompt = UserDefaults.standard.double(forKey: lastPromptKey)
        if lastPrompt > 0, Date().timeIntervalSince1970 - lastPrompt < 24 * 60 * 60 {
            return
        }

        isShowing = true
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastPromptKey)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let alert = NSAlert()
            alert.messageText = "Use Low Power mode?"
            alert.informativeText = reason.message
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Enable Low Power")
            alert.addButton(withTitle: "Not Now")
            alert.addButton(withTitle: "Do Not Ask Again")

            let response = alert.runModal()
            switch response {
            case .alertFirstButtonReturn:
                AppState.shared.energyMode = .lowPower
            case .alertThirdButtonReturn:
                AppState.shared.lowPowerSuggestionDoNotAskAgain = true
            default:
                break
            }
            self.isShowing = false
        }
    }
}
