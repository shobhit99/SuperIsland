import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var islandWindowController: IslandWindowController?
    private var statusItem: NSStatusItem?
    private static var fallbackSettingsWindowController: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupIslandWindow()
        setupMenuBar()
        initializeManagers()
    }

    // MARK: - Manager Initialization

    private func initializeManagers() {
        let state = AppState.shared

        // Eagerly initialize all enabled managers so they start monitoring
        if state.nowPlayingEnabled { _ = NowPlayingManager.shared }
        if state.volumeHUDEnabled { _ = VolumeManager.shared }
        if state.brightnessHUDEnabled { _ = BrightnessManager.shared }
        if state.batteryEnabled { _ = BatteryManager.shared }
        if state.connectivityEnabled { _ = BluetoothManager.shared; _ = WiFiManager.shared }
        if state.calendarEnabled { _ = CalendarManager.shared }
        if state.weatherEnabled { _ = WeatherManager.shared }
        if state.notificationsEnabled { _ = NotificationManager.shared }

        let extensions = ExtensionManager.shared
        extensions.discoverExtensions()
        extensions.activateDiscoveredExtensions()
    }

    // MARK: - Island Window

    private func setupIslandWindow() {
        islandWindowController = IslandWindowController()
        islandWindowController?.showIsland()
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        guard AppState.shared.showMenuBarIcon else { return }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: Constants.menuBarIconName, accessibilityDescription: "DynamicIsland")
        }

        let menu = NSMenu()
        menu.addItem(makeMenuItem(title: "Now Playing", action: #selector(showNowPlaying)))
        menu.addItem(makeMenuItem(title: "Battery", action: #selector(showBattery)))
        menu.addItem(NSMenuItem.separator())

        let modulesItem = NSMenuItem(title: "Modules", action: nil, keyEquivalent: "")
        let modulesMenu = NSMenu()
        for module in ModuleType.allCases {
            let item = NSMenuItem(title: module.displayName, action: #selector(toggleModule(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = module.rawValue
            item.state = AppState.shared.isModuleEnabled(module) ? .on : .off
            modulesMenu.addItem(item)
        }
        modulesItem.submenu = modulesMenu
        menu.addItem(modulesItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeMenuItem(title: "Quit DynamicIsland", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem?.menu = menu
    }

    private func makeMenuItem(title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    // MARK: - Menu Actions

    @objc private func showNowPlaying() {
        AppState.shared.showHUD(module: .nowPlaying, autoDismiss: false)
    }

    @objc private func showBattery() {
        AppState.shared.showHUD(module: .battery, autoDismiss: false)
    }

    @objc private func toggleModule(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let module = ModuleType(rawValue: rawValue) else { return }

        let newState = !AppState.shared.isModuleEnabled(module)
        switch module {
        case .nowPlaying: AppState.shared.nowPlayingEnabled = newState
        case .volumeHUD: AppState.shared.volumeHUDEnabled = newState
        case .brightnessHUD: AppState.shared.brightnessHUDEnabled = newState
        case .battery: AppState.shared.batteryEnabled = newState
        case .connectivity: AppState.shared.connectivityEnabled = newState
        case .calendar: AppState.shared.calendarEnabled = newState
        case .weather: AppState.shared.weatherEnabled = newState
        case .notifications: AppState.shared.notificationsEnabled = newState
        }
        sender.state = newState ? .on : .off
    }

    @objc private func openSettings() {
        // NSStatusItem menu actions run while the menu is still tracking.
        // Defer window presentation to the next runloop tick so it reliably appears.
        DispatchQueue.main.async {
            Self.showSettingsWindow()
        }
    }

    static func showSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        // Avoid opening the SwiftUI Settings scene via AppKit selectors in menu-bar mode.
        // macOS may reject those calls with a "use SettingsLink" warning.
        showFallbackSettingsWindow()
    }

    private static func showFallbackSettingsWindow() {
        if let window = fallbackSettingsWindowController?.window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let rootView = SettingsView()
            .environmentObject(AppState.shared)
        let hostingController = NSHostingController(rootView: rootView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "DynamicIsland Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 480, height: 400))
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)

        fallbackSettingsWindowController = NSWindowController(window: window)
        fallbackSettingsWindowController?.showWindow(nil)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
