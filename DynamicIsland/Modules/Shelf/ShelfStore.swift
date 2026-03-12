import AppKit
import Foundation
import UniformTypeIdentifiers

enum ShelfItemKind: String, Codable, Hashable {
    case file
    case link
    case text
}

struct ShelfItem: Identifiable, Codable, Hashable {
    let id: UUID
    let kind: ShelfItemKind
    let displayName: String
    let path: String?
    let bookmarkData: Data?
    let urlString: String?
    let textValue: String?
    let addedAt: Date

    init(
        id: UUID = UUID(),
        kind: ShelfItemKind,
        displayName: String,
        path: String? = nil,
        bookmarkData: Data? = nil,
        urlString: String? = nil,
        textValue: String? = nil,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.path = path
        self.bookmarkData = bookmarkData
        self.urlString = urlString
        self.textValue = textValue
        self.addedAt = addedAt
    }

    static func file(from url: URL) -> ShelfItem {
        let bookmarkData = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        return ShelfItem(
            kind: .file,
            displayName: displayName(for: url),
            path: url.path,
            bookmarkData: bookmarkData
        )
    }

    static func link(_ url: URL) -> ShelfItem {
        ShelfItem(
            kind: .link,
            displayName: linkDisplayName(for: url),
            urlString: url.absoluteString
        )
    }

    static func text(_ value: String) -> ShelfItem {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed
        let title = firstLine.isEmpty ? "Text snippet" : String(firstLine.prefix(72))
        return ShelfItem(kind: .text, displayName: title, textValue: trimmed)
    }

    var dedupeKey: String {
        switch kind {
        case .file:
            return "file:\(resolvedFileURL?.standardizedFileURL.path ?? path ?? displayName)"
        case .link:
            return "link:\(urlString ?? displayName)"
        case .text:
            return "text:\(textValue ?? displayName)"
        }
    }

    var subtitle: String {
        switch kind {
        case .file:
            guard let url = resolvedFileURL ?? path.map({ URL(fileURLWithPath: $0) }) else {
                return "File"
            }
            if url.hasDirectoryPath {
                return "Folder"
            }
            let ext = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
            return ext.isEmpty ? "File" : ext.uppercased()
        case .link:
            guard let url = resolvedURL else { return "Link" }
            return url.host(percentEncoded: false) ?? "Link"
        case .text:
            let count = textValue?.count ?? 0
            return count == 1 ? "1 character" : "\(count) characters"
        }
    }

    var previewText: String? {
        switch kind {
        case .file:
            guard let url = resolvedFileURL ?? path.map({ URL(fileURLWithPath: $0) }) else {
                return nil
            }
            let folder = url.deletingLastPathComponent().lastPathComponent
            return folder.isEmpty ? url.path : folder
        case .link:
            return urlString
        case .text:
            guard let textValue else { return nil }
            let collapsed = textValue.replacingOccurrences(of: "\n", with: " ")
            return String(collapsed.prefix(110))
        }
    }

    var resolvedURL: URL? {
        switch kind {
        case .file:
            return resolvedFileURL
        case .link:
            guard let urlString else { return nil }
            return URL(string: urlString)
        case .text:
            return nil
        }
    }

    var resolvedFileURL: URL? {
        if let bookmarkData {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                return url
            }
        }

        if let path {
            return URL(fileURLWithPath: path)
        }

        return nil
    }

    var icon: NSImage {
        switch kind {
        case .file:
            if let url = resolvedFileURL ?? path.map({ URL(fileURLWithPath: $0) }) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
            return Self.symbolImage(systemName: "doc.fill")
        case .link:
            return Self.symbolImage(systemName: "link")
        case .text:
            return Self.symbolImage(systemName: "text.alignleft")
        }
    }

    private static func displayName(for url: URL) -> String {
        if let localizedName = try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName,
           !localizedName.isEmpty {
            return localizedName
        }
        return url.lastPathComponent
    }

    private static func linkDisplayName(for url: URL) -> String {
        if let host = url.host(percentEncoded: false), !host.isEmpty {
            let suffix = url.path == "/" ? "" : url.path
            return host + suffix
        }
        return url.absoluteString
    }

    private static func symbolImage(systemName: String) -> NSImage {
        NSImage(systemSymbolName: systemName, accessibilityDescription: nil) ?? NSImage()
    }
}

@MainActor
final class ShelfStore: ObservableObject {
    static let shared = ShelfStore()

    static let acceptedDropTypes: [UTType] = [
        .fileURL,
        .url,
        .utf8PlainText,
        .plainText,
        .text
    ]

    @Published private(set) var items: [ShelfItem]

    private let storageKey = "module.shelf.items"
    private var activeAirDropService: NSSharingService?

