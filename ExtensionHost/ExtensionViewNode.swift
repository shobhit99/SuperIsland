import JavaScriptCore
import SwiftUI

enum ExtensionTextStyle: String {
    case largeTitle
    case title
    case body
    case caption
    case footnote
    case monospaced
    case monospacedSmall

    var font: Font {
        switch self {
        case .largeTitle:
            return .system(size: 22, weight: .bold)
        case .title:
            return .system(size: 15, weight: .semibold)
        case .body:
            return .system(size: 13)
        case .caption:
            return .system(size: 11, weight: .medium)
        case .footnote:
            return .system(size: 10)
        case .monospaced:
            return .system(size: 14, weight: .medium, design: .monospaced)
        case .monospacedSmall:
            return .system(size: 11, weight: .medium, design: .monospaced)
        }
    }
}

enum ExtensionAnimationKind: String {
    case pulse
    case bounce
    case spin
    case blink
}

enum ExtensionColorValue: Hashable {
    case named(String)
    case rgba(r: Double, g: Double, b: Double, a: Double)

    var swiftUIColor: Color {
        switch self {
        case .named(let name):
            switch name {
            case "gray": return .gray
            case "red": return .red
            case "green": return .green
            case "blue": return .blue
            case "yellow": return .yellow
            case "orange": return .orange
            case "purple": return .purple
            case "pink": return .pink
            case "teal": return .teal
            case "cyan": return .cyan
            default: return .white
            }
        case .rgba(let r, let g, let b, let a):
            return Color(red: r / 255, green: g / 255, blue: b / 255, opacity: a)
        }
    }

    static func from(_ jsValue: JSValue?) -> ExtensionColorValue {
        guard let jsValue, !jsValue.isUndefined, !jsValue.isNull else {
            return .named("white")
        }

        if let name = jsValue.toString() {
            return .named(name)
        }

        let r = jsValue.forProperty("r")?.toDouble() ?? 255
        let g = jsValue.forProperty("g")?.toDouble() ?? 255
        let b = jsValue.forProperty("b")?.toDouble() ?? 255
        let a = jsValue.forProperty("a")?.toDouble() ?? 1
        return .rgba(r: r, g: g, b: b, a: a)
    }
}

enum ExtensionHorizontalAlignmentValue {
    case leading
    case center
    case trailing

    var swiftUI: HorizontalAlignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

enum ExtensionVerticalAlignmentValue {
    case top
    case center
    case bottom

