import AppKit
import EventKit
import SwiftUI
import UserNotifications

struct ModuleSettingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var calendarManager = CalendarManager.shared
    @ObservedObject private var notificationManager = NotificationManager.shared
    @ObservedObject private var nowPlayingManager = NowPlayingManager.shared
    @ObservedObject private var shelf = ShelfStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            SettingSectionLabel(title: "Media & HUD")
            SettingGroup {
                SettingToggleRow(title: "Now Playing", isOn: $appState.nowPlayingEnabled)
                if appState.nowPlayingEnabled {
                    SettingRowDivider()
                    SettingToggleRow(
                        title: "Browser media detection",
                        description: "Use macOS automation to detect media in allowed browsers.",
                        isOn: $nowPlayingManager.browserDetectionEnabled
                    )
                    if nowPlayingManager.browserDetectionEnabled {
                        browserMediaRows
                    }
                }
                SettingRowDivider()
                SettingToggleRow(title: "Volume HUD", isOn: $appState.volumeHUDEnabled)
            }

            SettingSectionLabel(title: "Home")
            SettingGroup {
                homeSlotRow(title: "Left slot", selection: $appState.homeLeadingPanelRaw)
                SettingRowDivider()
                homeSlotRow(title: "Center slot", selection: $appState.homeCenterPanelRaw)
                SettingRowDivider()
                homeSlotRow(title: "Right slot", selection: $appState.homeTrailingPanelRaw)
            }

            SettingSectionLabel(title: "System")
            SettingGroup {
                SettingToggleRow(title: "Battery", isOn: $appState.batteryEnabled)
                SettingRowDivider()
                SettingToggleRow(title: "Shelf", isOn: $appState.shelfEnabled)
                SettingRowDivider()
                SettingToggleRow(title: "Auto-open Shelf on Drop", isOn: $appState.shelfAutoOpenOnDrop)
                SettingRowDivider()
                shelfRetentionRow
                SettingRowDivider()
                SettingToggleRow(title: "Connectivity", isOn: $appState.connectivityEnabled)
            }

            SettingSectionLabel(title: "Information")
            SettingGroup {
                SettingToggleRow(title: "Calendar", isOn: calendarEnabledBinding)
                if appState.calendarEnabled {
                    SettingRowDivider()
                    calendarPermissionRow
                    if calendarManager.hasAccess {
                        SettingRowDivider()
                        SettingToggleRow(
                            title: "Collapse duplicate events",
                            description: "Hide repeated holidays or birthdays with the same title and time.",
                            isOn: $calendarManager.collapseDuplicates
                        )
                        SettingRowDivider()
                        SettingToggleRow(
                            title: "Hide holidays",
                            isOn: $calendarManager.hideHolidays
                        )
                        SettingRowDivider()
                        SettingToggleRow(
                            title: "Hide birthdays",
                            isOn: $calendarManager.hideBirthdays
                        )
                        SettingRowDivider()
                        calendarLookaheadRow
                        calendarSourceRows
                    }
                }
                SettingRowDivider()
                SettingToggleRow(title: "Weather", isOn: $appState.weatherEnabled)
                SettingRowDivider()
                HStack {
                    Text("Temperature Unit")
                        .font(.system(size: 13))
                    Spacer(minLength: 8)
                    Picker("", selection: $appState.temperatureUnit) {
                        Text("°C").tag(TemperatureUnit.celsius)
                        Text("°F").tag(TemperatureUnit.fahrenheit)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 90)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                SettingRowDivider()
                SettingToggleRow(title: "Notifications", isOn: notificationsEnabledBinding)
                if appState.notificationsEnabled {
                    SettingRowDivider()
                    notificationPermissionRow
                    SettingRowDivider()
                    SettingToggleRow(
                        title: "Show previews",
                        description: "Display sender and message text when available.",
                        isOn: notificationPreviewsBinding
                    )
                    SettingRowDivider()
                    notificationRetentionRow
                    ForEach(NotificationFeedSource.allCases) { source in
                        SettingRowDivider()
                        SettingToggleRow(
                            title: source.title,
                            description: source.description,
                            isOn: notificationSourceBinding(for: source)
                        )
                    }
                }
            }

            SettingSectionLabel(title: "Productivity")
            SettingGroup {
                SettingToggleRow(title: "Teleprompter", isOn: $appState.teleprompterEnabled)
                SettingRowDivider()
                HStack {
                    Text("Script")
                        .font(.system(size: 13))
                    Spacer(minLength: 8)
                    Button("Edit Script…") {
                        TeleprompterScriptEditorWindowController.show()
                    }
                    .font(.system(size: 12))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear {
            notificationManager.checkPermission()
            calendarManager.refreshAccessStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            notificationManager.checkPermission()
            calendarManager.refreshAccessStatus()
        }
    }

    private var calendarPermissionRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Calendar access")
                    .font(.system(size: 13))
                Text(calendarPermissionDescription)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(calendarPermissionButtonTitle) {
                handleCalendarPermissionAction()
            }
            .font(.system(size: 12))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var notificationPermissionRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Permission")
                    .font(.system(size: 13))
                Text(notificationPermissionDescription)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(notificationPermissionButtonTitle) {
                handleNotificationPermissionAction()
            }
            .font(.system(size: 12))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var calendarLookaheadRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Upcoming range")
                    .font(.system(size: 13))
                Text("How many days appear in the Upcoming column.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 12)
            StepperField(
                value: calendarLookaheadBinding,
                step: 1,
                range: 1...30
            ) { "\(Int($0))d" }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var notificationRetentionRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Retained items")
                    .font(.system(size: 13))
                Text("How many feed items stay available in the island.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 12)
            StepperField(
                value: notificationMaxRetainedBinding,
                step: 1,
                range: 1...50
            ) { "\(Int($0))" }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var calendarSourceRows: some View {
        if calendarManager.calendarSourceGroups.isEmpty {
            SettingRowDivider()
            Text("No calendars available")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
        } else {
            ForEach(calendarManager.calendarSourceGroups) { group in
                SettingRowDivider()
                Text(group.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 4)

                ForEach(group.calendars) { calendar in
                    calendarSourceRow(calendar)
                    if calendar.id != group.calendars.last?.id {
                        SettingRowDivider()
                    }
                }
            }
        }
    }

    private func calendarSourceRow(_ calendar: CalendarDisplayOption) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color(cgColor: calendar.color))
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 2) {
                Text(calendar.title)
                    .font(.system(size: 13))
                Text(calendarTypeLabel(calendar.type))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: calendarEnabledBinding(for: calendar.id))
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var calendarEnabledBinding: Binding<Bool> {
        Binding(
            get: { appState.calendarEnabled },
            set: { newValue in
                appState.calendarEnabled = newValue
                if newValue {
                    calendarManager.refreshAccessStatus()
                    if calendarManager.authorizationStatus == .notDetermined {
                        calendarManager.requestAccess()
                    }
                }
            }
        )
    }

    private var calendarLookaheadBinding: Binding<Double> {
        Binding(
            get: { Double(calendarManager.lookaheadDays) },
            set: { calendarManager.lookaheadDays = Int($0) }
        )
    }

    private func calendarEnabledBinding(for calendarID: String) -> Binding<Bool> {
        Binding(
            get: { calendarManager.isCalendarEnabled(calendarID) },
            set: { calendarManager.setCalendar(calendarID, enabled: $0) }
        )
    }

    private var notificationPreviewsBinding: Binding<Bool> {
        Binding(
            get: { appState.notificationPreviewsEnabled },
            set: { newValue in
                appState.notificationPreviewsEnabled = newValue
                NotificationManager.shared.applyFeedPreferences()
            }
        )
    }

    private var notificationMaxRetainedBinding: Binding<Double> {
        Binding(
            get: { appState.notificationMaxRetainedItems },
            set: { newValue in
                appState.notificationMaxRetainedItems = newValue
                NotificationManager.shared.applyFeedPreferences()
            }
        )
    }

    private var notificationsEnabledBinding: Binding<Bool> {
        Binding(
            get: { appState.notificationsEnabled },
            set: { newValue in
                appState.notificationsEnabled = newValue
                guard newValue else {
                    NotificationManager.shared.clearAll()
                    return
                }

                NotificationManager.shared.checkPermission()
                if NotificationManager.shared.authorizationStatus == .notDetermined {
                    NotificationManager.shared.requestPermission()
                }
            }
        )
    }

    private func notificationSourceBinding(for source: NotificationFeedSource) -> Binding<Bool> {
        Binding(
            get: { appState.isNotificationSourceEnabled(source) },
            set: { newValue in
                appState.setNotificationSource(source, enabled: newValue)
                NotificationManager.shared.applyFeedPreferences()
            }
        )
    }

    private var calendarPermissionDescription: String {
        switch calendarManager.authorizationStatus {
        case .fullAccess, .authorized:
            return "Allowed. Choose which calendars appear in SuperIsland."
        case .notDetermined:
            return "Not requested. Allow access to show upcoming events."
        case .denied:
            return "Denied. Open System Settings to allow Calendar access."
        case .restricted:
            return "Restricted by macOS settings."
        case .writeOnly:
            return "Write-only access is not enough to display events."
        @unknown default:
            return "Unknown. Check macOS Calendar privacy settings."
        }
    }

    private var notificationPermissionDescription: String {
        switch notificationManager.authorizationStatus {
        case .authorized:
            return "Allowed. SuperIsland can send its own notifications and extension alerts."
        case .denied:
            return "Denied. Open System Settings to allow SuperIsland notifications."
        case .notDetermined:
            return "Not requested. Allow this when you want SuperIsland or extensions to send macOS notifications."
        case .provisional, .ephemeral:
            return "Allowed with limited delivery."
        @unknown default:
            return "Unknown. Check macOS notification settings."
        }
    }

    private var calendarPermissionButtonTitle: String {
        switch calendarManager.authorizationStatus {
        case .notDetermined:
            return "Request"
        default:
            return "Open Settings"
        }
    }

    private var notificationPermissionButtonTitle: String {
        switch notificationManager.authorizationStatus {
        case .notDetermined:
            return "Request"
        default:
            return "Open Settings"
        }
    }

    private func handleCalendarPermissionAction() {
        switch calendarManager.authorizationStatus {
        case .notDetermined:
            calendarManager.requestAccess()
        default:
            calendarManager.openCalendarSettings()
        }
    }

    private func handleNotificationPermissionAction() {
        switch notificationManager.authorizationStatus {
        case .notDetermined:
            notificationManager.requestPermission()
        default:
            notificationManager.openNotificationSettings()
        }
    }

    private func calendarTypeLabel(_ type: EKCalendarType) -> String {
        switch type {
        case .local:
            return "Local"
        case .calDAV:
            return "CalDAV"
        case .exchange:
            return "Exchange"
        case .subscription:
            return "Subscription"
        case .birthday:
            return "Birthdays"
        @unknown default:
            return "Calendar"
        }
    }

    private var shelfRetentionRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Shelf retention")
                    .font(.system(size: 13))
                Text("Pinned items are kept")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 8)
            Picker("", selection: $shelf.retentionDays) {
                ForEach(ShelfRetentionOption.allCases) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 120)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private func homeSlotRow(title: String, selection: Binding<String>) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13))
            Spacer(minLength: 12)
            Picker("", selection: selection) {
                ForEach(HomePanel.allCases) { panel in
                    Label(panel.title, systemImage: panel.iconName)
                        .tag(panel.rawValue)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 150)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var browserMediaRows: some View {
        ForEach(nowPlayingManager.browserTargets) { browser in
            SettingRowDivider()
            browserToggleRow(browser)
        }
        SettingRowDivider()
        browserDetectionTestRow
    }

    private func browserToggleRow(_ browser: NowPlayingBrowserTarget) -> some View {
        SettingToggleRow(
            title: browser.displayName,
            description: "Allow SuperIsland to look for media in this browser.",
            isOn: browserBinding(for: browser.id)
        )
    }

    private var browserDetectionTestRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Detection test")
                    .font(.system(size: 13))
                Text(browserDetectionMessage)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 6) {
                Button("Test") {
                    nowPlayingManager.testBrowserDetection()
                }
                .font(.system(size: 12))
                Button("Open Settings") {
                    nowPlayingManager.openAutomationSettings()
                }
                .font(.system(size: 12))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private func browserBinding(for browserID: String) -> Binding<Bool> {
        Binding(
            get: { nowPlayingManager.isBrowserAllowed(browserID) },
            set: { nowPlayingManager.setBrowser(browserID, allowed: $0) }
        )
    }

    private var browserDetectionMessage: String {
        if !nowPlayingManager.browserDetectionTestMessage.isEmpty {
            return nowPlayingManager.browserDetectionTestMessage
        }
        return "Requires Automation permission and JavaScript from Apple Events in the browser."
    }
}
