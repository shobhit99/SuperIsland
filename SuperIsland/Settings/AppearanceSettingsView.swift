import SwiftUI

struct AppearanceSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            SettingSectionLabel(title: "Shape")
            SettingGroup {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Corner Radius").font(.system(size: 13))
                        Text("Visual geometry for the island container")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    Spacer(minLength: 12)
                    StepperField(
                        value: $appState.cornerRadius,
                        step: 1,
                        range: 8...30
                    ) { "\(Int($0))" }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }

            SettingSectionLabel(title: "Opacity")
            SettingGroup {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Idle Opacity").font(.system(size: 13))
                        Text("Visibility strength when idle")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    Spacer(minLength: 12)
                    StepperField(
                        value: $appState.idleOpacity,
                        step: 0.05,
                        range: 0.1...1.0
                    ) { "\(Int(($0 * 100).rounded()))%" }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
