import SwiftUI
import JavaScriptCore

struct ExtensionViewState {
    var compact: ViewNode
    var expanded: ViewNode
    var fullExpanded: ViewNode?
    var minimalLeading: ViewNode?
    var minimalTrailing: ViewNode?
}

enum DisplayMode {
    case compact
    case expanded
    case fullExpanded
    case minimalLeading
    case minimalTrailing
}

enum ColorValue: Equatable {
    case named(String)
    case rgba(r: Double, g: Double, b: Double, a: Double)

    var swiftUI: Color {
        switch self {
        case .named(let value):
            switch value {
            case "white": return .white
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
            return Color(
                red: clamp(r, min: 0, max: 1),
                green: clamp(g, min: 0, max: 1),
                blue: clamp(b, min: 0, max: 1),
                opacity: clamp(a, min: 0, max: 1)
            )
        }
    }

    private func clamp(_ value: Double, min: Double, max: Double) -> Double {
        Swift.max(min, Swift.min(max, value))
    }
}

enum TextStyle: String {
    case largeTitle
    case title
    case headline
    case body
    case caption
    case footnote
    case monospaced
    case monospacedSmall

    var font: Font {
        switch self {
        case .largeTitle:
            return .system(size: 26, weight: .semibold)
        case .title:
            return .system(size: 16, weight: .semibold)
        case .headline:
            return .system(size: 14, weight: .semibold)
        case .body:
            return .system(size: 13)
        case .caption:
            return .system(size: 11)
        case .footnote:
            return .system(size: 10)
        case .monospaced:
            return .system(size: 14, weight: .medium, design: .monospaced)
        case .monospacedSmall:
            return .system(size: 11, weight: .regular, design: .monospaced)
        }
    }
}

indirect enum ViewNode: Equatable {
    case hstack(spacing: Double, align: String, distribution: String, children: [ViewNode])
    case vstack(spacing: Double, align: String, distribution: String, children: [ViewNode])
    case zstack(children: [ViewNode])
    case spacer(minLength: Double?)
    case scroll(child: ViewNode, axes: String, showsIndicators: Bool)

    case text(String, style: TextStyle, color: ColorValue, lineLimit: Int?)
    case icon(name: String, size: Double, color: ColorValue)
    case image(url: String, width: Double, height: Double, cornerRadius: Double)
    case progress(value: Double, total: Double, color: ColorValue)
    case circularProgress(value: Double, total: Double, lineWidth: Double, color: ColorValue)
    case gauge(value: Double, min: Double, max: Double, label: String?)
    case divider

    case button(label: ViewNode, actionID: String)
    case inputBox(id: String, placeholder: String, text: String, actionID: String, autoFocus: Bool, minHeight: Double, showsEmojiButton: Bool)
    case toggle(isOn: Bool, label: String, actionID: String)
    case slider(value: Double, min: Double, max: Double, actionID: String)

    case padding(child: ViewNode, edges: String, amount: Double)
    case frame(child: ViewNode, width: Double?, height: Double?, maxWidth: Double?, maxHeight: Double?, alignment: String)
    case opacity(child: ViewNode, value: Double)
    case background(child: ViewNode, color: ColorValue)
    case cornerRadius(child: ViewNode, radius: Double)
    case animation(child: ViewNode, kind: String)

    case empty

    static func from(_ value: JSValue?) -> ViewNode? {
        guard let value else {
            return .empty
        }
        if value.isNull || value.isUndefined {
            return .empty
        }

        guard let type = value.forProperty("type")?.toString() else {
            return .empty
        }

        switch type {
        case "hstack":
            return .hstack(
                spacing: value.forProperty("spacing")?.toDouble() ?? 8,
                align: value.forProperty("align")?.toString() ?? "center",
                distribution: value.forProperty("distribution")?.toString() ?? "natural",
                children: parseChildren(value.forProperty("children"))
            )

        case "vstack":
            return .vstack(
                spacing: value.forProperty("spacing")?.toDouble() ?? 4,
                align: value.forProperty("align")?.toString() ?? "center",
                distribution: value.forProperty("distribution")?.toString() ?? "natural",
                children: parseChildren(value.forProperty("children"))
            )

        case "zstack":
            return .zstack(children: parseChildren(value.forProperty("children")))

        case "spacer":
            let minLength = value.forProperty("minLength")?.isUndefined == false
                ? value.forProperty("minLength")?.toDouble()
                : nil
            return .spacer(minLength: minLength)

        case "scroll":
            return .scroll(
                child: ViewNode.from(value.forProperty("child")) ?? .empty,
                axes: value.forProperty("axes")?.toString() ?? "vertical",
                showsIndicators: value.forProperty("showsIndicators")?.isBoolean == true
                    ? (value.forProperty("showsIndicators")?.toBool() ?? true)
                    : true
            )

        case "text":
            let style = TextStyle(rawValue: value.forProperty("style")?.toString() ?? "body") ?? .body
            return .text(
                value.forProperty("value")?.toString() ?? "",
                style: style,
                color: parseColor(value.forProperty("color")),
                lineLimit: propertyInt(value, key: "lineLimit")
            )

        case "icon":
            return .icon(
                name: value.forProperty("name")?.toString() ?? "questionmark",
                size: value.forProperty("size")?.toDouble() ?? 14,
                color: parseColor(value.forProperty("color"))
            )

        case "image":
            return .image(
                url: value.forProperty("url")?.toString() ?? "",
                width: value.forProperty("width")?.toDouble() ?? 16,
                height: value.forProperty("height")?.toDouble() ?? 16,
                cornerRadius: value.forProperty("cornerRadius")?.toDouble() ?? 0
            )

        case "progress":
            return .progress(
                value: value.forProperty("value")?.toDouble() ?? 0,
                total: value.forProperty("total")?.toDouble() ?? 1,
                color: parseColor(value.forProperty("color"))
            )

        case "circular-progress":
            return .circularProgress(
                value: value.forProperty("value")?.toDouble() ?? 0,
                total: value.forProperty("total")?.toDouble() ?? 1,
                lineWidth: value.forProperty("lineWidth")?.toDouble() ?? 3,
                color: parseColor(value.forProperty("color"))
            )

        case "gauge":
            return .gauge(
                value: value.forProperty("value")?.toDouble() ?? 0,
                min: value.forProperty("min")?.toDouble() ?? 0,
                max: value.forProperty("max")?.toDouble() ?? 1,
                label: value.forProperty("label")?.toString()
            )

        case "divider":
            return .divider

        case "button":
            return .button(
                label: ViewNode.from(value.forProperty("label")) ?? .empty,
                actionID: value.forProperty("action")?.toString() ?? ""
            )

        case "input-box":
            let inputID = value.forProperty("id")?.toString() ?? ""
            let placeholder = value.forProperty("placeholder")?.toString() ?? ""
            let text = value.forProperty("text")?.toString() ?? ""
            let actionID = value.forProperty("action")?.toString() ?? ""
            let autoFocus = value.forProperty("autoFocus")?.isBoolean == true
                ? (value.forProperty("autoFocus")?.toBool() ?? true)
                : true
            let minHeight = value.forProperty("minHeight")?.toDouble() ?? 72
            let showsEmojiButton = value.forProperty("showsEmojiButton")?.isBoolean == true
                ? (value.forProperty("showsEmojiButton")?.toBool() ?? false)
                : false
            return .inputBox(
                id: inputID,
                placeholder: placeholder,
                text: text,
                actionID: actionID,
                autoFocus: autoFocus,
                minHeight: minHeight,
                showsEmojiButton: showsEmojiButton
            )

        case "toggle":
            return .toggle(
                isOn: value.forProperty("isOn")?.toBool() ?? false,
                label: value.forProperty("label")?.toString() ?? "",
                actionID: value.forProperty("action")?.toString() ?? ""
            )

        case "slider":
            return .slider(
                value: value.forProperty("value")?.toDouble() ?? 0,
                min: value.forProperty("min")?.toDouble() ?? 0,
                max: value.forProperty("max")?.toDouble() ?? 1,
                actionID: value.forProperty("action")?.toString() ?? ""
            )

        case "padding":
            return .padding(
                child: ViewNode.from(value.forProperty("child")) ?? .empty,
                edges: value.forProperty("edges")?.toString() ?? "all",
                amount: value.forProperty("amount")?.toDouble() ?? 8
            )

        case "frame":
            return .frame(
                child: ViewNode.from(value.forProperty("child")) ?? .empty,
                width: propertyDouble(value, key: "width"),
                height: propertyDouble(value, key: "height"),
                maxWidth: propertyDouble(value, key: "maxWidth"),
                maxHeight: propertyDouble(value, key: "maxHeight"),
                alignment: value.forProperty("alignment")?.toString() ?? "center"
            )

        case "opacity":
            return .opacity(
                child: ViewNode.from(value.forProperty("child")) ?? .empty,
                value: value.forProperty("value")?.toDouble() ?? 1
            )

        case "background":
            return .background(
                child: ViewNode.from(value.forProperty("child")) ?? .empty,
                color: parseColor(value.forProperty("color"))
            )

        case "cornerRadius":
            return .cornerRadius(
                child: ViewNode.from(value.forProperty("child")) ?? .empty,
                radius: value.forProperty("radius")?.toDouble() ?? 0
            )

        case "animation":
            return .animation(
                child: ViewNode.from(value.forProperty("child")) ?? .empty,
                kind: value.forProperty("kind")?.toString() ?? "pulse"
            )

        case "if":
            let condition = value.forProperty("condition")?.toBool() ?? false
            if condition {
                return ViewNode.from(value.forProperty("then")) ?? .empty
            }
            return ViewNode.from(value.forProperty("else")) ?? .empty

        default:
            return .empty
        }
    }

    private static func propertyDouble(_ value: JSValue, key: String) -> Double? {
        guard let property = value.forProperty(key), !property.isUndefined, !property.isNull else {
            return nil
        }
        return property.toDouble()
    }

    private static func propertyInt(_ value: JSValue, key: String) -> Int? {
        guard let property = value.forProperty(key), !property.isUndefined, !property.isNull else {
            return nil
        }
        let number = Int(property.toInt32())
        return number > 0 ? number : nil
    }

    private static func parseChildren(_ value: JSValue?) -> [ViewNode] {
        guard let value, !value.isUndefined, !value.isNull else {
            return []
        }

        let count = Int(value.forProperty("length")?.toInt32() ?? 0)
        guard count > 0 else {
            return []
        }

        var children: [ViewNode] = []
        children.reserveCapacity(count)

        for index in 0..<count {
            let childValue = value.atIndex(index)
            if let child = ViewNode.from(childValue) {
                children.append(child)
            }
        }

        return children
    }

    private static func parseColor(_ value: JSValue?) -> ColorValue {
        guard let value, !value.isUndefined, !value.isNull else {
            return .named("white")
        }

        if let string = value.toString(), value.isString {
            return .named(string)
        }

        let r = value.forProperty("r")?.toDouble() ?? 1
        let g = value.forProperty("g")?.toDouble() ?? 1
        let b = value.forProperty("b")?.toDouble() ?? 1
        let a = value.forProperty("a")?.toDouble() ?? 1
        return .rgba(r: r, g: g, b: b, a: a)
    }
}
