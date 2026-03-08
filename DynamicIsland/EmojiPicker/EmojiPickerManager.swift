import AppKit
import ApplicationServices
import Combine

final class EmojiPickerManager: ObservableObject {
    static let shared = EmojiPickerManager()

    @Published private(set) var isVisible = false
    @Published private(set) var query = ""
    @Published private(set) var results: [EmojiSearchResult] = []
    @Published private(set) var selectedIndex = 0
    @Published private(set) var bouncingEmojiID: String?

    let width: CGFloat = 320
    let columns = 6
    let maxVisibleResults = 18

    private let recentsDefaultsKey = "emojiPicker.recentEmojis"
    private let accessibilityPromptedDefaultsKey = "emojiPicker.accessibilityPrompted"
    private let syntheticEventMarker: Int64 = 0x45504A31
    private let index = EmojiSearchIndex.shared
    private lazy var windowController = EmojiPickerWindowController(manager: self)

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var mouseMonitor: Any?
    private var appObserver: Any?
    private var currentAnchor = CGPoint.zero
    private var currentScreenFrame = NSScreen.main?.visibleFrame ?? .zero
    private var pendingCommit: DispatchWorkItem?

    private init() {
        rebuildResults()
        startMonitoring()
    }

    deinit {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }

        if let appObserver {
            NotificationCenter.default.removeObserver(appObserver)
        }
    }

    var displayedResults: [EmojiSearchResult] {
        Array(results.prefix(maxVisibleResults))
    }

    var selectedResult: EmojiSearchResult? {
        let visible = displayedResults
        guard visible.indices.contains(selectedIndex) else { return visible.first }
        return visible[selectedIndex]
    }

    var footerLabel: String? {
        selectedResult?.name
    }

    var panelHeight: CGFloat {
        let count = max(displayedResults.count, results.isEmpty ? 1 : 0)
        let rows = max(1, min(3, Int(ceil(Double(count) / Double(columns)))))
        return 60 + CGFloat(rows) * 48 + 34
    }

    func hoverSelection(for emojiID: String?) {
        guard let emojiID,
              let index = displayedResults.firstIndex(where: { $0.id == emojiID }) else {
            return
        }

        selectedIndex = index
    }

    func commitSelection(index: Int? = nil) {
        let visible = displayedResults
        guard !visible.isEmpty else {
            close()
            return
        }

        let resolvedIndex = min(index ?? selectedIndex, visible.count - 1)
        let result = visible[resolvedIndex]
        selectedIndex = resolvedIndex
        bouncingEmojiID = result.id

        pendingCommit?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.performCommit(result)
        }
        pendingCommit = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: workItem)
    }

    private func startMonitoring() {
        ensureAccessibilityPromptIfNeeded()
        installEventTap()

        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            self?.close()
        }

        appObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.close()
        }
    }

    private func ensureAccessibilityPromptIfNeeded() {
        guard !AXIsProcessTrusted(),
              !UserDefaults.standard.bool(forKey: accessibilityPromptedDefaultsKey) else {
            return
        }

        UserDefaults.standard.set(true, forKey: accessibilityPromptedDefaultsKey)
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func installEventTap() {
        guard eventTap == nil else { return }

        let mask = (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<EmojiPickerManager>.fromOpaque(refcon).takeUnretainedValue()
            return manager.handleEvent(proxy: proxy, type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }

        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handleEvent(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        if event.getIntegerValueField(.eventSourceUserData) == syntheticEventMarker {
            return Unmanaged.passUnretained(event)
        }

        let appBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if appBundleID == Bundle.main.bundleIdentifier {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let hasDisallowedModifiers = flags.contains(.maskCommand)
            || flags.contains(.maskControl)
            || flags.contains(.maskAlternate)
            || flags.contains(.maskSecondaryFn)
        let characters = event.unicodeString

        if !isVisible {
            guard !hasDisallowedModifiers, characters == ":" else {
                return Unmanaged.passUnretained(event)
            }

            DispatchQueue.main.async { [weak self] in
                self?.open()
            }
            return Unmanaged.passUnretained(event)
        }

        guard !hasDisallowedModifiers else {
            DispatchQueue.main.async { [weak self] in
                self?.close()
            }
            return Unmanaged.passUnretained(event)
        }

        switch keyCode {
        case 53:
            DispatchQueue.main.async { [weak self] in
                self?.close()
            }
            return nil

        case 48:
            DispatchQueue.main.async { [weak self] in
                self?.commitSelection(index: 0)
            }
            return nil

        case 36, 76:
            DispatchQueue.main.async { [weak self] in
                self?.commitSelection()
            }
            return nil

        case 123:
            DispatchQueue.main.async { [weak self] in
                self?.moveSelectionByColumn(-1)
            }
            return nil

        case 124:
            DispatchQueue.main.async { [weak self] in
                self?.moveSelectionByColumn(1)
            }
            return nil

        case 125:
            DispatchQueue.main.async { [weak self] in
                self?.moveSelectionByRow(1)
            }
            return nil

        case 126:
            DispatchQueue.main.async { [weak self] in
                self?.moveSelectionByRow(-1)
            }
            return nil

        case 51:
            DispatchQueue.main.async { [weak self] in
                self?.handleBackspace()
            }
            return Unmanaged.passUnretained(event)

        default:
            break
        }

        guard let characters else {
            return Unmanaged.passUnretained(event)
        }

        DispatchQueue.main.async { [weak self] in
            self?.handleTypedCharacters(characters)
        }
        return Unmanaged.passUnretained(event)
    }

    private func open() {
        query = ""
        selectedIndex = 0
        bouncingEmojiID = nil
        updateAnchor()
        rebuildResults()
        isVisible = true
        windowController.show(anchor: currentAnchor, screenFrame: currentScreenFrame, height: panelHeight)
    }

    private func close() {
        pendingCommit?.cancel()
        pendingCommit = nil
        guard isVisible else { return }
        bouncingEmojiID = nil
        isVisible = false
        windowController.hide()
    }

    private func handleTypedCharacters(_ characters: String) {
        guard isVisible else { return }

        if characters == ":" {
            open()
            return
        }

        let normalized = EmojiSearchIndex.normalize(characters)
        guard !normalized.isEmpty else {
            close()
            return
        }

        query.append(contentsOf: normalized.replacingOccurrences(of: " ", with: ""))
        selectedIndex = 0
        updateAnchor()
        rebuildResults()
        syncWindow()
    }

    private func handleBackspace() {
        guard isVisible else { return }

        if query.isEmpty {
            close()
            return
        }

        query.removeLast()
        selectedIndex = 0
        updateAnchor()
        rebuildResults()
        syncWindow()
    }

    private func moveSelectionByColumn(_ delta: Int) {
        let visible = displayedResults
        guard !visible.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + visible.count) % visible.count
    }

    private func moveSelectionByRow(_ delta: Int) {
        let visible = displayedResults
        guard !visible.isEmpty else { return }
        let next = selectedIndex + (delta * columns)
        selectedIndex = min(max(0, next), visible.count - 1)
    }

    private func rebuildResults() {
        results = index.search(query: query, recents: recentEmojis(), limit: maxVisibleResults)
        if results.isEmpty {
            selectedIndex = 0
        } else {
            selectedIndex = min(selectedIndex, results.count - 1)
        }
    }

    private func performCommit(_ result: EmojiSearchResult) {
        close()
        replaceTypedToken(with: result.emoji)
        storeRecent(result.emoji)
    }

    private func replaceTypedToken(with emoji: String) {
        let deleteCount = query.count + 1
        for _ in 0..<deleteCount {
            postKeyPress(keyCode: 51)
        }
        postUnicodeString(emoji)
    }

    private func storeRecent(_ emoji: String) {
        var recents = recentEmojis().filter { $0 != emoji }
        recents.insert(emoji, at: 0)
        UserDefaults.standard.set(Array(recents.prefix(24)), forKey: recentsDefaultsKey)
    }

    private func recentEmojis() -> [String] {
        UserDefaults.standard.stringArray(forKey: recentsDefaultsKey) ?? []
    }

    private func postKeyPress(keyCode: CGKeyCode) {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return
        }

        keyDown.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        keyUp.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private func postUnicodeString(_ string: String) {
        let utf16 = Array(string.utf16)
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            return
        }

        keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        keyUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        keyDown.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        keyUp.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private func updateAnchor() {
        guard let anchor = CaretLocator.currentAnchor() else { return }
        currentAnchor = anchor.point
        currentScreenFrame = anchor.screenFrame
    }

    private func syncWindow() {
        guard isVisible else { return }
        windowController.show(anchor: currentAnchor, screenFrame: currentScreenFrame, height: panelHeight)
    }
}

private struct CaretAnchor {
    let point: CGPoint
    let screenFrame: CGRect
}

private enum CaretLocator {
    static func currentAnchor() -> CaretAnchor? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focusedElement = focusedValue else {
            return fallbackAnchor()
        }

        let element = focusedElement as! AXUIElement
        if let rect = selectedRangeBounds(for: element) ?? elementBounds(for: element),
           let anchor = anchor(from: rect) {
            return anchor
        }

        return fallbackAnchor()
    }

    private static func selectedRangeBounds(for element: AXUIElement) -> CGRect? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let rawValue = value else {
            return nil
        }
        let rangeValue = rawValue as! AXValue
        guard AXValueGetType(rangeValue) == .cfRange else { return nil }

        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range) else {
            return nil
        }

        var insertionRange = CFRange(location: range.location, length: 0)
        guard let parameter = AXValueCreate(.cfRange, &insertionRange),
              AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXBoundsForRangeParameterizedAttribute as CFString,
                parameter,
                &value
              ) == .success,
              let boundsRawValue = value else {
            return nil
        }
        let boundsValue = boundsRawValue as! AXValue
        guard AXValueGetType(boundsValue) == .cgRect else { return nil }

        var rect = CGRect.zero
        return AXValueGetValue(boundsValue, .cgRect, &rect) ? rect : nil
    }

    private static func elementBounds(for element: AXUIElement) -> CGRect? {
        guard let point = pointValue(element: element, attribute: kAXPositionAttribute as CFString) else {
            return nil
        }

        let size = sizeValue(element: element, attribute: kAXSizeAttribute as CFString) ?? CGSize(width: 2, height: 22)
        return CGRect(origin: point, size: size)
    }

    private static func pointValue(element: AXUIElement, attribute: CFString) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let rawValue = value else {
            return nil
        }
        let axValue = rawValue as! AXValue
        guard AXValueGetType(axValue) == .cgPoint else { return nil }

        var point = CGPoint.zero
        return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
    }

    private static func sizeValue(element: AXUIElement, attribute: CFString) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let rawValue = value else {
            return nil
        }
        let axValue = rawValue as! AXValue
        guard AXValueGetType(axValue) == .cgSize else { return nil }

        var size = CGSize.zero
        return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
    }

    private static func anchor(from rect: CGRect) -> CaretAnchor? {
        let normalizedRect = normalizeAccessibilityRect(rect)
        let anchorPoint = CGPoint(x: normalizedRect.midX, y: normalizedRect.minY)
        guard let screen = screen(containing: anchorPoint) else {
            return fallbackAnchor()
        }

        return CaretAnchor(point: anchorPoint, screenFrame: screen.visibleFrame)
    }

    private static func normalizeAccessibilityRect(_ rect: CGRect) -> CGRect {
        if screen(containing: CGPoint(x: rect.midX, y: rect.midY)) != nil {
            return rect
        }

        for screen in NSScreen.screens {
            let flipped = CGRect(
                x: rect.origin.x,
                y: screen.frame.maxY - rect.origin.y - rect.height,
                width: rect.width,
                height: rect.height
            )

            if screen.frame.contains(CGPoint(x: flipped.midX, y: flipped.midY)) {
                return flipped
            }
        }

        return rect
    }

    private static func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first(where: { $0.frame.contains(point) })
    }

    private static func fallbackAnchor() -> CaretAnchor? {
        let mouse = NSEvent.mouseLocation
        guard let screen = screen(containing: mouse) ?? NSScreen.main else { return nil }
        let point = CGPoint(x: mouse.x, y: mouse.y - 8)
        return CaretAnchor(point: point, screenFrame: screen.visibleFrame)
    }
}

private extension CGEvent {
    var unicodeString: String? {
        var length = 0
        keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &length, unicodeString: nil)
        guard length > 0 else { return nil }

        var buffer = Array<UniChar>(repeating: 0, count: length)
        keyboardGetUnicodeString(maxStringLength: length, actualStringLength: &length, unicodeString: &buffer)
        return String(utf16CodeUnits: buffer, count: length)
    }
}
