import Foundation

// MARK: - API Response Models (Codable, matches masko.ai API)

struct MascotTemplate: Codable, Equatable {
    let version: String?
    let name: String
    let slug: String
    let description: String?
    let thumbnail: String?
    let initialNode: String
    let autoPlay: Bool?
    let nodes: [MascotNode]
    let edges: [MascotEdge]

    private enum CodingKeys: String, CodingKey {
        case version
        case name
        case slug
        case description
        case thumbnail
        case initialNode
        case autoPlay
        case nodes
        case edges
    }

    init(
        version: String?,
        name: String,
        slug: String,
        description: String?,
        thumbnail: String?,
        initialNode: String,
        autoPlay: Bool?,
        nodes: [MascotNode],
        edges: [MascotEdge]
    ) {
        self.version = version
        self.name = name
        self.slug = slug
        self.description = description
        self.thumbnail = thumbnail
        self.initialNode = initialNode
        self.autoPlay = autoPlay
        self.nodes = nodes
        self.edges = edges
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        name = try container.decode(String.self, forKey: .name)
        slug = try container.decodeIfPresent(String.self, forKey: .slug) ?? ""
        description = try container.decodeIfPresent(String.self, forKey: .description)
        thumbnail = try container.decodeIfPresent(String.self, forKey: .thumbnail)
        initialNode = try container.decode(String.self, forKey: .initialNode)
        autoPlay = try container.decodeIfPresent(Bool.self, forKey: .autoPlay)
        nodes = try container.decode([MascotNode].self, forKey: .nodes)
        edges = try container.decode([MascotEdge].self, forKey: .edges)
    }

    func resolved(slug fallbackSlug: String) -> MascotTemplate {
        let resolvedSlug = slug.isEmpty ? fallbackSlug : slug
        let resolvedThumbnail = thumbnail ?? node(byID: initialNode)?.transparentThumbnailUrl ?? nodes.first?.transparentThumbnailUrl
        return MascotTemplate(
            version: version,
            name: name,
            slug: resolvedSlug,
            description: description,
            thumbnail: resolvedThumbnail,
            initialNode: initialNode,
            autoPlay: autoPlay,
            nodes: nodes,
            edges: edges
        )
    }

    func node(named name: String) -> MascotNode? {
        let lowered = name.lowercased()
        return nodes.first(where: { $0.name.lowercased() == lowered })
    }

    func node(byID id: String) -> MascotNode? {
        nodes.first(where: { $0.id == id })
    }

    func loopEdge(for nodeID: String) -> MascotEdge? {
        edges.first(where: { $0.source == nodeID && $0.target == nodeID && $0.isLoop })
    }

    func transitionEdge(from sourceID: String, to targetID: String) -> MascotEdge? {
        edges.first(where: { $0.source == sourceID && $0.target == targetID && !$0.isLoop })
    }
}

struct MascotNode: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let transparentThumbnailUrl: String?
}

struct MascotEdge: Codable, Equatable, Identifiable {
    let id: String
    let source: String
    let target: String
    let isLoop: Bool
    let duration: Double?
    let conditions: [MascotCondition]?
    let videos: MascotVideos?
}

struct MascotCondition: Codable, Equatable {
    let input: String
    let op: String
    let value: CodableValue

    enum CodingKeys: String, CodingKey {
        case input, op, value
    }
}

struct MascotVideos: Codable, Equatable {
    let webm: String?
    let hevc: String?

    var hevcURL: URL? {
        guard let hevc else { return nil }
        return URL(string: hevc)
    }
}

// MARK: - CodableValue (handles bool/number/string in conditions)

enum CodableValue: Codable, Equatable {
    case bool(Bool)
    case number(Double)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let boolValue = try? container.decode(Bool.self) {
            self = .bool(boolValue)
        } else if let doubleValue = try? container.decode(Double.self) {
            self = .number(doubleValue)
        } else if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else {
            self = .bool(false)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let v): try container.encode(v)
        case .number(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        }
    }
}

// MARK: - Known mascot slugs available from masko.ai

struct MascotCatalogEntry: Identifiable {
    let slug: String
    let name: String
    let thumbnailURL: String

    var id: String { slug }
}

extension MascotTemplate {
    static let remoteTemplates: [MascotCatalogEntry] = [
        MascotCatalogEntry(slug: "otto", name: "Otto", thumbnailURL: "https://assets.masko.ai/07d95e/otto-ef17/idle-needs-attention-e46716d4.png"),
        MascotCatalogEntry(slug: "masko", name: "Masko", thumbnailURL: "https://assets.masco.dev/68c972/sandsy-82ac/eat-kebab-in-a-couch-eat-kebab-in-a-couch-aa91e2c3.png"),
        MascotCatalogEntry(slug: "clippy", name: "Clippy", thumbnailURL: "https://assets.masko.ai/7fced6/clippy-0710/idle-thinking-156fa793.png"),
        MascotCatalogEntry(slug: "rusty", name: "Rusty", thumbnailURL: "https://assets.masko.ai/7fced6/rusty-9777/idle-needs-attention-be94be34.png"),
        MascotCatalogEntry(slug: "nugget", name: "Nugget", thumbnailURL: "https://assets.masko.ai/7fced6/nugget-752f/idle-a17d604d.png"),
        MascotCatalogEntry(slug: "cupidon", name: "Cupidon", thumbnailURL: "https://assets.masko.ai/07d95e/cupidon-2724/idle-fb36b91b.png"),
        MascotCatalogEntry(slug: "madame-patate", name: "Madame Patate", thumbnailURL: "https://assets.masko.ai/07d95e/madame-patate-7e0d/idle-thinking-305df681.png"),
    ]

    static let apiBaseURL = "https://masko.ai/api/mascot-templates"
}
