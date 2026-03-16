import Foundation

actor MascotVideoCache {
    static let shared = MascotVideoCache()

    private let cacheDirectory: URL
    private var activeDownloads: [URL: Task<URL, Error>] = [:]

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDirectory = caches.appendingPathComponent("DynamicIsland/Mascots", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    func localURL(for remoteURL: URL) -> URL {
        let filename = remoteURL.absoluteString
            .replacingOccurrences(of: "://", with: "_")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ".", with: "_")
        let ext = remoteURL.pathExtension.isEmpty ? "mov" : remoteURL.pathExtension
        return cacheDirectory.appendingPathComponent("\(filename).\(ext)")
    }

    func cachedFileURL(for remoteURL: URL) -> URL? {
        let local = localURL(for: remoteURL)
        return FileManager.default.fileExists(atPath: local.path) ? local : nil
    }

    func ensureCached(remoteURL: URL) async throws -> URL {
        if let local = cachedFileURL(for: remoteURL) {
            return local
        }

        if let existing = activeDownloads[remoteURL] {
            return try await existing.value
        }

        let task = Task<URL, Error> {
            let local = localURL(for: remoteURL)
            let (tempURL, _) = try await URLSession.shared.download(from: remoteURL)
            try? FileManager.default.removeItem(at: local)
            try FileManager.default.moveItem(at: tempURL, to: local)
            return local
        }

        activeDownloads[remoteURL] = task
        defer { activeDownloads.removeValue(forKey: remoteURL) }
        return try await task.value
    }

    func preloadVideos(for template: MascotTemplate) async {
        var urls: [URL] = []

        for edge in template.edges {
            if let hevcURL = edge.videos?.hevcURL {
                urls.append(hevcURL)
            }
        }

        await withTaskGroup(of: Void.self) { group in
            for url in urls {
                group.addTask {
                    _ = try? await self.ensureCached(remoteURL: url)
                }
            }
        }
    }

    func preloadLoopVideos(for template: MascotTemplate) async {
        var urls: [URL] = []

        for edge in template.edges where edge.isLoop {
            if let hevcURL = edge.videos?.hevcURL {
                urls.append(hevcURL)
            }
        }

        await withTaskGroup(of: Void.self) { group in
            for url in urls {
                group.addTask {
                    _ = try? await self.ensureCached(remoteURL: url)
                }
            }
        }
    }

    func clearCache() throws {
        let contents = try FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)
        for file in contents {
            try FileManager.default.removeItem(at: file)
        }
    }
}
