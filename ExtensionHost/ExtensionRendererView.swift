import SwiftUI

struct ExtensionRendererView: View {
    let extensionID: String
    let displayMode: DisplayMode

    @ObservedObject private var manager = ExtensionManager.shared

    var body: some View {
        Group {
            if let state = manager.extensionStates[extensionID] {
                ViewNodeRenderer(
                    node: node(from: state),
                    extensionID: extensionID
                )
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            }
        }
    }

    private func node(from state: ExtensionViewState) -> ViewNode {
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
    let node: ViewNode
    let extensionID: String

    @ObservedObject private var manager = ExtensionManager.shared

    @ViewBuilder
    var body: some View {
        switch node {
        case .text(let value, let style, let color):
            Text(value)
                .font(style.font)
                .foregroundStyle(color.swiftUI)

        case .icon(let name, let size, let color):
            Image(systemName: name)
                .font(.system(size: size))
                .foregroundStyle(color.swiftUI)

        case .image(let urlString, let width, let height, let cornerRadius):
            if let url = URL(string: urlString) {
                AsyncImage(url: url) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    Color.white.opacity(0.1)
                }
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            } else {
                Color.clear
                    .frame(width: width, height: height)
            }

        case .hstack(let spacing, let align, let children):
            HStack(alignment: verticalAlignment(from: align), spacing: spacing) {
                ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                    ViewNodeRenderer(node: child, extensionID: extensionID)
                }
            }

        case .vstack(let spacing, let align, let children):
            VStack(alignment: horizontalAlignment(from: align), spacing: spacing) {
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
            Spacer(minLength: minLength.map { CGFloat($0) })

        case .progress(let value, let total, let color):
            ProgressView(value: value, total: total)
                .tint(color.swiftUI)

        case .circularProgress(let value, let total, let lineWidth, let color):
            ProgressView(value: value, total: total)
                .progressViewStyle(.circular)
                .tint(color.swiftUI)
                .scaleEffect(max(0.5, lineWidth / 4))

        case .gauge(let value, let min, let max, let label):
            Gauge(value: value, in: min...max) {
                Text(label ?? "")
            }

        case .divider:
            Divider()

        case .button(let label, let actionID):
            Button {
                manager.handleAction(extensionID: extensionID, actionID: actionID)
            } label: {
                ViewNodeRenderer(node: label, extensionID: extensionID)
            }
            .buttonStyle(.plain)

        case .toggle(let isOn, let label, let actionID):
            ExtensionToggleNode(
                extensionID: extensionID,
                label: label,
                isOn: isOn,
                actionID: actionID
            )

        case .slider(let value, let min, let max, let actionID):
            ExtensionSliderNode(
                extensionID: extensionID,
                value: value,
                min: min,
                max: max,
                actionID: actionID
            )

        case .padding(let child, let edges, let amount):
            ViewNodeRenderer(node: child, extensionID: extensionID)
                .padding(edgeSet(from: edges), amount)

        case .frame(let child, let width, let height, let maxWidth, let maxHeight):
            ViewNodeRenderer(node: child, extensionID: extensionID)
                .frame(
                    width: width.map { CGFloat($0) },
                    height: height.map { CGFloat($0) }
                )
                .frame(
                    maxWidth: maxWidth.map { CGFloat($0) },
                    maxHeight: maxHeight.map { CGFloat($0) }
                )

        case .opacity(let child, let value):
            ViewNodeRenderer(node: child, extensionID: extensionID)
                .opacity(value)

        case .background(let child, let color):
            ViewNodeRenderer(node: child, extensionID: extensionID)
                .background(color.swiftUI)

        case .cornerRadius(let child, let radius):
            ViewNodeRenderer(node: child, extensionID: extensionID)
                .clipShape(RoundedRectangle(cornerRadius: radius))

        case .animation(let child, let kind):
            ExtensionAnimatedNode(kind: kind) {
                ViewNodeRenderer(node: child, extensionID: extensionID)
            }

        case .empty:
            EmptyView()
        }
    }

    private func verticalAlignment(from value: String) -> VerticalAlignment {
        switch value {
        case "top": return .top
        case "bottom": return .bottom
        default: return .center
        }
    }

    private func horizontalAlignment(from value: String) -> HorizontalAlignment {
        switch value {
        case "leading": return .leading
        case "trailing": return .trailing
        default: return .center
        }
    }

    private func edgeSet(from value: String) -> Edge.Set {
        switch value {
        case "horizontal": return .horizontal
        case "vertical": return .vertical
        default: return .all
        }
    }
}

private struct ExtensionToggleNode: View {
    let extensionID: String
    let label: String
    let isOn: Bool
    let actionID: String

    @ObservedObject private var manager = ExtensionManager.shared
    @State private var localValue: Bool

    init(extensionID: String, label: String, isOn: Bool, actionID: String) {
        self.extensionID = extensionID
        self.label = label
        self.isOn = isOn
        self.actionID = actionID
        _localValue = State(initialValue: isOn)
    }

    var body: some View {
        Toggle(label, isOn: Binding(
            get: { localValue },
            set: { newValue in
                localValue = newValue
                manager.handleAction(extensionID: extensionID, actionID: actionID, value: newValue)
            }
        ))
        .toggleStyle(.switch)
    }
}

private struct ExtensionSliderNode: View {
    let extensionID: String
    let value: Double
    let min: Double
    let max: Double
    let actionID: String

    @ObservedObject private var manager = ExtensionManager.shared
    @State private var localValue: Double

    init(extensionID: String, value: Double, min: Double, max: Double, actionID: String) {
        self.extensionID = extensionID
        self.value = value
        self.min = min
        self.max = max
        self.actionID = actionID
        _localValue = State(initialValue: value)
    }

    var body: some View {
        Slider(
            value: Binding(
                get: { localValue },
                set: { newValue in
                    localValue = newValue
                }
            ),
            in: min...max,
            onEditingChanged: { editing in
                if !editing {
                    manager.handleAction(extensionID: extensionID, actionID: actionID, value: localValue)
                }
            }
        )
    }
}

private struct ExtensionAnimatedNode<Content: View>: View {
    let kind: String
    @ViewBuilder let content: () -> Content

    @State private var animate = false

    private var bounceAnimation: Animation {
        .easeInOut(duration: 0.5).repeatForever(autoreverses: true)
    }

    private var spinAnimation: Animation {
        .linear(duration: 1.2).repeatForever(autoreverses: false)
    }

    private var blinkAnimation: Animation {
        .easeInOut(duration: 0.45).repeatForever(autoreverses: true)
    }

    private var pulseAnimation: Animation {
        .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
    }

    var body: some View {
        switch kind {
        case "bounce":
            content()
                .scaleEffect(animate ? 1.08 : 0.92)
                .animation(bounceAnimation, value: animate)
                .onAppear { animate = true }
        case "spin":
            content()
                .rotationEffect(.degrees(animate ? 360 : 0))
                .animation(spinAnimation, value: animate)
                .onAppear { animate = true }
        case "blink":
            content()
                .opacity(animate ? 1 : 0.2)
                .animation(blinkAnimation, value: animate)
                .onAppear { animate = true }
        default:
            content()
                .opacity(animate ? 1 : 0.6)
                .animation(pulseAnimation, value: animate)
                .onAppear { animate = true }
        }
    }
}
