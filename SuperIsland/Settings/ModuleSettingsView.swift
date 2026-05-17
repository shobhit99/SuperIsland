import AppKit
import EventKit
import SwiftUI

struct ModuleSettingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var calendarManager = CalendarManager.shared
    @ObservedObject private var shelf = ShelfStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            SettingSectionLabel(title: "Media & HUD")
            SettingGroup {
                SettingToggleRow(title: "Now Playing", isOn: $appState.nowPlayingEnabled)
                SettingRowDivider()
                SettingToggleRow(title: "Volume HUD", isOn: $appState.volumeHUDEnabled)
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
                SettingToggleRow(title: "Notifications", isOn: $appState.notificationsEnabled)
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
        .onAppear { calendarManager.refreshAccessStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
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

    private var calendarPermissionButtonTitle: String {
        switch calendarManager.authorizationStatus {
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
}
