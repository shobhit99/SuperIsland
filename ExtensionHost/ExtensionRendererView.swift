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
                .frame(
                    maxWidth: .infinity,
                    maxHeight: displayMode == .fullExpanded ? .infinity : nil,
                    alignment: .topLeading
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
        case .text(let value, let style, let color, let lineLimit):
            Text(value)
                .font(style.font)
                .foregroundStyle(color.swiftUI)
                .lineLimit(lineLimit)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)

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

        case .hstack(let spacing, let align, let distribution, let children):
            HStack(alignment: verticalAlignment(from: align), spacing: spacing) {
                ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                    if distribution == "fillEqually" {
                        ViewNodeRenderer(node: child, extensionID: extensionID)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    } else {
                        ViewNodeRenderer(node: child, extensionID: extensionID)
                    }
                }
            }

        case .vstack(let spacing, let align, let distribution, let children):
            VStack(alignment: horizontalAlignment(from: align), spacing: spacing) {
                ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                    if distribution == "fillEqually" {
                        ViewNodeRenderer(node: child, extensionID: extensionID)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    } else {
                        ViewNodeRenderer(node: child, extensionID: extensionID)
                    }
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

        case .scroll(let child, let axes, let showsIndicators):
            ScrollView(axisSet(from: axes), showsIndicators: showsIndicators) {
                ViewNodeRenderer(node: child, extensionID: extensionID)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }

        case .progress(let value, let total, let color):
            ProgressView(value: value, total: total)
                .tint(color.swiftUI)

        case .circularProgress(let value, let total, let lineWidth, let color):
            ExtensionCircularProgressNode(
                value: value,
                total: total,
                lineWidth: lineWidth,
                color: color.swiftUI
            )

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

        case .inputBox(let inputID, let placeholder, let text, let actionID, let autoFocus, let minHeight, let showsEmojiButton):
            ExtensionInputBoxNode(
                extensionID: extensionID,
                inputID: inputID,
                placeholder: placeholder,
                text: text,
                actionID: actionID,
                autoFocus: autoFocus,
                minHeight: minHeight,
                showsEmojiButton: showsEmojiButton
            )
            .id(inputID.isEmpty ? "\(extensionID)-\(actionID)" : inputID)

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

        case .frame(let child, let width, let height, let maxWidth, let maxHeight, let alignment):
            ViewNodeRenderer(node: child, extensionID: extensionID)
                .frame(
                    width: width.map { CGFloat($0) },
                    height: height.map { CGFloat($0) },
                    alignment: frameAlignment(from: alignment)
                )
                .frame(
                    maxWidth: maxWidth.map { CGFloat($0) },
                    maxHeight: maxHeight.map { CGFloat($0) },
                    alignment: frameAlignment(from: alignment)
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

    private func axisSet(from value: String) -> Axis.Set {
        switch value {
        case "horizontal":
            return .horizontal
        case "both":
            return [.horizontal, .vertical]
        default:
            return .vertical
        }
    }

    private func frameAlignment(from value: String) -> Alignment {
        switch value {
        case "leading": return .leading
        case "trailing": return .trailing
        case "top": return .top
        case "bottom": return .bottom
        case "topLeading": return .topLeading
        case "topTrailing": return .topTrailing
        case "bottomLeading": return .bottomLeading
        case "bottomTrailing": return .bottomTrailing
        default: return .center
        }
    }
}

private struct ExtensionCircularProgressNode: View {
    let value: Double
    let total: Double
    let lineWidth: Double
    let color: Color

    private var normalizedProgress: Double {
        guard total > 0 else { return 0 }
        let raw = value / total
        return min(1, max(0, raw))
    }

    private var strokeWidth: CGFloat {
        max(1, CGFloat(lineWidth))
    }

    private var diameter: CGFloat {
        max(10, strokeWidth * 4)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.18), lineWidth: strokeWidth)

            Circle()
                .trim(from: 0, to: normalizedProgress)
                .stroke(
                    color,
                    style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.2), value: normalizedProgress)
        }
        .frame(width: diameter, height: diameter)
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

private struct ExtensionInputBoxNode: View {
    let extensionID: String
    let inputID: String
    let placeholder: String
    let text: String
    let actionID: String
    let autoFocus: Bool
    let minHeight: Double
    let showsEmojiButton: Bool

    private var boxHeight: CGFloat {
        CGFloat(max(46, minHeight))
    }

    @ObservedObject private var manager = ExtensionManager.shared
    @State private var localText: String
    @State private var shouldFocus: Bool = false
    @State private var shouldOpenEmojiPicker: Bool = false

