import SwiftUI
import AppKit

struct UpdateDialogView: View {
    let version: String
    let releaseURL: URL
    let onDismiss: () -> Void

    @State private var hoveringDownload = false
    @State private var hoveringLater = false
    @State private var appeared = false

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

            Text("Version \(version) is ready to download.")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.45))

            Spacer()

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
                    NSWorkspace.shared.open(releaseURL)
                    onDismiss()
                } label: {
                    Text("Download")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.85))
                        .frame(width: 100, height: 34)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.white.opacity(hoveringDownload ? 1.0 : 0.9))
                        )
                }
                .buttonStyle(.plain)
                .scaleEffect(hoveringDownload ? 1.03 : 1)
                .onHover { active in
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                        hoveringDownload = active
                    }
                }
            }
            .padding(.bottom, 26)
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
}
