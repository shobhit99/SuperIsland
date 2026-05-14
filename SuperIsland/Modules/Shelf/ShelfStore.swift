import AppKit
import Foundation
import Quartz
import UniformTypeIdentifiers

enum ShelfItemKind: String, Codable, Hashable {
    case file
    case folder
    case image
    case link
    case text
}

enum ShelfRetentionOption: Int, CaseIterable, Identifiable {
    case never = 0
    case oneDay = 1
    case oneWeek = 7
    case oneMonth = 30
    case threeMonths = 90

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .never: return "Never"
        case .oneDay: return "1 day"
        case .oneWeek: return "7 days"
        case .oneMonth: return "30 days"
        case .threeMonths: return "90 days"
        }
    }
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
    var lastAccessedAt: Date?
    var isPinned: Bool

    init(
        id: UUID = UUID(),
        kind: ShelfItemKind,
        displayName: String,
        path: String? = nil,
        bookmarkData: Data? = nil,
        urlString: String? = nil,
        textValue: String? = nil,
        addedAt: Date = Date(),
        lastAccessedAt: Date? = nil,
        isPinned: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.path = path
        self.bookmarkData = bookmarkData
        self.urlString = urlString
        self.textValue = textValue
        self.addedAt = addedAt
        self.lastAccessedAt = lastAccessedAt
        self.isPinned = isPinned
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case displayName
        case path
        case bookmarkData
        case urlString
        case textValue
        case addedAt
        case lastAccessedAt
        case isPinned
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try container.decode(ShelfItemKind.self, forKey: .kind)
        displayName = try container.decode(String.self, forKey: .displayName)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        bookmarkData = try container.decodeIfPresent(Data.self, forKey: .bookmarkData)
        urlString = try container.decodeIfPresent(String.self, forKey: .urlString)
        textValue = try container.decodeIfPresent(String.self, forKey: .textValue)
        addedAt = try container.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        lastAccessedAt = try container.decodeIfPresent(Date.self, forKey: .lastAccessedAt)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }

    static func file(from url: URL) -> ShelfItem {
        let bookmarkData = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let kind = fileKind(for: url)
        return ShelfItem(
            kind: kind,
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
        case .file, .folder, .image:
            return "\(kind.rawValue):\(resolvedFileURL?.standardizedFileURL.path ?? path ?? displayName)"
        case .link:
            return "link:\(urlString ?? displayName)"
        case .text:
            return "text:\(textValue ?? displayName)"
        }
    }

    var subtitle: String {
        switch kind {
        case .file, .folder, .image:
            if isMissing {
                return "Missing"
            }
            guard let url = resolvedFileURL ?? path.map({ URL(fileURLWithPath: $0) }) else {
                return "File"
            }
            if kind == .folder || url.hasDirectoryPath {
                return "Folder"
            }
            if kind == .image {
                return "Image"
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
        case .file, .folder, .image:
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
        case .file, .folder, .image:
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
        case .file, .folder, .image:
            if let url = resolvedFileURL ?? path.map({ URL(fileURLWithPath: $0) }) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
            if kind == .image {
                return Self.symbolImage(systemName: "photo.fill")
            }
            return Self.symbolImage(systemName: "doc.fill")
        case .link:
            return Self.symbolImage(systemName: "link")
        case .text:
            return Self.symbolImage(systemName: "text.alignleft")
        }
    }

    var isFileBacked: Bool {
        switch kind {
        case .file, .folder, .image:
            return true
        case .link, .text:
            return false
        }
    }

    var canQuickLook: Bool {
        isFileBacked && !isMissing
    }

    var isMissing: Bool {
        guard isFileBacked else { return false }
        guard let url = resolvedFileURL ?? path.map({ URL(fileURLWithPath: $0) }) else {
            return true
        }
        return !FileManager.default.fileExists(atPath: url.path)
    }

    private static func fileKind(for url: URL) -> ShelfItemKind {
        if url.hasDirectoryPath {
            return .folder
        }

        if let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey]) {
            if values.isDirectory == true {
                return .folder
            }
            if values.contentType?.conforms(to: .image) == true {
                return .image
            }
        }

        if let type = UTType(filenameExtension: url.pathExtension),
           type.conforms(to: .image) {
            return .image
        }

        return .file
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
        .image,
        .utf8PlainText,
        .plainText,
        .text
    ]

    @Published private(set) var items: [ShelfItem]
    @Published var retentionDays: Int {
        didSet {
            UserDefaults.standard.set(retentionDays, forKey: retentionKey)
            pruneExpiredItems()
        }
    }

    private let storageKey = "module.shelf.items"
    private let retentionKey = "module.shelf.retentionDays"
    private var activeAirDropService: NSSharingService?
    private var activeSharingPicker: NSSharingServicePicker?

    private init() {
        self.retentionDays = UserDefaults.standard.object(forKey: retentionKey) as? Int ?? ShelfRetentionOption.never.rawValue
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([ShelfItem].self, from: data) {
            self.items = decoded
        } else {
            self.items = []
        }
        pruneExpiredItems()
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
        pruneExpiredItems()
        persist()
        return addedCount
    }

    func remove(_ item: ShelfItem) {
        removeManagedImages(for: [item])
        items.removeAll { $0.id == item.id }
        persist()
    }

    func clear() {
        guard !items.isEmpty else { return }
        removeManagedImages(for: items)
        items.removeAll()
        persist()
    }

    func clearUnpinned() {
        let removedItems = items.filter { !$0.isPinned }
        guard !removedItems.isEmpty else { return }
        removeManagedImages(for: removedItems)
        items.removeAll { !$0.isPinned }
        persist()
    }

    func togglePinned(_ item: ShelfItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].isPinned.toggle()
        items[index].lastAccessedAt = Date()
        persist()
    }

    func open(_ item: ShelfItem) {
        switch item.kind {
        case .file, .folder, .image:
            withResolvedFileURL(for: item) { url in
                NSWorkspace.shared.open(url)
            }
        case .link:
            if let url = item.resolvedURL {
                NSWorkspace.shared.open(url)
                touch(item)
            }
        case .text:
            copy(item)
        }
    }

    func reveal(_ item: ShelfItem) {
        guard item.isFileBacked else { return }
        withResolvedFileURL(for: item) { url in
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func quickLook(_ item: ShelfItem) {
        guard item.canQuickLook else {
            NSSound.beep()
            return
        }
        withResolvedFileURL(for: item) { url in
            ShelfQuickLookController.shared.preview(url)
        }
    }

    func copy(_ item: ShelfItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch item.kind {
        case .file, .folder, .image:
            if let url = item.resolvedFileURL {
                pasteboard.writeObjects([url as NSURL])
                touch(item)
            }
        case .link:
            if let urlString = item.urlString {
                pasteboard.setString(urlString, forType: .string)
                touch(item)
            }
        case .text:
            if let text = item.textValue {
                pasteboard.setString(text, forType: .string)
                touch(item)
            }
        }
    }

    func copyPath(_ item: ShelfItem) {
        guard item.isFileBacked,
              let path = item.resolvedFileURL?.path ?? item.path else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
        touch(item)
    }

    func dragProvider(for item: ShelfItem) -> NSItemProvider {
        switch item.kind {
        case .file, .folder, .image:
            if let url = item.resolvedFileURL, !item.isMissing {
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
        items.forEach(touch)
    }

    func share(items: [ShelfItem]) {
        let rawItems = items.compactMap(sharingPayload(for:))
        guard !rawItems.isEmpty else {
            NSSound.beep()
            return
        }

        guard let view = NSApp.keyWindow?.contentView
                ?? NSApp.mainWindow?.contentView
                ?? NSApp.windows.first(where: { $0.isVisible })?.contentView else {
            NSSound.beep()
            return
        }

        let picker = NSSharingServicePicker(items: rawItems)
        activeSharingPicker = picker
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        items.forEach(touch)
    }

    private func persist() {
        if let encoded = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(encoded, forKey: storageKey)
        }
    }

    private func withResolvedFileURL(for item: ShelfItem, _ action: (URL) -> Void) {
        guard let url = item.resolvedFileURL else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            NSSound.beep()
            return
        }
        let didAccess = url.startAccessingSecurityScopedResource()
        action(url)
        if didAccess {
            url.stopAccessingSecurityScopedResource()
        }
        touch(item)
    }

    private func airDropPayload(for item: ShelfItem) -> Any? {
        sharingPayload(for: item)
    }

    private func sharingPayload(for item: ShelfItem) -> Any? {
        switch item.kind {
        case .file, .folder, .image:
            guard !item.isMissing else { return nil }
            return item.resolvedFileURL
        case .link:
            return item.resolvedURL
        case .text:
            return item.textValue
        }
    }

    private func touch(_ item: ShelfItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].lastAccessedAt = Date()
        persist()
    }

    private func pruneExpiredItems() {
        guard retentionDays > 0 else { return }
        let cutoff = Date().addingTimeInterval(TimeInterval(-retentionDays * 24 * 60 * 60))
        let removedItems = items.filter { !$0.isPinned && $0.addedAt < cutoff }
        guard !removedItems.isEmpty else { return }
        removeManagedImages(for: removedItems)
        items.removeAll { !$0.isPinned && $0.addedAt < cutoff }
        persist()
    }

    private func removeManagedImages(for items: [ShelfItem]) {
        for item in items {
            guard item.kind == .image,
                  let url = item.resolvedFileURL,
                  isManagedImageURL(url) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func isManagedImageURL(_ url: URL) -> Bool {
        guard let storageURL = Self.imageStorageURL else { return false }
        let storagePath = storageURL.standardizedFileURL.path
        let itemPath = url.standardizedFileURL.path
        return itemPath == storagePath || itemPath.hasPrefix(storagePath + "/")
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

        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
           let data = await loadData(from: provider, type: .image),
           let item = imageItem(from: data, type: .image) {
            return item
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

    private static func imageItem(from data: Data, type: UTType) -> ShelfItem? {
        guard data.count <= 20 * 1024 * 1024,
              let storageURL = imageStorageURL else {
            return nil
        }

        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: storageURL, withIntermediateDirectories: true)
            let fileExtension = type.preferredFilenameExtension ?? "png"
            let fileURL = storageURL.appendingPathComponent("\(UUID().uuidString).\(fileExtension)")
            try data.write(to: fileURL, options: [.atomic])
            return ShelfItem(
                kind: .image,
                displayName: "Image",
                path: fileURL.path
            )
        } catch {
            return nil
        }
    }

    private static var imageStorageURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("SuperIsland", isDirectory: true)
            .appendingPathComponent("ShelfImages", isDirectory: true)
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

    private static func loadData(from provider: NSItemProvider, type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                guard error == nil else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: data)
            }
        }
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

@MainActor
private final class ShelfQuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = ShelfQuickLookController()

    private var previewURLs: [URL] = []
    private var scopedURLs: [URL] = []

    func preview(_ url: URL) {
        closeScopedURLs()

        let didAccess = url.startAccessingSecurityScopedResource()
        if didAccess {
            scopedURLs = [url]
        }

        previewURLs = [url]
        guard let panel = QLPreviewPanel.shared() else {
            closeScopedURLs()
            NSSound.beep()
            return
        }

        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated {
            previewURLs.count
        }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated {
            previewURLs[index] as NSURL
        }
    }

    nonisolated func previewPanelDidClose(_ panel: QLPreviewPanel!) {
        Task { @MainActor in
            closeScopedURLs()
        }
    }

    private func closeScopedURLs() {
        scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        scopedURLs.removeAll()
    }
}