    init(
        extensionID: String,
        inputID: String,
        placeholder: String,
        text: String,
        actionID: String,
        autoFocus: Bool,
        minHeight: Double,
        showsEmojiButton: Bool
    ) {
        self.extensionID = extensionID
        self.inputID = inputID
        self.placeholder = placeholder
        self.text = text
        self.actionID = actionID
        self.autoFocus = autoFocus
        self.minHeight = minHeight
        self.showsEmojiButton = showsEmojiButton
        _localText = State(initialValue: text)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ExtensionInputTextView(
                text: $localText,
                shouldFocus: $shouldFocus,
                shouldOpenEmojiPicker: $shouldOpenEmojiPicker,
                fixedHeight: boxHeight
            ) {
                submit()
            }
            .padding(.trailing, showsEmojiButton ? 30 : 0)
            if localText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(placeholder)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.34))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .padding(.trailing, showsEmojiButton ? 30 : 0)
                    .allowsHitTesting(false)
            }
        }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: boxHeight, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.white.opacity(0.08), lineWidth: 1)
            )
            .overlay(alignment: .bottomTrailing) {
                if showsEmojiButton {
                    Button {
                        shouldFocus = true
                        shouldOpenEmojiPicker = true
                    } label: {
                        Image(systemName: "face.smiling")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.72))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 10)
                    .padding(.bottom, 8)
                }
            }
            .onChange(of: text) { _, newValue in
                if newValue != localText {
                    localText = newValue
                }
            }
            .onAppear {
                guard autoFocus else { return }
                DispatchQueue.main.async {
                    shouldFocus = true
                }
            }
    }

    private func submit() {
        let trimmed = localText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        manager.handleAction(extensionID: extensionID, actionID: actionID, value: trimmed)
        localText = ""
        shouldFocus = true
    }
}

private struct ExtensionInputTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var shouldFocus: Bool
    @Binding var shouldOpenEmojiPicker: Bool

    let fixedHeight: CGFloat
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            shouldFocus: $shouldFocus,
            shouldOpenEmojiPicker: $shouldOpenEmojiPicker,
            onSubmit: onSubmit
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .none

        let textView = SubmitAwareTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.usesFindBar = false
        textView.usesFontPanel = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.font = .systemFont(ofSize: 12, weight: .medium)
        textView.textColor = .white
        textView.insertionPointColor = .white
        textView.caretWidth = 1
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.onSubmit = {
            context.coordinator.handleSubmit()
        }

        if let textContainer = textView.textContainer {
            textContainer.widthTracksTextView = true
            textContainer.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
            textContainer.lineFragmentPadding = 0
        }

        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: fixedHeight)
        textView.translatesAutoresizingMaskIntoConstraints = true
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentView.automaticallyAdjustsContentInsets = false

        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }

        if textView.string != text {
            textView.string = text
        }

        if let textContainer = textView.textContainer {
            textContainer.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
        }

        textView.minSize = NSSize(width: 0, height: fixedHeight)

        if shouldFocus, textView.window?.firstResponder !== textView {
            textView.window?.makeKeyAndOrderFront(nil)
            textView.window?.makeFirstResponder(textView)
            DispatchQueue.main.async {
                shouldFocus = false
            }
        }

        if shouldOpenEmojiPicker {
            textView.window?.makeKeyAndOrderFront(nil)
            textView.window?.makeFirstResponder(textView)
            DispatchQueue.main.async {
                NSApp.orderFrontCharacterPalette(nil)
                shouldOpenEmojiPicker = false
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String
        @Binding private var shouldFocus: Bool
        @Binding private var shouldOpenEmojiPicker: Bool
        let onSubmit: () -> Void

        weak var textView: SubmitAwareTextView?

        init(
            text: Binding<String>,
            shouldFocus: Binding<Bool>,
            shouldOpenEmojiPicker: Binding<Bool>,
            onSubmit: @escaping () -> Void
        ) {
            _text = text
            _shouldFocus = shouldFocus
            _shouldOpenEmojiPicker = shouldOpenEmojiPicker
            self.onSubmit = onSubmit
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            text = textView.string
        }

        func handleSubmit() {
            onSubmit()
            shouldFocus = true
            shouldOpenEmojiPicker = false
        }
    }
}

private final class SubmitAwareTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var caretWidth: CGFloat = 1

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn && !modifiers.contains(.shift) {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        let width = max(1, min(caretWidth, rect.width))
        let adjustedRect = NSRect(
            x: rect.midX - (width / 2),
            y: rect.minY,
            width: width,
            height: rect.height
        )
        super.drawInsertionPoint(in: adjustedRect, color: color, turnedOn: flag)
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
