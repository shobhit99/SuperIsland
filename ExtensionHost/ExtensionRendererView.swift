import SwiftUI

enum ExtensionDisplayMode {
    case compact
    case expanded
    case fullExpanded
    case minimalLeading
    case minimalTrailing
}

struct ExtensionRendererView: View {
    let extensionID: String
    let displayMode: ExtensionDisplayMode

    @ObservedObject private var manager = ExtensionManager.shared

    var body: some View {
        if let state = manager.extensionStates[extensionID] {
            ViewNodeRenderer(
                node: node(for: state),
                extensionID: extensionID
            )
        } else {
            switch displayMode {
            case .minimalLeading, .minimalTrailing:
                EmptyView()
            case .compact, .expanded, .fullExpanded:
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.6)
                    .tint(.white)
            }
        }
    }

    private func node(for state: ExtensionViewState) -> ExtensionViewNode {
        switch displayMode {
        case .compact:
            return state.compact
        case .expanded:
            return state.expanded
        case .fullExpanded:
            return state.fullExpanded ?? state.expanded
        case .minimalLeading:
            return state.minimalLeading ?? .empty
        case .minimalTrailing:
            return state.minimalTrailing ?? .empty
        }
    }
}

struct ViewNodeRenderer: View {
    let node: ExtensionViewNode
    let extensionID: String

    @ViewBuilder
    var body: some View {
        render(node)
    }

    @ViewBuilder
    private func render(_ node: ExtensionViewNode) -> some View {
        switch node {
        case .hstack(let spacing, let alignment, let children):
            HStack(alignment: alignment.swiftUI, spacing: spacing) {
                ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                    ViewNodeRenderer(node: child, extensionID: extensionID)
                }
            }
        case .vstack(let spacing, let alignment, let children):
            VStack(alignment: alignment.swiftUI, spacing: spacing) {
                ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                    ViewNodeRenderer(node: child, extensionID: extensionID)
                }
            }
        case .zstack(let children):
            ZStack {
                ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                    ViewNodeRenderer(node: child, extensionID: extensionID)
                }
            }
        case .spacer(let minLength):
            Spacer(minLength: minLength)
        case .text(let value, let style, let color):
            Text(value)
                .font(style.font)
                .foregroundColor(color.swiftUIColor)
                .lineLimit(2)
        case .icon(let name, let size, let color):
            Image(systemName: name)
                .font(.system(size: size))
                .foregroundColor(color.swiftUIColor)
        case .image(let urlString, let width, let height, let cornerRadius):
            if let url = URL(string: urlString), !urlString.isEmpty {
                AsyncImage(url: url) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(.white.opacity(0.08))
                }
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                EmptyView()
            }
        case .progress(let value, let total, let color):
            ProgressView(value: value, total: total)
                .tint(color.swiftUIColor)
        case .circularProgress(let value, let total, let lineWidth, let color):
            ExtensionCircularProgressView(
                progress: total == 0 ? 0 : value / total,
                lineWidth: lineWidth,
                color: color.swiftUIColor
            )
            .frame(width: 20, height: 20)
        case .gauge(let value, let min, let max, let label):
            Gauge(value: value, in: min...max) {
                if let label {
                    Text(label)
                }
            }
            .gaugeStyle(.accessoryLinear)
            .tint(.white)
        case .divider:
            Divider()
                .overlay(.white.opacity(0.2))
        case .button(let label, let actionID):
            Button {
                ExtensionManager.shared.handleAction(extensionID: extensionID, actionID: actionID)
            } label: {
                ViewNodeRenderer(node: label, extensionID: extensionID)
            }
            .buttonStyle(.plain)
        case .toggle(let isOn, let label, let actionID):
            Toggle(
                label,
                isOn: Binding(
                    get: { isOn },
                    set: { newValue in
                        ExtensionManager.shared.handleAction(
                            extensionID: extensionID,
                            actionID: actionID,
                            value: newValue
                        )
                    }
                )
            )
            .toggleStyle(.switch)
        case .slider(let value, let min, let max, let actionID):
            Slider(
                value: Binding(
                    get: { value },
                    set: { newValue in
                        ExtensionManager.shared.handleAction(
                            extensionID: extensionID,
                            actionID: actionID,
                            value: newValue
                        )
                    }
                ),
                in: min...max
            )
            .tint(.white)
        case .padding(let child, let edges, let amount):
            ViewNodeRenderer(node: child, extensionID: extensionID)
                .padding(edges, amount)
        case .frame(let child, let width, let height, let maxWidth, let maxHeight):
            ViewNodeRenderer(node: child, extensionID: extensionID)
                .frame(width: width, height: height)
                .frame(maxWidth: maxWidth, maxHeight: maxHeight)
        case .opacity(let child, let value):
            ViewNodeRenderer(node: child, extensionID: extensionID)
                .opacity(value)
        case .background(let child, let color):
            ViewNodeRenderer(node: child, extensionID: extensionID)
                .padding(2)
                .background(color.swiftUIColor)
        case .cornerRadius(let child, let radius):
            ViewNodeRenderer(node: child, extensionID: extensionID)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        case .animation(let child, let kind):
            animatedNode(child, kind: kind)
        case .empty:
            EmptyView()
        }
    }

    @ViewBuilder
    private func animatedNode(_ child: ExtensionViewNode, kind: ExtensionAnimationKind) -> some View {
        switch kind {
        case .pulse:
            ViewNodeRenderer(node: child, extensionID: extensionID)
                .symbolEffect(.pulse)
        case .bounce:
            ViewNodeRenderer(node: child, extensionID: extensionID)
                .symbolEffect(.bounce)
        case .spin:
            ViewNodeRenderer(node: child, extensionID: extensionID)
                .rotationEffect(.degrees(360))
                .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: extensionID)
        case .blink:
            ViewNodeRenderer(node: child, extensionID: extensionID)
        }
    }
}

private struct ExtensionCircularProgressView: View {
    let progress: Double
    let lineWidth: CGFloat
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0, min(progress, 1)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}
