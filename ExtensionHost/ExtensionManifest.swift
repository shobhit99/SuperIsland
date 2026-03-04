import Foundation

struct ExtensionAuthor: Codable, Hashable {
    let name: String
    let url: String?
}

struct ExtensionCapabilities: Codable, Hashable {
    let compact: Bool
    let expanded: Bool
    let fullExpanded: Bool
    let minimalCompact: Bool?
    let backgroundRefresh: Bool
    let settings: Bool
}

struct ExtensionManifest: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let version: String
    let minAppVersion: String?
    let main: String
    let author: ExtensionAuthor?
    let description: String
    let icon: String?
    let license: String?
    let categories: [String]
    let permissions: [String]
    let capabilities: ExtensionCapabilities?
    let refreshInterval: Double?
    let activationTriggers: [String]
    let bundleURL: URL

    enum CodingKeys: String, CodingKey {
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
        minAppVersion = try container.decodeIfPresent(String.self, forKey: .minAppVersion)
        main = try container.decode(String.self, forKey: .main)
        author = try container.decodeIfPresent(ExtensionAuthor.self, forKey: .author)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        license = try container.decodeIfPresent(String.self, forKey: .license)
        categories = try container.decodeIfPresent([String].self, forKey: .categories) ?? []
        permissions = try container.decodeIfPresent([String].self, forKey: .permissions) ?? []
        capabilities = try container.decodeIfPresent(ExtensionCapabilities.self, forKey: .capabilities)
        refreshInterval = try container.decodeIfPresent(Double.self, forKey: .refreshInterval)
        activationTriggers = try container.decodeIfPresent([String].self, forKey: .activationTriggers) ?? []
        bundleURL = URL(fileURLWithPath: "/")
    }

    init(
        id: String,
        name: String,
        version: String,
        minAppVersion: String?,
        main: String,
        author: ExtensionAuthor?,
        description: String,
        icon: String?,
        license: String?,
        categories: [String],
        permissions: [String],
        capabilities: ExtensionCapabilities?,
        refreshInterval: Double?,
        activationTriggers: [String],
        bundleURL: URL
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.minAppVersion = minAppVersion
        self.main = main
        self.author = author
        self.description = description
        self.icon = icon
        self.license = license
        self.categories = categories
        self.permissions = permissions
        self.capabilities = capabilities
        self.refreshInterval = refreshInterval
        self.activationTriggers = activationTriggers
        self.bundleURL = bundleURL
    }

    var mainFileURL: URL {
        bundleURL.appending(path: main)
    }

    var settingsURL: URL {
        bundleURL.appending(path: "settings.json")
    }

    var iconURL: URL? {
        guard let icon else { return nil }
        return bundleURL.appending(path: icon)
    }

    var effectiveRefreshInterval: TimeInterval {
        let interval = refreshInterval ?? 1.0
        return max(0.1, interval)
    }

    var supportsMinimalCompact: Bool {
        capabilities?.minimalCompact ?? false
    }

    static func load(from bundleURL: URL) throws -> ExtensionManifest {
        let manifestURL = bundleURL.appending(path: "manifest.json")
        let data = try Data(contentsOf: manifestURL)
        let decoded = try JSONDecoder().decode(ExtensionManifest.self, from: data)
        return ExtensionManifest(
            id: decoded.id,
            name: decoded.name,
            version: decoded.version,
            minAppVersion: decoded.minAppVersion,
            main: decoded.main,
            author: decoded.author,
            description: decoded.description,
            icon: decoded.icon,
            license: decoded.license,
            categories: decoded.categories,
            permissions: decoded.permissions,
            capabilities: decoded.capabilities,
            refreshInterval: decoded.refreshInterval,
            activationTriggers: decoded.activationTriggers,
            bundleURL: bundleURL
        )
    }
}

enum ExtensionInstallError: LocalizedError {
    case unsupportedSource
    case manifestMissing
    case invalidBundleName

    var errorDescription: String? {
        switch self {
        case .unsupportedSource:
            return "Only unpacked extension directories are supported right now."
        case .manifestMissing:
            return "The extension directory is missing manifest.json."
        case .invalidBundleName:
            return "The extension bundle directory name is invalid."
        }
    }
}
