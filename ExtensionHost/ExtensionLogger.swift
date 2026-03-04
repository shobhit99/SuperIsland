import Foundation
import Combine

final class ExtensionLogger: ObservableObject {
    static let shared = ExtensionLogger()

    enum Level: String {
        case info
        case warning
        case error
    }

    struct Entry: Identifiable {
        let id = UUID()
        let extensionID: String
        let level: Level
        let message: String
        let timestamp: Date
    }

    @Published private(set) var records: [Entry] = []

    private let maxRecords = 500
    private init() {}

    func log(_ extensionID: String, _ level: Level, _ message: String) {
        let entry = Entry(
            extensionID: extensionID,
            level: level,
            message: message,
            timestamp: Date()
        )

        DispatchQueue.main.async {
            self.records.append(entry)
            if self.records.count > self.maxRecords {
                self.records.removeFirst(self.records.count - self.maxRecords)
            }
        }
    }

    func entries(for extensionID: String) -> [Entry] {
        records.filter { $0.extensionID == extensionID }
    }
}
