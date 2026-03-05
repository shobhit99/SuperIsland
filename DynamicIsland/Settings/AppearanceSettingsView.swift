import SwiftUI

struct AppearanceSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                SettingsCard(
                    title: "Shape",
                    subtitle: "Visual geometry for the Dynamic Island container."
                ) {
                    HStack(spacing: 8) {
                        Text("Corner Radius")
                        Slider(value: $appState.cornerRadius, in: 8...30, step: 1)
                        Text("\(Int(appState.cornerRadius))")
                            .frame(width: 30)
                            .monospacedDigit()
                    }
                }

                SettingsCard(
                    title: "Opacity",
                    subtitle: "Adjust idle visibility strength."
                ) {
                    HStack(spacing: 8) {
                        Text("Idle Opacity")
                        Slider(value: $appState.idleOpacity, in: 0.1...1.0, step: 0.05)
                        Text("\(Int(appState.idleOpacity * 100))%")
                            .frame(width: 40)
                            .monospacedDigit()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
    }
}
