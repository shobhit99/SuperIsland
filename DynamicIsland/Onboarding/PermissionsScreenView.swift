import SwiftUI

struct PermissionsScreenView: View {
    @ObservedObject var permissions: OnboardingPermissionState
    let onContinue: () -> Void

    @State private var revealCards = false

    private let requiredPermissions = OnboardingPermission.allCases

    var body: some View {
        VStack(spacing: 24) {
            DynamicIslandHeroView(mode: .permissions, interactionTick: permissions.allRequiredGranted ? 1 : 0)
                .padding(.top, 6)

            VStack(spacing: 10) {
                Text("Let’s set things up")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(OnboardingPalette.textPrimary)
                    .accessibilityAddTraits(.isHeader)

                Text("We just need a couple permissions so the app can work smoothly.")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(OnboardingPalette.textSecondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 14) {
                ForEach(Array(requiredPermissions.enumerated()), id: \.element.id) { index, permission in
                    PermissionCardComponent(
                        permission: permission,
                        isGranted: permissions.isGranted(permission)
                    ) {
                        permissions.request(permission)
                    }
                    .opacity(revealCards ? 1 : 0)
                    .offset(y: revealCards ? 0 : 18)
                    .animation(
                        .spring(response: 0.42, dampingFraction: 0.88).delay(Double(index) * 0.1),
                        value: revealCards
                    )
                }
            }
            .frame(maxWidth: 720)

            Spacer(minLength: 0)

            VStack(spacing: 12) {
                OnboardingActionButton(
                    title: "Continue",
                    tone: .cool,
                    isDisabled: !permissions.allRequiredGranted,
                    action: onContinue
                )
                .accessibilityLabel("Continue after permissions are granted")

                if !permissions.allRequiredGranted {
                    Text("Continue unlocks once both permissions are enabled.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(OnboardingPalette.textTertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            revealCards = true

            while !Task.isCancelled {
                permissions.refresh()
                try? await Task.sleep(for: .milliseconds(900))
            }
        }
    }
}
