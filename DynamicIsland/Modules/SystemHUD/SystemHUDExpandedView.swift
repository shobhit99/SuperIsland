import SwiftUI

struct SystemHUDExpandedView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var volumeManager = VolumeManager.shared
    @ObservedObject private var brightnessManager = BrightnessManager.shared

    @State private var overshootScale: CGFloat = 1.0

    var body: some View {
        HStack(spacing: 16) {
            // Icon with bounce on limits
            Image(systemName: iconName)
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(.white)
                .scaleEffect(overshootScale)

            VStack(alignment: .leading, spacing: 6) {
                // Label + percentage
                HStack {
                    Text(label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)

                    Spacer()

                    Text("\(currentPercentage)%")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))
                }

                // Slider
                SliderBar(value: currentBinding)
                    .frame(height: 6)

                // Device name (volume only)
                if appState.activeModule == .volumeHUD {
                    Text(volumeManager.outputDeviceName)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                }
            }
        }
        .onChange(of: currentValue) { _, newValue in
            if newValue <= 0 || newValue >= 1.0 {
                triggerOvershoot()
            }
        }
    }

    private var iconName: String {
        switch appState.activeModule {
        case .volumeHUD: return volumeManager.volumeIconName
        case .brightnessHUD: return brightnessManager.brightnessIconName
        default: return "speaker.wave.2.fill"
        }
    }

    private var label: String {
        switch appState.activeModule {
        case .volumeHUD: return "Volume"
        case .brightnessHUD: return "Brightness"
        default: return ""
        }
    }

    private var currentValue: Float {
        switch appState.activeModule {
        case .volumeHUD: return volumeManager.volume
        case .brightnessHUD: return brightnessManager.brightness
        default: return 0
        }
    }

    private var currentPercentage: Int {
        Int(currentValue * 100)
    }

    private var currentBinding: Binding<Float> {
        switch appState.activeModule {
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
