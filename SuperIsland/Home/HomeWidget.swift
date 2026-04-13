import Foundation

enum HomeWidgetSelection: Hashable, Identifiable, RawRepresentable {
    case none
    case builtIn(ModuleType)
    case extension_(String)

    init?(rawValue: String) {
        if rawValue == Self.none.rawValue {
            self = .none
        } else if rawValue.hasPrefix("builtIn."),
                  let module = ModuleType(rawValue: String(rawValue.dropFirst("builtIn.".count))) {
            self = .builtIn(module)
        } else if rawValue.hasPrefix("extension.") {
            self = .extension_(String(rawValue.dropFirst("extension.".count)))
        } else {
            self = .none
        }
    }

    var id: String { rawValue }

    var rawValue: String {
        switch self {
        case .none:
            return "none"
        case .builtIn(let module):
            return "builtIn.\(module.rawValue)"
        case .extension_(let extensionID):
            return "extension.\(extensionID)"
        }
    }

    @MainActor
    var displayName: String {
        switch self {
        case .none:
            return "None"
        case .builtIn(.nowPlaying):
            return "Media Player"
        case .builtIn(let module):
            return module.displayName
        case .extension_(let extensionID):
            return ExtensionManager.shared.installed.first(where: { $0.id == extensionID })?.name ?? extensionID
        }
    }

    var iconName: String {
        switch self {
        case .none:
            return "minus"
        case .builtIn(let module):
            return module.iconName
        case .extension_:
            return "puzzlepiece.extension"
        }
    }
}

struct HomeWidgetOption: Identifiable, Hashable {
    let selection: HomeWidgetSelection
    let label: String
    let iconName: String

    var id: String { selection.id }
}
