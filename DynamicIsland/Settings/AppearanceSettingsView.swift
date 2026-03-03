import SwiftUI

struct AppearanceSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section("Shape") {
                HStack {
                    Text("Corner Radius")
                    Slider(value: $appState.cornerRadius, in: 8...30, step: 1)
                    Text("\(Int(appState.cornerRadius))")
                        .frame(width: 30)
                }
            }

            Section("Opacity") {
                HStack {
                    Text("Idle Opacity")
                    Slider(value: $appState.idleOpacity, in: 0.1...1.0, step: 0.05)
                    Text("\(Int(appState.idleOpacity * 100))%")
                        .frame(width: 40)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
