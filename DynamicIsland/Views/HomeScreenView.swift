import SwiftUI
import EventKit

struct HomeScreenView: View {
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            HomeNowPlayingPanel()
                .frame(width: 228, alignment: .topLeading)

            homeDivider

            HomeCalendarPanel()
                .frame(maxWidth: .infinity, alignment: .topLeading)

            homeDivider

            HomeWeatherPanel()
                .frame(width: 150, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var homeDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(width: 1)
            .padding(.vertical, 4)
    }
}

private struct HomeNowPlayingPanel: View {
    @ObservedObject private var manager = NowPlayingManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if manager.title.isEmpty {
                HomeEmptyState(
                    icon: "music.note.house",
                    title: "Nothing is playing",
                    subtitle: "Start playback to pin controls here."
                )
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(manager.title)
                            .font(HomeTypography.panelTitleFont)
                            .foregroundStyle(HomeTypography.primaryText)
                            .lineLimit(1)

                        Text(secondaryLine)
                            .font(HomeTypography.secondaryFont)
                            .foregroundStyle(HomeTypography.secondaryText)
                            .lineLimit(1)
                    }

                    HStack(alignment: .center, spacing: 18) {
                        albumArt

                        controlsRow
                            .frame(maxWidth: .infinity, alignment: .center)
                    }

                    sliderSection
                }
            }
        }
    }

    private var albumArt: some View {
        ZStack(alignment: .bottomTrailing) {
            AlbumArtView(image: manager.albumArt, size: 78)

            if let sourceAppIcon = manager.sourceAppIcon {
                Image(nsImage: sourceAppIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(Color.black.opacity(0.55), lineWidth: 1)
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.black.opacity(0.9))
                    )
                    .offset(x: 4, y: 4)
            }
        }
    }

    private var secondaryLine: String {
        let artist = sanitized(manager.artist)
        let album = sanitized(manager.album)

        if let artist, let album {
            return "\(artist) • \(album)"
        }

        return artist ?? album ?? "Media"
    }

    private var durationLine: String {
        guard manager.duration > 0 else { return "--:--" }
        return "\(manager.formattedElapsedTime) / \(manager.formattedDuration)"
    }

    private var controlsRow: some View {
        HStack(spacing: 10) {
            transportButton(systemName: "backward.fill", action: manager.previousTrack)
            transportButton(
                systemName: manager.isPlaying ? "pause.fill" : "play.fill",
                action: manager.togglePlayPause,
                isPrimary: true
            )
            transportButton(systemName: "forward.fill", action: manager.nextTrack)
        }
    }

    private var sliderSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressBar(
                progress: manager.progress,
                trackHeight: 3,
                knobSize: 8
            ) { newProgress in
                manager.seek(to: manager.duration * newProgress)
            }
            .frame(height: 14)

            HStack {
                Text(manager.formattedElapsedTime)
                Spacer(minLength: 8)
                Text(manager.formattedDuration)
            }
            .font(HomeTypography.metaFont)
            .foregroundStyle(HomeTypography.tertiaryText)
            .lineLimit(1)
        }
        .padding(.horizontal, 6)
    }

    private func transportButton(
        systemName: String,
        action: @escaping () -> Void,
        isPrimary: Bool = false
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: isPrimary ? 13 : 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: isPrimary ? 32 : 26, height: isPrimary ? 32 : 26)
                .background(
                    Circle()
                        .fill(Color.white.opacity(isPrimary ? 0.12 : 0.07))
                )
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(isPrimary ? 0.1 : 0.06), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .hoverPointer()
    }

    private func sanitized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct HomeCalendarPanel: View {
    @ObservedObject private var manager = CalendarManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(todayTitle)
                    .font(HomeTypography.heroFont)
                    .foregroundStyle(HomeTypography.primaryText)
                    .lineLimit(2)

                Text(todaySubtitle)
                    .font(HomeTypography.secondaryFont)
                    .foregroundStyle(HomeTypography.secondaryText)
            }

            if upcomingEvents.isEmpty {
                HomeEmptyState(
                    icon: "calendar",
                    title: "Nothing coming up",
                    subtitle: "Your schedule is clear for now."
                )
                .padding(.top, 10)
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(upcomingEvents.prefix(3).enumerated()), id: \.offset) { _, event in
                        HomeEventRow(
                            event: event,
                            countdown: countdown(for: event),
                            joinURL: manager.joinURL(for: event)
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var upcomingEvents: [EKEvent] {
        let now = Date()
        return manager.todayEvents.filter { $0.endDate > now }
    }

    private var todayTitle: String {
        Self.todayTitleFormatter.string(from: Date())
    }

    private var todaySubtitle: String {
        if upcomingEvents.isEmpty {
            return "No events scheduled today"
        }
        if upcomingEvents.count == 1 {
            return "1 event coming up"
        }
        return "\(upcomingEvents.count) events coming up"
    }

    private func countdown(for event: EKEvent) -> String? {
        guard let nextEvent = manager.nextEvent, nextEvent.eventIdentifier == event.eventIdentifier else {
            return nil
        }
        return manager.nextEventCountdown
    }

    private static let todayTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, d MMM"
        return formatter
    }()
}

