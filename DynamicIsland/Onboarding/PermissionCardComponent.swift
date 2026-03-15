import SwiftUI

enum OnboardingPermission: CaseIterable, Identifiable {
    case screenRecording
    case accessibility

    var id: Self { self }

    var iconName: String {
        switch self {
        case .screenRecording:
            return "display"
        case .accessibility:
            return "figure.stand"
        }
    }

    var title: String {
        switch self {
        case .screenRecording:
            return "Screen Recording"
        case .accessibility:
            return "Accessibility Access"
        }
    }

    var description: String {
        switch self {
        case .screenRecording:
            return "Allows the app to detect your active workspace and integrate with your Dynamic Island."
        case .accessibility:
            return "Required to interact with system windows and provide productivity overlays."
        }
    }

    var actionTitle: String {
        switch self {
        case .screenRecording:
            return "Grant Access"
        case .accessibility:
            return "Enable"
        }
    }
}

struct PermissionCardComponent: View {
    let permission: OnboardingPermission
    let isGranted: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 58, height: 58)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )

                Image(systemName: permission.iconName)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(isGranted ? Color.green.opacity(0.95) : OnboardingPalette.coolAccent)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(permission.title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(OnboardingPalette.textPrimary)

                Text(permission.description)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(OnboardingPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            if isGranted {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Granted")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(Color.green.opacity(0.95))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.green.opacity(0.14))
                )
                .scaleEffect(isGranted ? 1.0 : 0.75)
                .animation(.spring(response: 0.34, dampingFraction: 0.72), value: isGranted)
            } else {
                OnboardingActionButton(
                    title: permission.actionTitle,
                    tone: .secondary,
                    action: action
                )
            }
        }
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        )
        .shadow(color: Color.black.opacity(isHovering ? 0.18 : 0.1), radius: isHovering ? 24 : 14, y: isHovering ? 12 : 6)
        .offset(y: isHovering ? -2 : 0)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(permission.title). \(permission.description)")
        .accessibilityValue(isGranted ? "Granted" : "Not granted")
    }
}
