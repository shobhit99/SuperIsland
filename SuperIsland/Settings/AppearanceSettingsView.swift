import SwiftUI

struct AppearanceSettingsView: View {
    @EnvironmentObject var appState: AppState

    // Canonical defaults — source of truth for the per-section Reset buttons
    // and for the @AppStorage initial values in AppState.
    private enum Defaults {
        static let bounceAmount: Double = 0.25
        static let compactIslandWidth: Double = 200
        static let compactIslandHeight: Double = 36
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            section(
                title: "Animation",
                reset: {
                    appState.bounceAmount = Defaults.bounceAmount
                }
            ) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bounce").font(.system(size: 13))
                        Text("Spring bounce for compact ↔ expanded transitions")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    Spacer(minLength: 12)
                    StepperField(
                        value: $appState.bounceAmount,
                        step: 0.05,
                        range: 0.0...0.5
                    ) { "\(Int(($0 * 100).rounded()))%" }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }

            section(
                title: "Compact Island Size",
                reset: {
                    appState.compactIslandWidth = Defaults.compactIslandWidth
                    appState.compactIslandHeight = Defaults.compactIslandHeight
                }
            ) {
                sizeRow(
                    title: "Width",
                    description: "Pill width on notched Macs",
                    value: $appState.compactIslandWidth,
                    step: 2,
                    range: 140...320,
                    unit: "pt"
                )
                SettingRowDivider()
                sizeRow(
                    title: "Height",
                    description: "Pill height on notched Macs",
                    value: $appState.compactIslandHeight,
                    step: 1,
                    range: 28...60,
                    unit: "pt"
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func section<Content: View>(
        title: String,
        reset: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            SettingSectionLabel(title: title)
            Button("Reset", action: reset)
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(.accentColor)
        }
        SettingGroup {
            content()
        }
    }

    private func sizeRow(
        title: String,
        description: String,
        value: Binding<Double>,
        step: Double,
        range: ClosedRange<Double>,
        unit: String
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                Text(description)
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer(minLength: 12)
            StepperField(
                value: value,
                step: step,
                range: range
            ) { "\(Int($0.rounded())) \(unit)" }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}
