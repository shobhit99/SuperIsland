import SwiftUI

struct SystemHUDCompactView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var volumeManager = VolumeManager.shared
    @ObservedObject private var brightnessManager = BrightnessManager.shared

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)

            // Slim progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.white.opacity(0.2))

                    RoundedRectangle(cornerRadius: 2)
                        .fill(.white)
                        .frame(width: max(0, geometry.size.width * CGFloat(currentValue)))
                        .animation(Constants.progressBar, value: currentValue)
                }
            }
            .frame(maxWidth: 80, maxHeight: 4)

            Text("\(currentPercentage)%")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.7))
        }
    }

    private var iconName: String {
        switch appState.activeBuiltInModule {
        case .volumeHUD:
            return volumeManager.volumeIconName
        case .brightnessHUD:
            return brightnessManager.brightnessIconName
        default:
            return "speaker.wave.2.fill"
        }
    }

    private var currentValue: Float {
        switch appState.activeBuiltInModule {
        case .volumeHUD:
            return volumeManager.volume
        case .brightnessHUD:
            return brightnessManager.brightness
        default:
            return 0
        }
    }

    private var currentPercentage: Int {
        Int(currentValue * 100)
    }
}
