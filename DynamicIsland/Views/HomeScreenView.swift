import SwiftUI
import EventKit

enum HomeScreenDensity {
    case expanded
    case fullExpanded

    var cardSpacing: CGFloat {
        switch self {
        case .expanded: return 10
        case .fullExpanded: return 12
        }
    }

    var cardPadding: CGFloat {
        switch self {
        case .expanded: return 10
        case .fullExpanded: return 12
        }
    }

    var cardHeight: CGFloat {
        switch self {
        case .expanded: return 72
        case .fullExpanded: return 92
        }
    }
}

struct HomeScreenView: View {
    let density: HomeScreenDensity

    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: density.cardSpacing) {
            ForEach(Array(appState.homeTraySelections.enumerated()), id: \.offset) { index, selection in
                HomeTrayCard(selection: selection, density: density)
                    .frame(maxWidth: .infinity)
                    .id("home-tray-\(index)-\(selection.rawValue)")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct HomeTrayCard: View {
    let selection: HomeWidgetSelection
    let density: HomeScreenDensity

    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            switch selection {
            case .none:
                placeholderCard
            default:
                Button(action: openSelection) {
                    cardBody
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var placeholderCard: some View {
        cardContainer {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "plus.square.dashed")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))

                Spacer(minLength: 0)

                Text("Empty tray")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))

                Text("Choose a widget in settings")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(2)
            }
        }
    }

    private var cardBody: some View {
        cardContainer {
            VStack(alignment: .leading, spacing: 8) {
                Label(selection.displayName, systemImage: selection.iconName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)

                Spacer(minLength: 0)

                HomeTrayContent(selection: selection, density: density)
            }
        }
    }

    private func cardContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(density.cardPadding)
            .frame(maxWidth: .infinity, minHeight: density.cardHeight, maxHeight: density.cardHeight, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
    }

    private func openSelection() {
        switch selection {
        case .none:
            break
        case .builtIn(let module):
            appState.setActiveModule(module)
        case .extension_(let extensionID):
            appState.setActiveModule(.extension_(extensionID))
        }
    }
}

private struct HomeTrayContent: View {
    let selection: HomeWidgetSelection
    let density: HomeScreenDensity

    var body: some View {
        switch selection {
        case .none:
            EmptyView()
        case .builtIn(.weather):
            WeatherHomeWidget()
        case .builtIn(.nowPlaying):
            MediaHomeWidget()
        case .builtIn(.calendar):
            CalendarHomeWidget()
        case .builtIn(.battery):
            BatteryHomeWidget()
        case .builtIn(.connectivity):
            ConnectivityHomeWidget()
        case .builtIn:
            EmptyView()
        case .extension_(let extensionID):
            ExtensionHomeWidget(extensionID: extensionID)
        }
    }
}

private struct WeatherHomeWidget: View {
    @ObservedObject private var manager = WeatherManager.shared

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: manager.weather.conditionIcon)
                .font(.system(size: 18))
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(Int(manager.weather.temperature))°")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text(manager.weather.locationName.isEmpty ? manager.weather.condition : manager.weather.locationName)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
    }
}

private struct MediaHomeWidget: View {
    @ObservedObject private var manager = NowPlayingManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if manager.title.isEmpty {
                Text("No media playing")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
                Text("Open music to pin it here")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
            } else {
                Text(manager.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(manager.artist.isEmpty ? manager.sourceName : manager.artist)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)

                ProgressView(value: progressValue)
                    .tint(.white.opacity(0.9))
                    .scaleEffect(x: 1, y: 0.65, anchor: .center)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var progressValue: Double {
        guard manager.duration > 0 else { return 0 }
        return min(1, max(0, manager.elapsedTime / manager.duration))
    }
}

private struct CalendarHomeWidget: View {
    @ObservedObject private var manager = CalendarManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let event = manager.nextEvent {
                Text(event.title ?? "Upcoming event")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(timeRange(for: event))
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)

                if let countdown = manager.nextEventCountdown {
                    Text(countdown)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                }
            } else {
                Text("No more events today")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
                Text("\(manager.todayEvents.count) scheduled today")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func timeRange(for event: EKEvent) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return "\(formatter.string(from: event.startDate)) - \(formatter.string(from: event.endDate))"
    }
}

private struct BatteryHomeWidget: View {
    @ObservedObject private var manager = BatteryManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: manager.isCharging ? "battery.100.bolt" : "battery.100")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(manager.isCharging ? Color.green : .white)

                Text("\(manager.batteryLevel)%")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Spacer(minLength: 0)

                Text("24h")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
            }

            BatterySparkline(samples: manager.batteryHistory)
                .frame(height: 22)
        }
    }
}

private struct ConnectivityHomeWidget: View {
    @ObservedObject private var bluetooth = BluetoothManager.shared
    @ObservedObject private var wifi = WiFiManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: wifi.signalIconName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(wifi.isConnected ? Color.blue : .white.opacity(0.6))

                Text(wifi.ssid ?? "Wi-Fi Off")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }

            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(bluetooth.connectedDevices.isEmpty ? .white.opacity(0.5) : Color.green)

                Text(bluetoothSummary)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var bluetoothSummary: String {
        if let device = bluetooth.connectedDevices.first {
            if bluetooth.connectedDevices.count == 1 {
                return device.name
            }
            return "\(device.name) +\(bluetooth.connectedDevices.count - 1)"
        }
        return "No Bluetooth devices"
    }
}

private struct ExtensionHomeWidget: View {
    let extensionID: String

    var body: some View {
        ExtensionRendererView(extensionID: extensionID, displayMode: .compact)
            .allowsHitTesting(false)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct BatterySparkline: View {
    let samples: [BatteryHistorySample]

    var body: some View {
        GeometryReader { geometry in
            let points = normalizedPoints(in: geometry.size)

            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.04))

                if points.count > 1 {
                    Path { path in
                        path.move(to: points[0])
                        for point in points.dropFirst() {
                            path.addLine(to: point)
                        }
                    }
                    .stroke(Color.green.opacity(0.9), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }

    private func normalizedPoints(in size: CGSize) -> [CGPoint] {
        let window = Array(samples.suffix(288))
        guard let minLevel = window.map(\.level).min(),
              let maxLevel = window.map(\.level).max(),
              !window.isEmpty else {
            return []
        }

        let xStep = window.count > 1 ? size.width / CGFloat(window.count - 1) : 0
        let levelSpan = max(1, maxLevel - minLevel)

        return window.enumerated().map { index, sample in
            let x = CGFloat(index) * xStep
            let normalized = CGFloat(sample.level - minLevel) / CGFloat(levelSpan)
            let y = size.height - (normalized * max(CGFloat(1), size.height - 4)) - 2
            return CGPoint(x: x, y: y)
        }
    }
}
