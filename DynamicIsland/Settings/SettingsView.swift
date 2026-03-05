import SwiftUI
import AppKit

enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case modules
    case appearance
    case extensions
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .modules: return "Modules"
        case .appearance: return "Appearance"
        case .extensions: return "Extensions"
        case .advanced: return "Advanced"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gear"
        case .modules: return "square.grid.2x2"
        case .appearance: return "paintbrush"
        case .extensions: return "puzzlepiece.extension"
        case .advanced: return "wrench.and.screwdriver"
        }
    }
}

struct SettingsView: View {
    @State private var selectedPane: SettingsPane? = .general

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )

            VStack(spacing: 0) {
                topNavigation

                Divider()
                    .opacity(0.35)

                detailPane
            }
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 2)
        .padding(.top, 0)
        .frame(minWidth: 820, idealWidth: 900, minHeight: 560, idealHeight: 620)
    }

    private var topNavigation: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                ForEach(SettingsPane.allCases) { pane in
                    topPaneButton(for: pane)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text((selectedPane ?? .general).title)
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            Divider()
                .opacity(0.35)

            detailContent
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func topPaneButton(for pane: SettingsPane) -> some View {
        let isSelected = (selectedPane ?? .general) == pane
        return Button {
            selectedPane = pane
        } label: {
            HStack(spacing: 8) {
                Image(systemName: pane.icon)
                    .font(.system(size: 13, weight: .semibold))
                Text(pane.title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.clear)
            )
            .foregroundColor(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selectedPane ?? .general {
        case .general:
            GeneralSettingsView()
        case .modules:
            ModuleSettingsView()
        case .appearance:
            AppearanceSettingsView()
        case .extensions:
            ExtensionsSettingsView()
        case .advanced:
            AdvancedSettingsView()
        }
    }
}

struct SettingsCard<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline.weight(.semibold))

            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.8))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}
