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

    func downloadMascot(_ slug: String) async {
        guard !isMascotDownloaded(slug) else { return }

        // Fetch template
        guard let url = URL(string: "\(MascotTemplate.apiBaseURL)/\(slug)") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(MascotTemplate.self, from: data)
            saveCachedTemplate(data: data, slug: slug)

            // Download all loop videos (skip transitions for speed)
            await MascotVideoCache.shared.preloadLoopVideos(for: decoded)

            await MainActor.run {
                downloadedSlugs.insert(slug)
            }
        } catch {
            // Download failed silently
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
        guard let url = URL(string: "\(MascotTemplate.apiBaseURL)/\(slug)") else {
            loadError = "Invalid URL"
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(MascotTemplate.self, from: data)
            saveCachedTemplate(data: data, slug: slug)
            applyTemplate(decoded)
            downloadedSlugs.insert(slug)
            Task { await MascotVideoCache.shared.preloadLoopVideos(for: decoded) }
        } catch {
            if template == nil { loadError = error.localizedDescription }
        }
    }

    private func applyTemplate(_ newTemplate: MascotTemplate) {
        template = newTemplate

        if let thumb = newTemplate.thumbnail, let url = URL(string: thumb) {
            thumbnailURL = url
        }

        let initialNode = newTemplate.node(byID: newTemplate.initialNode) ?? newTemplate.nodes.first
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
        let dir = caches.appendingPathComponent("DynamicIsland/MascotTemplates", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func loadCachedTemplate(slug: String) -> MascotTemplate? {
        let file = templateCacheDirectory.appendingPathComponent("\(slug).json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(MascotTemplate.self, from: data)
    }

    private func saveCachedTemplate(data: Data, slug: String) {
        let file = templateCacheDirectory.appendingPathComponent("\(slug).json")
        try? data.write(to: file, options: .atomic)
    }
}
