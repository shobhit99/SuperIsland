import Foundation

enum ActiveModule: Equatable, Hashable, Identifiable {
    case builtIn(ModuleType)
    case extension_(String)

    var id: String {
        switch self {
        case .builtIn(let module):
            return "builtin:\(module.rawValue)"
        case .extension_(let extensionID):
            return "extension:\(extensionID)"
        }
    }

    @MainActor
    var displayName: String {
        switch self {
        case .builtIn(let module):
            return module.displayName
        case .extension_(let extensionID):
            return ExtensionManager.shared.manifest(for: extensionID)?.name ?? extensionID
        }
    }

    @MainActor
    var iconName: String {
        switch self {
        case .builtIn(let module):
            return module.iconName
        case .extension_:
            return "puzzlepiece.extension"
        }
    }
}
