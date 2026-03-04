import Foundation
import SwiftUI

struct ExtensionSettingsSchema: Codable, Hashable {
    let sections: [ExtensionSettingsSection]
}

struct ExtensionSettingsSection: Codable, Hashable, Identifiable {
    let title: String
    let fields: [ExtensionSettingsField]

    var id: String { title }
}

struct ExtensionSettingsOption: Codable, Hashable, Identifiable {
    let value: String
    let label: String

    var id: String { value }
}

enum ExtensionSettingsValue: Codable, Hashable {
    case bool(Bool)
    case string(String)
    case double(Double)
    case int(Int)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        }
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        switch self {
        case .double(let value):
            return value
        case .int(let value):
            return Double(value)
        default:
            return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .int(let value):
            return value
        case .double(let value):
            return Int(value)
        default:
            return nil
        }
    }
}

struct ExtensionSettingsField: Codable, Hashable, Identifiable {
    let type: String
    let key: String
    let label: String
    let min: Double?
    let max: Double?
    let step: Double?
    let options: [ExtensionSettingsOption]?
    let defaultValue: ExtensionSettingsValue?

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

    var id: String { key }
    var defaultBool: Bool { defaultValue?.boolValue ?? false }
    var defaultString: String { defaultValue?.stringValue ?? "" }
    var defaultDouble: Double { defaultValue?.doubleValue ?? min ?? 0 }
    var defaultInt: Int { defaultValue?.intValue ?? Int(min ?? 0) }
}

struct ExtensionSettingsRenderer: View {
    let extensionID: String
    let schema: ExtensionSettingsSchema

    @ObservedObject private var manager = ExtensionManager.shared

    var body: some View {
        Form {
            ForEach(schema.sections) { section in
                Section(section.title) {
                    ForEach(section.fields) { field in
                        renderField(field)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func renderField(_ field: ExtensionSettingsField) -> some View {
        switch field.type {
        case "toggle":
            Toggle(field.label, isOn: boolBinding(for: field))
        case "slider":
            VStack(alignment: .leading, spacing: 6) {
                Text(field.label)
                Slider(
                    value: doubleBinding(for: field),
                    in: (field.min ?? 0)...(field.max ?? 100),
                    step: field.step ?? 1
                )
            }
        case "stepper":
            Stepper(
                "\(field.label): \(intValue(for: field))",
                value: intBinding(for: field),
                in: Int(field.min ?? 0)...Int(field.max ?? 100),
                step: Int(field.step ?? 1)
            )
        case "picker":
            Picker(field.label, selection: stringBinding(for: field)) {
                ForEach(field.options ?? []) { option in
                    Text(option.label).tag(option.value)
                }
            }
        case "text":
            TextField(field.label, text: stringBinding(for: field))
        default:
            EmptyView()
        }
    }

    private func boolBinding(for field: ExtensionSettingsField) -> Binding<Bool> {
        Binding(
            get: {
                manager.settingValue(for: extensionID, key: field.key) as? Bool ?? field.defaultBool
            },
            set: { value in
                manager.setSettingValue(value, for: extensionID, key: field.key)
            }
        )
    }

    private func doubleBinding(for field: ExtensionSettingsField) -> Binding<Double> {
        Binding(
            get: {
                if let value = manager.settingValue(for: extensionID, key: field.key) as? Double {
                    return value
                }
                if let value = manager.settingValue(for: extensionID, key: field.key) as? Int {
                    return Double(value)
                }
                return field.defaultDouble
            },
            set: { value in
                manager.setSettingValue(value, for: extensionID, key: field.key)
            }
        )
    }

    private func intBinding(for field: ExtensionSettingsField) -> Binding<Int> {
        Binding(
            get: { intValue(for: field) },
            set: { value in
                manager.setSettingValue(value, for: extensionID, key: field.key)
            }
        )
    }

    private func stringBinding(for field: ExtensionSettingsField) -> Binding<String> {
        Binding(
            get: {
                manager.settingValue(for: extensionID, key: field.key) as? String ?? field.defaultString
            },
            set: { value in
                manager.setSettingValue(value, for: extensionID, key: field.key)
            }
        )
    }

    private func intValue(for field: ExtensionSettingsField) -> Int {
        if let int = manager.settingValue(for: extensionID, key: field.key) as? Int {
            return int
        }
        if let double = manager.settingValue(for: extensionID, key: field.key) as? Double {
            return Int(double)
        }
        return field.defaultInt
    }
}