    private init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([ShelfItem].self, from: data) {
            self.items = decoded
        } else {
            self.items = []
        }
    }

    var isEmpty: Bool {
        items.isEmpty
    }

    func handleDrop(
        providers: [NSItemProvider],
        completion: (@MainActor (_ addedCount: Int) -> Void)? = nil
    ) -> Bool {
        guard !providers.isEmpty else { return false }

        Task {
            let droppedItems = await Self.extractItems(from: providers)
            let addedCount = await MainActor.run {
                add(droppedItems)
            }
            await MainActor.run {
                completion?(addedCount)
            }
        }

        return true
    }

    @discardableResult
    func add(_ incomingItems: [ShelfItem]) -> Int {
        guard !incomingItems.isEmpty else { return 0 }

        var merged = items
        var existingKeys = Set(merged.map(\.dedupeKey))
        var addedCount = 0

        for item in incomingItems {
            let key = item.dedupeKey
            guard !existingKeys.contains(key) else { continue }
            merged.append(item)
            existingKeys.insert(key)
            addedCount += 1
        }

        guard addedCount > 0 else { return 0 }
        items = merged
        persist()
        return addedCount
    }

    func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
        persist()
    }

    func clear() {
        guard !items.isEmpty else { return }
        items.removeAll()
        persist()
    }

    func open(_ item: ShelfItem) {
        switch item.kind {
        case .file:
            withResolvedFileURL(for: item) { url in
                NSWorkspace.shared.open(url)
            }
        case .link:
            if let url = item.resolvedURL {
                NSWorkspace.shared.open(url)
            }
        case .text:
            copy(item)
        }
    }

    func reveal(_ item: ShelfItem) {
        guard item.kind == .file else { return }
        withResolvedFileURL(for: item) { url in
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func copy(_ item: ShelfItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch item.kind {
        case .file:
            if let url = item.resolvedFileURL {
                pasteboard.writeObjects([url as NSURL])
            }
        case .link:
            if let urlString = item.urlString {
                pasteboard.setString(urlString, forType: .string)
            }
        case .text:
            if let text = item.textValue {
                pasteboard.setString(text, forType: .string)
            }
        }
    }

    func dragProvider(for item: ShelfItem) -> NSItemProvider {
        switch item.kind {
        case .file:
            if let url = item.resolvedFileURL {
                if let provider = NSItemProvider(contentsOf: url) {
                    return provider
                }
                return NSItemProvider(object: url as NSURL)
            }
        case .link:
            if let url = item.resolvedURL {
                return NSItemProvider(object: url as NSURL)
            }
        case .text:
            if let text = item.textValue {
                return NSItemProvider(object: text as NSString)
            }
        }

        return NSItemProvider(object: item.displayName as NSString)
    }

    func handleAirDropDrop(providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }

        Task {
            let droppedItems = await Self.extractItems(from: providers)
            await MainActor.run {
                shareViaAirDrop(items: droppedItems)
            }
        }

        return true
    }

    func openAirDropPicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            self?.shareViaAirDrop(rawItems: panel.urls)
        }
    }

    func shareViaAirDrop(items: [ShelfItem]) {
        let rawItems = items.compactMap(airDropPayload(for:))
        shareViaAirDrop(rawItems: rawItems)
    }

    private func persist() {
        if let encoded = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(encoded, forKey: storageKey)
        }
    }

    private func withResolvedFileURL(for item: ShelfItem, _ action: (URL) -> Void) {
        guard let url = item.resolvedFileURL else { return }
        let didAccess = url.startAccessingSecurityScopedResource()
        action(url)
        if didAccess {
            url.stopAccessingSecurityScopedResource()
        }
    }

    private func airDropPayload(for item: ShelfItem) -> Any? {
        switch item.kind {
        case .file:
            return item.resolvedFileURL
        case .link:
            return item.resolvedURL
        case .text:
            return item.textValue
        }
    }

    private func shareViaAirDrop(rawItems: [Any]) {
        guard !rawItems.isEmpty,
              let service = NSSharingService(named: .sendViaAirDrop),
              service.canPerform(withItems: rawItems) else {
            NSSound.beep()
            return
        }

        activeAirDropService = service
        service.perform(withItems: rawItems)
    }

    private static func extractItems(from providers: [NSItemProvider]) async -> [ShelfItem] {
        var extracted: [ShelfItem] = []

        for provider in providers {
            if let item = await extractItem(from: provider) {
                extracted.append(item)
            }
        }

        return extracted
    }

    private static func extractItem(from provider: NSItemProvider) async -> ShelfItem? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = await loadURL(from: provider, type: .fileURL),
           url.isFileURL {
            return .file(from: url)
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let url = await loadURL(from: provider, type: .url) {
            return url.isFileURL ? .file(from: url) : .link(url)
        }

        for type in [UTType.utf8PlainText, .plainText, .text] {
            guard provider.hasItemConformingToTypeIdentifier(type.identifier),
                  let string = await loadString(from: provider, type: type) else {
                continue
            }

            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if let url = recognizedURL(from: trimmed) {
                return url.isFileURL ? .file(from: url) : .link(url)
            }

            return .text(trimmed)
        }

        return nil
    }

    private static func recognizedURL(from string: String) -> URL? {
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased() else {
            return nil
        }

        switch scheme {
        case "http", "https", "mailto", "file":
            return url
        default:
            return nil
        }
    }

    private static func loadURL(from provider: NSItemProvider, type: UTType) async -> URL? {
        guard let item = await loadItem(from: provider, typeIdentifier: type.identifier) else {
            return nil
        }

        if let url = item as? URL {
            return url
        }
        if let url = item as? NSURL {
            return url as URL
        }
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        if let string = item as? String {
            return URL(string: string)
        }
        if let string = item as? NSString {
            return URL(string: string as String)
        }

        return nil
    }

    private static func loadString(from provider: NSItemProvider, type: UTType) async -> String? {
        guard let item = await loadItem(from: provider, typeIdentifier: type.identifier) else {
            return nil
        }

        if let string = item as? String {
            return string
        }
        if let string = item as? NSString {
            return string as String
        }
        if let data = item as? Data {
            return String(data: data, encoding: .utf8)
        }

        return nil
    }

    private static func loadItem(from provider: NSItemProvider, typeIdentifier: String) async -> NSSecureCoding? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                guard error == nil else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: item)
            }
        }
    }
}
