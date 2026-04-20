import Foundation
import SwiftUI

struct SettingsSchema: Decodable {
    var sections: [SettingsSection]

    static func load(from url: URL) throws -> SettingsSchema {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SettingsSchema.self, from: data)
    }
}

struct SettingsSection: Decodable, Identifiable {
    let title: String
    let fields: [SettingsField]

    var id: String { title }
}

struct SettingsOption: Decodable, Identifiable {
    let value: String
    let label: String

    var id: String { value }
}

enum JSONScalar: Decodable {
    case string(String)
    case bool(Bool)
    case double(Double)
    case integer(Int)
    case none

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .none
            return
        }
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? container.decode(Int.self) {
            self = .integer(value)
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .double(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }

        self = .none
    }
}

struct SettingsField: Decodable, Identifiable {
    let type: String
    let key: String
    let label: String
    let action: String?
    let enabledWhen: String?

    let min: Double?
    let max: Double?
    let step: Double?
    let options: [SettingsOption]?
    let defaultValue: JSONScalar?

    var id: String { key }

    enum CodingKeys: String, CodingKey {
        case type
        case key
        case label
        case action
        case enabledWhen
        case min
        case max
        case step
        case options
        case defaultValue = "default"
    }

    var defaultBool: Bool {
        switch defaultValue {
        case .bool(let value):
            return value
        case .integer(let value):
            return value != 0
        case .double(let value):
            return value != 0
        case .string(let value):
            return (value as NSString).boolValue
        case nil, .some(.none):
            return false
        }
    }

    var defaultDouble: Double {
        switch defaultValue {
        case .integer(let value):
            return Double(value)
        case .double(let value):
            return value
        case .bool(let value):
            return value ? 1 : 0
        case .string(let value):
            return Double(value) ?? 0
        case nil, .some(.none):
            return 0
        }
    }

    var defaultString: String {
        switch defaultValue {
        case .string(let value):
            return value
        case .integer(let value):
            return String(value)
        case .double(let value):
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case nil, .some(.none):
            return ""
        }
    }
}

/// Broadcasts "something under ExtensionSettingsStore changed" so any SwiftUI
/// view that renders extension toggles/sliders can invalidate and re-read the
/// underlying UserDefault. Without this, a custom `Binding<Bool>` backed by
/// UserDefaults has no way to notify SwiftUI — the Toggle stays frozen at
/// whatever value it first rendered, even though UserDefaults has updated.
@MainActor
final class ExtensionSettingsObserver: ObservableObject {
    static let shared = ExtensionSettingsObserver()
    @Published var version: Int = 0
    private var defaultsObserver: NSObjectProtocol?

    private init() {
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.bump()
            }
        }
    }

    deinit {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }

    fileprivate func bump() {
        version &+= 1
    }
}

enum ExtensionSettingsStore {
    private static func namespacedKey(extensionID: String, key: String) -> String {
        "extensions.\(extensionID).settings.\(key)"
    }

    static func value(extensionID: String, key: String) -> Any? {
        UserDefaults.standard.object(forKey: namespacedKey(extensionID: extensionID, key: key))
    }

    /// Bool-typed setter — used from Toggle bindings. Routed through the
    /// typed UserDefaults overload so no Any?/NSNumber bridging can silently
    /// drop a `false` write.
    static func setBool(_ value: Bool, extensionID: String, key: String) {
        let nsKey = namespacedKey(extensionID: extensionID, key: key)
        UserDefaults.standard.set(value, forKey: nsKey)
        notifyChanged(extensionID: extensionID, key: key, value: value)
    }

    static func setDouble(_ value: Double, extensionID: String, key: String) {
        let nsKey = namespacedKey(extensionID: extensionID, key: key)
        UserDefaults.standard.set(value, forKey: nsKey)
        notifyChanged(extensionID: extensionID, key: key, value: value)
    }

    static func setString(_ value: String, extensionID: String, key: String) {
        let nsKey = namespacedKey(extensionID: extensionID, key: key)
        UserDefaults.standard.set(value, forKey: nsKey)
        notifyChanged(extensionID: extensionID, key: key, value: value)
    }

    static func set(_ value: Any?, extensionID: String, key: String) {
        let nsKey = namespacedKey(extensionID: extensionID, key: key)
        switch value {
        case .none:
            UserDefaults.standard.removeObject(forKey: nsKey)
        case .some(let unwrapped):
            // Dispatch to the typed overloads explicitly for primitives.
            // Swift's `Any?` → `UserDefaults.set(_:forKey:)` bridge has been
            // the source of flaky Bool writes; this shortcut avoids it.
            if let b = unwrapped as? Bool {
                UserDefaults.standard.set(b, forKey: nsKey)
            } else if let d = unwrapped as? Double {
                UserDefaults.standard.set(d, forKey: nsKey)
            } else if let i = unwrapped as? Int {
                UserDefaults.standard.set(i, forKey: nsKey)
            } else if let s = unwrapped as? String {
                UserDefaults.standard.set(s, forKey: nsKey)
            } else {
                UserDefaults.standard.set(unwrapped, forKey: nsKey)
            }
        }
        notifyChanged(extensionID: extensionID, key: key, value: value)
    }

    private static func notifyChanged(extensionID: String, key: String, value: Any?) {
        // 1. Publish on a global observer so the settings UI can invalidate
        //    and re-read UserDefaults — keeps the Toggle's visual state in
        //    sync with the stored value.
        // 2. Fire the extension's onSettingsChanged JS hook so it can react
        //    (e.g. agents-status runs `reconcileHooks("codex", true)` here).
        DispatchQueue.main.async {
            ExtensionSettingsObserver.shared.bump()
            ExtensionManager.shared.notifySettingsChanged(
                extensionID: extensionID,
                key: key,
                value: value
            )
        }
    }
}

