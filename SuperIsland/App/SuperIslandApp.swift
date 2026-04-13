import SwiftUI

@main
struct SuperIslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject private var appState = AppState.shared

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(AppState.shared)
        }
        .commands {
            CommandGroup(replacing: .appTermination) {
                if appState.quitHotkeyEnabled {
                    Button("Quit SuperIsland") {
                        NSApp.terminate(nil)
                    }
                    .keyboardShortcut("q")
                } else {
                    Button("Quit SuperIsland") {
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }
}
