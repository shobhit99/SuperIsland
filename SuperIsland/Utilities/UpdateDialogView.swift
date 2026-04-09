import SwiftUI
import AppKit

struct UpdateDialogView: View {
    let version: String
    let releaseURL: URL
    let downloadURL: URL?
    let onDismiss: () -> Void

    @ObservedObject private var updater = AutoUpdater.shared
    @State private var appeared = false
    @State private var hoveringUpdate = false
    @State private var hoveringLater = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 30)

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 60, height: 60)

            Spacer().frame(height: 14)

            Text("Update Available")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.92))

            Spacer().frame(height: 5)

            statusText

            Spacer()

            bottomControls

            Spacer().frame(height: 26)
        }
        .frame(width: 300, height: 210)
        .background(Color(red: 0.02, green: 0.02, blue: 0.03))
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1 : 0.96)
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) {
                appeared = true
            }
        }
    }

    // MARK: - Status Text

    @ViewBuilder
    private var statusText: some View {
        switch updater.state {
        case .idle:
            Text("Version \(version) is ready to install.")
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.45))
        case .downloading(let progress):
            VStack(spacing: 6) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(Color.white.opacity(0.8))
                    .frame(width: 160)
                Text("Downloading \(Int(progress * 100))%")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.4))
            }
        case .installing:
            HStack(spacing: 6) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
                    .tint(Color.white.opacity(0.6))
                Text("Installing...")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.45))
            }
        case .failed(let message):
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(Color.red.opacity(0.75))
                .multilineTextAlignment(.center)
                .frame(width: 200)
        }
    }

    // MARK: - Bottom Controls

    @ViewBuilder
    private var bottomControls: some View {
        switch updater.state {
        case .idle:
            HStack(spacing: 8) {
                Button("Later") { onDismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(hoveringLater ? 0.65 : 0.38))
                    .frame(width: 88, height: 34)
                    .onHover { active in
                        withAnimation(.easeInOut(duration: 0.15)) { hoveringLater = active }
                    }

                Button {
                    if let downloadURL {
                        updater.start(downloadURL: downloadURL, releaseURL: releaseURL)
                    } else {
                        NSWorkspace.shared.open(releaseURL)
                        onDismiss()
                    }
                } label: {
                    Text("Update")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.85))
                        .frame(width: 100, height: 34)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.white.opacity(hoveringUpdate ? 1.0 : 0.9))
                        )
                }
                .buttonStyle(.plain)
                .scaleEffect(hoveringUpdate ? 1.03 : 1)
                .onHover { active in
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                        hoveringUpdate = active
                    }
                }
            }

        case .downloading, .installing:
            EmptyView()

        case .failed:
            Button("Open Release Page") {
                NSWorkspace.shared.open(releaseURL)
                onDismiss()
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.55))
        }
    }
}