struct ExtensionSettingsRenderer: View {
    let extensionID: String
    let schema: SettingsSchema

    // Observe the shared settings-change publisher so Toggles/Sliders repaint
    // immediately after their binding.set fires. Without this, the custom
    // `Binding<Bool>` backed by UserDefaults has no way to tell SwiftUI to
    // invalidate the view — the checkbox stays stuck on its first-rendered
    // value even though the underlying store updated.
    @ObservedObject private var observer = ExtensionSettingsObserver.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(schema.sections) { section in
                VStack(alignment: .leading, spacing: 8) {
                    Text(section.title)
                        .font(.subheadline.weight(.semibold))

                    ForEach(section.fields) { field in
                        fieldView(field)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func fieldView(_ field: SettingsField) -> some View {
        switch field.type.lowercased() {
        case "toggle":
            Toggle(field.label, isOn: boolBinding(for: field))

        case "slider":
            ExtensionSliderSettingsField(extensionID: extensionID, field: field)

        case "stepper":
            Stepper(
                "\(field.label): \(Int(doubleBinding(for: field).wrappedValue))",
                value: doubleBinding(for: field),
                in: (field.min ?? 0)...(field.max ?? 100),
                step: field.step ?? 1
            )

        case "picker":
            Picker(field.label, selection: stringBinding(for: field)) {
                ForEach(field.options ?? []) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .pickerStyle(.menu)

        case "button":
            Button(field.label) {
                let actionID = field.action.flatMap { $0.isEmpty ? nil : $0 } ?? field.key
                ExtensionManager.shared.handleAction(extensionID: extensionID, actionID: actionID)
            }
            .buttonStyle(.bordered)
            .disabled(!buttonEnabled(for: field))
            .opacity(buttonEnabled(for: field) ? 1 : 0.45)

        case "text", "color":
            VStack(alignment: .leading, spacing: 4) {
                Text(field.label)
                TextField(field.label, text: stringBinding(for: field))
                    .textFieldStyle(.roundedBorder)
            }

        default:
            Text("Unsupported setting field: \(field.type)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func boolBinding(for field: SettingsField) -> Binding<Bool> {
        Binding(
            get: {
                // Prefer bool(forKey:) over object(forKey:) as? Bool — the
                // latter has been the source of the "can't uncheck" bug on
                // some macOS versions where a stored `false` round-trips to
                // nil through NSNumber bridging.
                let nsKey = "extensions.\(extensionID).settings.\(field.key)"
                if UserDefaults.standard.object(forKey: nsKey) != nil {
                    return UserDefaults.standard.bool(forKey: nsKey)
                }
                return field.defaultBool
            },
            set: { newValue in
                ExtensionSettingsStore.setBool(newValue, extensionID: extensionID, key: field.key)
            }
        )
    }

    private func doubleBinding(for field: SettingsField) -> Binding<Double> {
        Binding(
            get: {
                if let value = ExtensionSettingsStore.value(extensionID: extensionID, key: field.key) as? Double {
                    return value
                }
                if let value = ExtensionSettingsStore.value(extensionID: extensionID, key: field.key) as? Int {
                    return Double(value)
                }
                return field.defaultDouble
            },
            set: { newValue in
                ExtensionSettingsStore.setDouble(newValue, extensionID: extensionID, key: field.key)
            }
        )
    }

    private func stringBinding(for field: SettingsField) -> Binding<String> {
        Binding(
            get: {
                if let value = ExtensionSettingsStore.value(extensionID: extensionID, key: field.key) as? String {
                    return value
                }
                return field.defaultString
            },
            set: { newValue in
                ExtensionSettingsStore.setString(newValue, extensionID: extensionID, key: field.key)
            }
        )
    }

    private func buttonEnabled(for field: SettingsField) -> Bool {
        guard let dependencyKey = field.enabledWhen, !dependencyKey.isEmpty else {
            return true
        }
        guard let value = ExtensionSettingsStore.value(extensionID: extensionID, key: dependencyKey) else {
            return false
        }
        switch value {
        case let boolValue as Bool:
            return boolValue
        case let intValue as Int:
            return intValue != 0
        case let doubleValue as Double:
            return doubleValue != 0
        case let stringValue as String:
            return (stringValue as NSString).boolValue
        default:
            return false
        }
    }
}

private struct ExtensionSliderSettingsField: View {
    let extensionID: String
    let field: SettingsField

    @State private var value: Double

    init(extensionID: String, field: SettingsField) {
        self.extensionID = extensionID
        self.field = field

        let storedValue = ExtensionSettingsStore.value(extensionID: extensionID, key: field.key)
        let resolvedValue: Double
        if let storedValue = storedValue as? Double {
            resolvedValue = storedValue
        } else if let storedValue = storedValue as? Int {
            resolvedValue = Double(storedValue)
        } else {
            resolvedValue = field.defaultDouble
        }

        let minimum = field.min ?? 0
        let maximum = field.max ?? 100
        _value = State(initialValue: min(max(resolvedValue, minimum), maximum))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(field.label)
                Spacer()
                Text(String(format: "%.0f", value))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }

            Slider(
                value: $value,
                in: (field.min ?? 0)...(field.max ?? 100),
                step: field.step ?? 1
            )
            .onChange(of: value) { _, newValue in
                ExtensionSettingsStore.set(newValue, extensionID: extensionID, key: field.key)
            }
        }
    }
}
