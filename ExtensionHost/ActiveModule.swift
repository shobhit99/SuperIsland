import Foundation

enum ActiveModule: Equatable, Hashable {
    case builtIn(ModuleType)
    case extension_(String)

    @MainActor
    var displayName: String {
        switch self {
        case .builtIn(let module):
            return module.displayName
        case .extension_(let id):
            return ExtensionManager.shared.installed.first(where: { $0.id == id })?.name ?? id
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
