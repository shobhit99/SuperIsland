import Foundation

enum ExtensionLogLevel: String {
    case info
    case warning
    case error
}

struct ExtensionLogEntry: Identifiable {
    let id = UUID()
    let extensionID: String
    let level: ExtensionLogLevel
    let message: String
    let timestamp: Date
}

@MainActor
final class ExtensionLogger: ObservableObject {
    static let shared = ExtensionLogger()

    @Published private(set) var entries: [ExtensionLogEntry] = []

    private init() {}

    func log(_ extensionID: String, _ level: ExtensionLogLevel, _ message: String) {
        let entry = ExtensionLogEntry(
            extensionID: extensionID,
            level: level,
            message: message,
            timestamp: Date()
        )
        entries.append(entry)

        if entries.count > 250 {
            entries.removeFirst(entries.count - 250)
        }
    }

    func entries(for extensionID: String) -> [ExtensionLogEntry] {
        entries.filter { $0.extensionID == extensionID }
    }
}
