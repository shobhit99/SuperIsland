import Foundation

struct ExtensionManifest: Codable, Identifiable, Hashable {
    struct Author: Codable, Hashable {
        var name: String
        var url: String?
    }

    struct Capabilities: Codable, Hashable {
        var compact: Bool = true
        var expanded: Bool = true
        var fullExpanded: Bool = true
        var minimalCompact: Bool = false
        var backgroundRefresh: Bool = true
        var settings: Bool = true
    }

    let id: String
    let name: String
    let version: String
    let minAppVersion: String
    let main: String
    let author: Author?
    let description: String
    let icon: String?
    let license: String?
    let categories: [String]
    let permissions: [String]
    let capabilities: Capabilities
    let refreshInterval: TimeInterval
    let activationTriggers: [String]

    var bundleURL: URL
    var settingsURL: URL?

    var entryURL: URL {
        bundleURL.appendingPathComponent(main)
    }

    var iconURL: URL? {
        guard let icon, !icon.isEmpty else { return nil }

        if icon.hasPrefix("/") {
            return URL(fileURLWithPath: icon)
        }

        return bundleURL.appendingPathComponent(icon)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case version
        case minAppVersion
        case main
        case author
        case description
        case icon
        case license
        case categories
        case permissions
        case capabilities
        case refreshInterval
        case activationTriggers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decode(String.self, forKey: .version)
        minAppVersion = try container.decodeIfPresent(String.self, forKey: .minAppVersion) ?? "1.0.0"
        main = try container.decodeIfPresent(String.self, forKey: .main) ?? "index.js"
        author = try container.decodeIfPresent(Author.self, forKey: .author)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        license = try container.decodeIfPresent(String.self, forKey: .license)
        categories = try container.decodeIfPresent([String].self, forKey: .categories) ?? []
        permissions = try container.decodeIfPresent([String].self, forKey: .permissions) ?? []
        capabilities = try container.decodeIfPresent(Capabilities.self, forKey: .capabilities) ?? Capabilities()
        refreshInterval = max(0.1, try container.decodeIfPresent(Double.self, forKey: .refreshInterval) ?? 1.0)
        activationTriggers = try container.decodeIfPresent([String].self, forKey: .activationTriggers) ?? ["manual"]

        bundleURL = URL(fileURLWithPath: "/")
        settingsURL = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(version, forKey: .version)
        try container.encode(minAppVersion, forKey: .minAppVersion)
        try container.encode(main, forKey: .main)
        try container.encodeIfPresent(author, forKey: .author)
        try container.encode(description, forKey: .description)
        try container.encodeIfPresent(icon, forKey: .icon)
        try container.encodeIfPresent(license, forKey: .license)
        try container.encode(categories, forKey: .categories)
        try container.encode(permissions, forKey: .permissions)
        try container.encode(capabilities, forKey: .capabilities)
        try container.encode(refreshInterval, forKey: .refreshInterval)
        try container.encode(activationTriggers, forKey: .activationTriggers)
    }

    enum ManifestError: LocalizedError {
        case missingManifest(URL)
        case missingEntry(URL)
        case invalidSource(URL)

        var errorDescription: String? {
            switch self {
            case .missingManifest(let directory):
                return "Missing manifest.json in \(directory.path)"
            case .missingEntry(let file):
                return "Missing extension entry file: \(file.lastPathComponent)"
            case .invalidSource(let url):
                return "Unsupported extension source: \(url.path)"
            }
        }
    }

    static func load(from directory: URL) throws -> ExtensionManifest {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw ManifestError.missingManifest(directory)
        }

        let data = try Data(contentsOf: manifestURL)
        var manifest = try JSONDecoder().decode(ExtensionManifest.self, from: data)
        manifest.bundleURL = directory

        let settingsURL = directory.appendingPathComponent("settings.json")
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            manifest.settingsURL = settingsURL
        }

        guard FileManager.default.fileExists(atPath: manifest.entryURL.path) else {
            throw ManifestError.missingEntry(manifest.entryURL)
        }

        return manifest
    }
}
