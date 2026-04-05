import SwiftUI
import Combine
import AVFoundation

@MainActor
final class MascotManager: ObservableObject {
    static let shared = MascotManager()

    @AppStorage("mascot.selected") var selectedSlug: String = "otto"
    @AppStorage("mascot.showInPomodoro") var showInPomodoro: Bool = true

    @Published private(set) var template: MascotTemplate?
    @Published private(set) var currentNodeID: String?
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?

    // Current video URL for the view layer (loop only, no transitions for instant switching)
    @Published private(set) var currentLoopVideoURL: URL?
    @Published private(set) var thumbnailURL: URL?

    // Download status per slug
    @Published var downloadedSlugs: Set<String> = []

    // Expression-to-node mapping
    @Published var currentExpression: String = "idle" {
        didSet {
            guard oldValue != currentExpression else { return }
            transitionToNode(forExpression: currentExpression)
        }
    }

    // Each expression maps to candidate node names (tried in order, case-insensitive)
    private let expressionToNodeCandidates: [String: [String]] = [
        "idle": ["idle"],
        "working": ["working"],
        "alert": ["permission", "needs attention", "alert"],
        "happy": ["idle"],
        "tired": ["thinking", "idle"],
        "clicked": ["needs attention", "idle"]
    ]

    var availableMascots: [MascotCatalogEntry] {
        MascotTemplate.remoteTemplates
    }

    var currentTemplateName: String {
        template?.name ?? selectedSlug.capitalized
    }

    private init() {
        refreshDownloadedSlugs()
        Task {
            await loadTemplate(slug: selectedSlug)
        }
    }

    func selectMascot(_ slug: String) {
        guard slug != selectedSlug else { return }
        selectedSlug = slug
        template = nil
        currentNodeID = nil
        currentLoopVideoURL = nil
        thumbnailURL = nil
        Task {
            await loadTemplate(slug: slug)
        }
    }

    func setExpression(_ expression: String) {
        currentExpression = expression
    }