private struct HomeWeatherPanel: View {
    @ObservedObject private var manager = WeatherManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isWeatherUnavailable {
                HomeEmptyState(
                    icon: "cloud.sun",
                    title: manager.isLoading ? "Fetching weather" : "Weather unavailable",
                    subtitle: manager.isLoading ? "Getting your local conditions." : "Current forecast will appear here."
                )
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: manager.weather.conditionIcon)
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.white.opacity(0.92))
                            .frame(width: 34, height: 34)
                            .background(
                                Circle()
                                    .fill(Color.white.opacity(0.06))
                            )

                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(Int(manager.weather.temperature))°")
                                .font(HomeTypography.temperatureFont)
                                .foregroundStyle(HomeTypography.primaryText)

                            Text(manager.weather.condition)
                                .font(HomeTypography.secondaryFont)
                                .foregroundStyle(HomeTypography.secondaryText)
                                .lineLimit(1)
                        }
                    }

                    if !manager.weather.locationName.isEmpty {
                        Text(manager.weather.locationName)
                            .font(HomeTypography.bodyTitleFont)
                            .foregroundStyle(HomeTypography.secondaryText)
                            .lineLimit(1)
                    }

                    HStack(spacing: 8) {
                        weatherStat(
                            title: "High",
                            value: "\(Int(manager.weather.temperatureHigh))°",
                            icon: "arrow.up.circle.fill",
                            tint: Color.orange.opacity(0.88)
                        )
                        weatherStat(
                            title: "Low",
                            value: "\(Int(manager.weather.temperatureLow))°",
                            icon: "arrow.down.circle.fill",
                            tint: Color.cyan.opacity(0.88)
                        )
                    }
                }
            }
        }
    }

    private var isWeatherUnavailable: Bool {
        !hasWeatherData
    }

    private var hasWeatherData: Bool {
        !manager.weather.locationName.isEmpty ||
        manager.weather.temperature != 0 ||
        manager.weather.temperatureHigh != 0 ||
        manager.weather.temperatureLow != 0
    }

    private func weatherStat(title: String, value: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)

                Text(title)
                    .font(HomeTypography.badgeFont)
                    .foregroundStyle(HomeTypography.tertiaryText)
            }

            Text(value)
                .font(HomeTypography.valueFont)
                .foregroundStyle(HomeTypography.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HomeEventRow: View {
    let event: EKEvent
    let countdown: String?
    let joinURL: URL?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(Color(cgColor: event.calendar.cgColor))
                .frame(width: 8, height: 8)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 3) {
                Text(event.title ?? "Upcoming event")
                    .font(HomeTypography.bodyTitleFont)
                    .foregroundStyle(HomeTypography.secondaryText)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(timeRange)
                        .font(HomeTypography.secondaryFont)
                        .foregroundStyle(HomeTypography.secondaryText)
                        .lineLimit(1)

                    if let countdown {
                        Text(countdown)
                            .font(HomeTypography.badgeFont)
                            .foregroundStyle(HomeTypography.primaryText.opacity(0.92))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.white.opacity(0.08))
                            )
                    }
                }
            }

            Spacer(minLength: 0)

            if let joinURL {
                Button {
                    NSWorkspace.shared.open(joinURL)
                } label: {
                    Image(systemName: "video.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.92))
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var timeRange: String {
        let formatter = Self.timeFormatter
        return "\(formatter.string(from: event.startDate)) - \(formatter.string(from: event.endDate))"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()
}

private struct HomeEmptyState: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(HomeTypography.tertiaryText)

            Text(title)
                .font(HomeTypography.bodyTitleFont)
                .foregroundStyle(HomeTypography.primaryText.opacity(0.9))

            Text(subtitle)
                .font(HomeTypography.secondaryFont)
                .foregroundStyle(HomeTypography.secondaryText)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum HomeTypography {
    static let heroFont = Font.system(size: 18, weight: .semibold)
    static let temperatureFont = Font.system(size: 24, weight: .semibold)
    static let panelTitleFont = Font.system(size: 15, weight: .semibold)
    static let bodyTitleFont = Font.system(size: 14, weight: .semibold)
    static let valueFont = Font.system(size: 14, weight: .semibold)
    static let secondaryFont = Font.system(size: 11, weight: .medium)
    static let badgeFont = Font.system(size: 10, weight: .semibold)
    static let metaFont = Font.system(size: 10, weight: .medium, design: .monospaced)

    static let primaryText = Color.white.opacity(0.88)
    static let secondaryText = Color.white.opacity(0.58)
    static let tertiaryText = Color.white.opacity(0.36)
}
