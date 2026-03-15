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

enum ExtensionSettingsStore {
    private static func namespacedKey(extensionID: String, key: String) -> String {
        "extensions.\(extensionID).settings.\(key)"
    }

    static func value(extensionID: String, key: String) -> Any? {
        UserDefaults.standard.object(forKey: namespacedKey(extensionID: extensionID, key: key))
    }

    static func set(_ value: Any?, extensionID: String, key: String) {
        let nsKey = namespacedKey(extensionID: extensionID, key: key)
        if let value {
            UserDefaults.standard.set(value, forKey: nsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: nsKey)
        }
    }
}

struct ExtensionSettingsRenderer: View {
    let extensionID: String
    let schema: SettingsSchema

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
                if let value = ExtensionSettingsStore.value(extensionID: extensionID, key: field.key) as? Bool {
                    return value
                }
                return field.defaultBool
            },
            set: { newValue in
                ExtensionSettingsStore.set(newValue, extensionID: extensionID, key: field.key)
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
                ExtensionSettingsStore.set(newValue, extensionID: extensionID, key: field.key)
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
                ExtensionSettingsStore.set(newValue, extensionID: extensionID, key: field.key)
            }
        )
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
