import SwiftUI
import AppKit

struct SystemHUDExpandedView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var volumeManager = VolumeManager.shared
    @ObservedObject private var brightnessManager = BrightnessManager.shared

    @State private var overshootScale: CGFloat = 1.0

    var body: some View {
        Group {
            if appState.activeBuiltInModule == .volumeHUD && appState.currentState == .fullExpanded {
                fullExpandedVolumeView
            } else {
                defaultHUDView
            }
        }
        .onChange(of: currentValue) { _, newValue in
            if newValue <= 0 || newValue >= 1.0 {
                triggerOvershoot()
            }
        }
    }

    private var defaultHUDView: some View {
        HStack(spacing: 16) {
            Image(systemName: iconName)
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(.white)
                .scaleEffect(overshootScale)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)

                    Spacer()

                    Text("\(currentPercentage)%")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))
                }

                SliderBar(value: currentBinding)
                    .frame(height: 6)

                if appState.activeBuiltInModule == .volumeHUD {
                    Text(volumeManager.outputDeviceName)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                }
            }
        }
    }

    private var fullExpandedVolumeView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: volumeManager.volumeIconName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .scaleEffect(overshootScale)

                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("System Volume")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                        Spacer()
                        Text("\(volumeManager.volumePercentage)%")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    SliderBar(value: currentBinding)
                        .frame(height: 6)
                }
            }

            Text(volumeManager.outputDeviceName)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.45))

            Divider()
                .overlay(.white.opacity(0.15))

            Text("Media Apps")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.8))

            if volumeManager.mediaAppVolumes.isEmpty {
                Text("No supported media apps are currently playing.")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 8) {
                        ForEach(volumeManager.mediaAppVolumes.prefix(5)) { app in
                            MediaAppVolumeRow(app: app) { newValue in
                                volumeManager.setMediaAppVolume(appID: app.id, volume: newValue)
                            }
                        }
                    }
                    .padding(.trailing, 2)
                }
                .frame(maxHeight: 106)
            }
        }
        .onAppear {
            volumeManager.refreshMediaAppVolumes()
        }
    }

    private var iconName: String {
        switch appState.activeBuiltInModule {
        case .volumeHUD: return volumeManager.volumeIconName
        case .brightnessHUD: return brightnessManager.brightnessIconName
        default: return "speaker.wave.2.fill"
        }
    }

    private var label: String {
        switch appState.activeBuiltInModule {
        case .volumeHUD: return "Volume"
        case .brightnessHUD: return "Brightness"
        default: return ""
        }
    }

    private var currentValue: Float {
        switch appState.activeBuiltInModule {
        case .volumeHUD: return volumeManager.volume
        case .brightnessHUD: return brightnessManager.brightness
        default: return 0
        }
    }

    private var currentPercentage: Int {
        Int(currentValue * 100)
    }

    private var currentBinding: Binding<Float> {
        switch appState.activeBuiltInModule {
        case .volumeHUD:
            return Binding(
                get: { volumeManager.volume },
                set: { volumeManager.setVolume($0) }
            )
        case .brightnessHUD:
            return Binding(
                get: { brightnessManager.brightness },
                set: { brightnessManager.setBrightness($0) }
            )
        default:
            return .constant(0)
        }
    }

    private func triggerOvershoot() {
        withAnimation(Constants.overshootBounce) {
            overshootScale = 1.15
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(Constants.overshootBounce) {
                overshootScale = 1.0
            }
        }
    }
}

private struct MediaAppVolumeRow: View {
    let app: MediaAppVolume
    let onChange: (Float) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let appIcon = appIconImage {
                    Image(nsImage: appIcon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 14, height: 14)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                } else {
                    Image(systemName: app.iconName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                        .frame(width: 14)
                }

                Text(app.appName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)

                Spacer()

                Text(app.statusText)
                    .font(.system(size: 10))
                    .foregroundColor(app.isPlaying ? .green : .white.opacity(0.55))

                Text("\(Int(app.volume * 100))%")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.72))
            }

            SliderBar(
                value: Binding(
                    get: { app.volume },
                    set: { onChange($0) }
                )
            )
            .frame(height: 5)
        }
    }

    private var appIconImage: NSImage? {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: appURL.path)
    }
}

// MARK: - Slider Bar

struct SliderBar: View {
    @Binding var value: Float

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(.white.opacity(0.2))

                RoundedRectangle(cornerRadius: 3)
                    .fill(.white)
                    .frame(width: max(0, geometry.size.width * CGFloat(min(value, 1.0))))
                    .animation(Constants.progressBar, value: value)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let newValue = Float(drag.location.x / geometry.size.width)
                        value = max(0, min(1, newValue))
                    }
            )
        }
    }
}