    var swiftUI: VerticalAlignment {
        switch self {
        case .top: return .top
        case .center: return .center
        case .bottom: return .bottom
        }
    }
}

indirect enum ExtensionViewNode {
    case hstack(spacing: CGFloat, alignment: ExtensionVerticalAlignmentValue, children: [ExtensionViewNode])
    case vstack(spacing: CGFloat, alignment: ExtensionHorizontalAlignmentValue, children: [ExtensionViewNode])
    case zstack(children: [ExtensionViewNode])
    case spacer(minLength: CGFloat?)
    case text(String, style: ExtensionTextStyle, color: ExtensionColorValue)
    case icon(name: String, size: CGFloat, color: ExtensionColorValue)
    case image(url: String, width: CGFloat, height: CGFloat, cornerRadius: CGFloat)
    case progress(value: Double, total: Double, color: ExtensionColorValue)
    case circularProgress(value: Double, total: Double, lineWidth: CGFloat, color: ExtensionColorValue)
    case gauge(value: Double, min: Double, max: Double, label: String?)
    case divider
    case button(label: ExtensionViewNode, actionID: String)
    case toggle(isOn: Bool, label: String, actionID: String)
    case slider(value: Double, min: Double, max: Double, actionID: String)
    case padding(ExtensionViewNode, edges: Edge.Set, amount: CGFloat)
    case frame(ExtensionViewNode, width: CGFloat?, height: CGFloat?, maxWidth: CGFloat?, maxHeight: CGFloat?)
    case opacity(ExtensionViewNode, Double)
    case background(ExtensionViewNode, ExtensionColorValue)
    case cornerRadius(ExtensionViewNode, CGFloat)
    case animation(ExtensionViewNode, ExtensionAnimationKind)
    case empty

    static func from(_ jsValue: JSValue?) -> ExtensionViewNode? {
        guard let jsValue, !jsValue.isUndefined, !jsValue.isNull else {
            return .empty
        }

        guard let type = jsValue.forProperty("type")?.toString() else {
            return nil
        }

        switch type {
        case "hstack":
            let spacing = cgFloat(jsValue.forProperty("spacing")) ?? 8
            return .hstack(
                spacing: spacing,
                alignment: parseVerticalAlignment(jsValue.forProperty("align")?.toString()),
                children: parseChildren(jsValue.forProperty("children"))
            )
        case "vstack":
            let spacing = cgFloat(jsValue.forProperty("spacing")) ?? 4
            return .vstack(
                spacing: spacing,
                alignment: parseHorizontalAlignment(jsValue.forProperty("align")?.toString()),
                children: parseChildren(jsValue.forProperty("children"))
            )
        case "zstack":
            return .zstack(children: parseChildren(jsValue.forProperty("children")))
        case "spacer":
            return .spacer(minLength: cgFloat(jsValue.forProperty("minLength")))
        case "text":
            return .text(
                jsValue.forProperty("value")?.toString() ?? "",
                style: ExtensionTextStyle(rawValue: jsValue.forProperty("style")?.toString() ?? "body") ?? .body,
                color: .from(jsValue.forProperty("color"))
            )
        case "icon":
            return .icon(
                name: jsValue.forProperty("name")?.toString() ?? "questionmark",
                size: cgFloat(jsValue.forProperty("size")) ?? 14,
                color: .from(jsValue.forProperty("color"))
            )
        case "image":
            let url = jsValue.forProperty("url")?.toString() ?? ""
            let width = cgFloat(jsValue.forProperty("width")) ?? 24
            let height = cgFloat(jsValue.forProperty("height")) ?? 24
            let cornerRadius = cgFloat(jsValue.forProperty("cornerRadius")) ?? 0
            return .image(url: url, width: width, height: height, cornerRadius: cornerRadius)
        case "progress":
            return .progress(
                value: jsValue.forProperty("value")?.toDouble() ?? 0,
                total: jsValue.forProperty("total")?.toDouble() ?? 1,
                color: .from(jsValue.forProperty("color"))
            )
        case "circular-progress":
            let lineWidth = cgFloat(jsValue.forProperty("lineWidth")) ?? 3
            return .circularProgress(
                value: jsValue.forProperty("value")?.toDouble() ?? 0,
                total: jsValue.forProperty("total")?.toDouble() ?? 1,
                lineWidth: lineWidth,
                color: .from(jsValue.forProperty("color"))
            )
        case "gauge":
            return .gauge(
                value: jsValue.forProperty("value")?.toDouble() ?? 0,
                min: jsValue.forProperty("min")?.toDouble() ?? 0,
                max: jsValue.forProperty("max")?.toDouble() ?? 1,
                label: jsValue.forProperty("label")?.toString()
            )
        case "divider":
            return .divider
        case "button":
            return .button(
                label: ExtensionViewNode.from(jsValue.forProperty("label")) ?? .empty,
                actionID: jsValue.forProperty("action")?.toString() ?? ""
            )
        case "toggle":
            return .toggle(
                isOn: jsValue.forProperty("isOn")?.toBool() ?? false,
                label: jsValue.forProperty("label")?.toString() ?? "",
                actionID: jsValue.forProperty("action")?.toString() ?? ""
            )
        case "slider":
            return .slider(
                value: jsValue.forProperty("value")?.toDouble() ?? 0,
                min: jsValue.forProperty("min")?.toDouble() ?? 0,
                max: jsValue.forProperty("max")?.toDouble() ?? 1,
                actionID: jsValue.forProperty("action")?.toString() ?? ""
            )
        case "padding":
            let amount = cgFloat(jsValue.forProperty("amount")) ?? 8
            return .padding(
                ExtensionViewNode.from(jsValue.forProperty("child")) ?? .empty,
                edges: parseEdges(jsValue.forProperty("edges")?.toString()),
                amount: amount
            )
        case "frame":
            let child = ExtensionViewNode.from(jsValue.forProperty("child")) ?? .empty
            let width = cgFloat(jsValue.forProperty("width"))
            let height = cgFloat(jsValue.forProperty("height"))
            let maxWidth = cgFloat(jsValue.forProperty("maxWidth"))
            let maxHeight = cgFloat(jsValue.forProperty("maxHeight"))
            return .frame(child, width: width, height: height, maxWidth: maxWidth, maxHeight: maxHeight)
        case "opacity":
            return .opacity(
                ExtensionViewNode.from(jsValue.forProperty("child")) ?? .empty,
                jsValue.forProperty("value")?.toDouble() ?? 1
            )
        case "background":
            return .background(
                ExtensionViewNode.from(jsValue.forProperty("child")) ?? .empty,
                .from(jsValue.forProperty("color"))
            )
        case "cornerRadius":
            return .cornerRadius(
                ExtensionViewNode.from(jsValue.forProperty("child")) ?? .empty,
                cgFloat(jsValue.forProperty("radius")) ?? 0
            )
        case "animation":
            return .animation(
                ExtensionViewNode.from(jsValue.forProperty("child")) ?? .empty,
                ExtensionAnimationKind(rawValue: jsValue.forProperty("kind")?.toString() ?? "pulse") ?? .pulse
            )
        case "if":
            let condition = jsValue.forProperty("condition")?.toBool() ?? false
            return ExtensionViewNode.from(condition ? jsValue.forProperty("then") : jsValue.forProperty("else")) ?? .empty
        default:
            return .empty
        }
    }

    private static func parseChildren(_ jsValue: JSValue?) -> [ExtensionViewNode] {
        guard let jsValue,
              let context = jsValue.context,
              let array = jsValue.toArray() else {
            return []
        }

        return array.compactMap { child in
            let childValue = JSValue(object: child, in: context)
            return ExtensionViewNode.from(childValue)
        }
        .filter {
            if case .empty = $0 { return false }
            return true
        }
    }

    private static func cgFloat(_ jsValue: JSValue?) -> CGFloat? {
        guard let jsValue, !jsValue.isUndefined, !jsValue.isNull else {
            return nil
        }
        return CGFloat(jsValue.toDouble())
    }

    private static func parseVerticalAlignment(_ rawValue: String?) -> ExtensionVerticalAlignmentValue {
        switch rawValue {
        case "top":
            return .top
        case "bottom":
            return .bottom
        default:
            return .center
        }
    }

    private static func parseHorizontalAlignment(_ rawValue: String?) -> ExtensionHorizontalAlignmentValue {
        switch rawValue {
        case "leading":
            return .leading
        case "trailing":
            return .trailing
        default:
            return .center
        }
    }

    private static func parseEdges(_ rawValue: String?) -> Edge.Set {
        switch rawValue {
        case "horizontal":
            return .horizontal
        case "vertical":
            return .vertical
        default:
            return .all
        }
    }
}

struct ExtensionViewState {
    let compact: ExtensionViewNode
    let expanded: ExtensionViewNode
    let fullExpanded: ExtensionViewNode?
    let minimalLeading: ExtensionViewNode?
    let minimalTrailing: ExtensionViewNode?
}
