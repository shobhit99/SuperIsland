import SwiftUI
import EventKit

struct HomeScreenView: View {
    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            HomeNowPlayingPanel()
                .frame(width: 252, alignment: .topLeading)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1)
                .padding(.vertical, 4)

            HomeCalendarPanel()
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct HomeNowPlayingPanel: View {
    @ObservedObject private var manager = NowPlayingManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Now Playing")

            if manager.title.isEmpty {
                HomeEmptyState(
                    icon: "music.note.house",
                    title: "Nothing is playing",
                    subtitle: "Start playback to pin controls here."
                )
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 14) {
                        albumArt

                        VStack(alignment: .leading, spacing: 9) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(manager.title)
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)

                                Text(secondaryLine)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.62))
                                    .lineLimit(1)

                                sourceBadge
                            }

                            controlsRow
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }

                    sliderSection
                }
            }
        }
    }

    private var albumArt: some View {
        AlbumArtView(image: manager.albumArt, size: 92)
    }

    private var secondaryLine: String {
        let artist = sanitized(manager.artist)
        let album = sanitized(manager.album)

        if let artist, let album {
            return "\(artist) • \(album)"
        }

        return artist ?? album ?? sanitized(manager.sourceName) ?? "Media"
    }

    private var durationLine: String {
        guard manager.duration > 0 else { return "--:--" }
        return "\(manager.formattedElapsedTime) / \(manager.formattedDuration)"
    }

    private var controlsRow: some View {
        HStack(spacing: 12) {
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
        VStack(alignment: .leading, spacing: 5) {
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
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.5))
            .lineLimit(1)
        }
        .padding(.horizontal, 10)
    }

    private var sourceBadge: some View {
        Text(sanitized(manager.sourceName) ?? "System Audio")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white.opacity(0.72))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
    }

    private func transportButton(
        systemName: String,
        action: @escaping () -> Void,
        isPrimary: Bool = false
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: isPrimary ? 14 : 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: isPrimary ? 34 : 28, height: isPrimary ? 34 : 28)
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
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("Calendar")

            VStack(alignment: .leading, spacing: 2) {
                Text(todayTitle)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text(todaySubtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }

            if upcomingEvents.isEmpty {
                HomeEmptyState(
                    icon: "calendar",
                    title: "Nothing coming up",
                    subtitle: "Your schedule is clear for now."
                )
                .padding(.top, 10)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(upcomingEvents.prefix(4).enumerated()), id: \.offset) { _, event in
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
        formatter.dateFormat = "EEEE, d MMM"
        return formatter
    }()
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
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(timeRange)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.56))
                        .lineLimit(1)

                    if let countdown {
                        Text(countdown)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.86))
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
                .foregroundStyle(.white.opacity(0.34))

            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))

            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private func sectionLabel(_ title: String) -> some View {
    Text(title.uppercased())
        .font(.system(size: 9, weight: .bold))
        .tracking(1.2)
        .foregroundStyle(.white.opacity(0.4))
}