    func setInput(_ name: String, _ value: Any) {
        switch name {
        case "isWorking":
            if let boolValue = value as? Bool, boolValue { setExpression("working") }
        case "isIdle":
            if let boolValue = value as? Bool, boolValue { setExpression("idle") }
        case "isAlert":
            if let boolValue = value as? Bool, boolValue { setExpression("alert") }
        case "clicked":
            setExpression("clicked")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                if self?.currentExpression == "clicked" { self?.setExpression("idle") }
            }
        default:
            break
        }
    }

    // MARK: - Download Management

    func isMascotDownloaded(_ slug: String) -> Bool {
        if slug == "otto" { return true } // Bundled
        return downloadedSlugs.contains(slug)
    }

    @discardableResult
    func downloadMascot(_ slug: String) async -> Bool {
        guard !isMascotDownloaded(slug) else { return true }

        do {
            let (decoded, data) = try await fetchTemplate(slug: slug)
            saveCachedTemplate(data: data, slug: slug)

            // Download all loop videos (skip transitions for speed)
            await MascotVideoCache.shared.preloadLoopVideos(for: decoded)

            downloadedSlugs.insert(slug)
            loadError = nil
            return true
        } catch {
            loadError = error.localizedDescription
            return false
        }
    }

    private func refreshDownloadedSlugs() {
        var slugs: Set<String> = ["otto"]
        for entry in MascotTemplate.remoteTemplates {
            if loadCachedTemplate(slug: entry.slug) != nil {
                slugs.insert(entry.slug)
            }
        }
        downloadedSlugs = slugs
    }

    // MARK: - Template Loading

    func loadTemplate(slug: String) async {
        isLoading = true
        loadError = nil

        // Otto: try bundled first
        if slug == "otto", let bundled = loadBundledTemplate() {
            applyTemplate(bundled)
            isLoading = false
            // Preload videos in background
            Task { await MascotVideoCache.shared.preloadLoopVideos(for: bundled) }
            return
        }

        // Try local cache
        if let cached = loadCachedTemplate(slug: slug) {
            applyTemplate(cached)
            isLoading = false
            Task { await MascotVideoCache.shared.preloadLoopVideos(for: cached) }
            return
        }

        // Fetch from API
        await fetchAndCacheTemplate(slug: slug)
        isLoading = false
    }

    private func fetchAndCacheTemplate(slug: String) async {
        do {
            let (decoded, data) = try await fetchTemplate(slug: slug)
            saveCachedTemplate(data: data, slug: slug)
            applyTemplate(decoded)
            downloadedSlugs.insert(slug)
            loadError = nil
            Task { await MascotVideoCache.shared.preloadLoopVideos(for: decoded) }
        } catch {
            if template == nil { loadError = error.localizedDescription }
        }
    }

    private func applyTemplate(_ newTemplate: MascotTemplate) {
        template = newTemplate

        let initialNode = newTemplate.node(byID: newTemplate.initialNode) ?? newTemplate.nodes.first
        if let thumb = newTemplate.thumbnail ?? initialNode?.transparentThumbnailUrl,
           let url = URL(string: thumb) {
            thumbnailURL = url
        }
        if let initialNode {
            currentNodeID = initialNode.id
            resolveLoopVideo(for: initialNode.id)
        }

        transitionToNode(forExpression: currentExpression)
    }

    // MARK: - State Machine (instant switching, no transition videos)

    private func transitionToNode(forExpression expression: String) {
        guard let template else { return }

        let candidates = expressionToNodeCandidates[expression] ?? ["idle"]
        guard let targetNode = candidates.lazy.compactMap({ template.node(named: $0) }).first
                ?? template.node(named: "idle")
                ?? template.nodes.first else { return }
        guard targetNode.id != currentNodeID else { return }

        currentNodeID = targetNode.id
        resolveLoopVideo(for: targetNode.id)
    }

    private func resolveLoopVideo(for nodeID: String) {
        guard let template else { return }
        guard let loopEdge = template.loopEdge(for: nodeID),
              let hevcURL = loopEdge.videos?.hevcURL else {
            currentLoopVideoURL = nil
            return
        }

        Task {
            let localURL = try? await MascotVideoCache.shared.ensureCached(remoteURL: hevcURL)
            await MainActor.run {
                self.currentLoopVideoURL = localURL ?? hevcURL
            }
        }
    }

    // MARK: - Bundled Otto

    private func loadBundledTemplate() -> MascotTemplate? {
        guard let url = Bundle.main.url(forResource: "otto", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MascotTemplate.self, from: data)
    }

    // MARK: - Local Cache

    private var templateCacheDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("SuperIsland/MascotTemplates", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func loadCachedTemplate(slug: String) -> MascotTemplate? {
        let file = templateCacheDirectory.appendingPathComponent("\(slug).json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return decodeTemplate(from: data, slug: slug)
    }

    private func saveCachedTemplate(data: Data, slug: String) {
        let file = templateCacheDirectory.appendingPathComponent("\(slug).json")
        try? data.write(to: file, options: .atomic)
    }

    private func fetchTemplate(slug: String) async throws -> (MascotTemplate, Data) {
        guard let url = URL(string: "\(MascotTemplate.apiBaseURL)/\(slug)") else {
            throw MascotLoadError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response: response)
        guard let template = decodeTemplate(from: data, slug: slug) else {
            throw MascotLoadError.invalidTemplate
        }
        return (template, data)
    }

    private func decodeTemplate(from data: Data, slug: String) -> MascotTemplate? {
        // The live API payload no longer includes `slug`, so we preserve the requested slug here.
        (try? JSONDecoder().decode(MascotTemplate.self, from: data))?.resolved(slug: slug)
    }

    private func validate(response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else { return }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw MascotLoadError.httpStatus(httpResponse.statusCode)
        }
    }
}

private enum MascotLoadError: LocalizedError {
    case invalidURL
    case invalidTemplate
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Couldn't build the mascot download URL."
        case .invalidTemplate:
            return "The mascot template response couldn't be read."
        case .httpStatus(let statusCode):
            return "The mascot service returned HTTP \(statusCode)."
        }
    }
}
