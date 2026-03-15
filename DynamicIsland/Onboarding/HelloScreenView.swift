import SwiftUI

struct HelloScreenView: View {
    let interactionTick: Int
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 26) {
            DynamicIslandHeroView(mode: .hello, interactionTick: interactionTick)
                .padding(.top, 10)

            VStack(spacing: 12) {
                Text("Hello 👋")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(OnboardingPalette.textPrimary)
                    .accessibilityAddTraits(.isHeader)

                Text("Meet your new focus companion — designed to live right inside your Mac’s Dynamic Island.")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(OnboardingPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)
            }

            HStack(spacing: 10) {
                Text("Calm by default")
                Text("Notch-native")
                Text("Made for macOS")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(OnboardingPalette.textTertiary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(OnboardingPalette.outline, lineWidth: 1)
                    )
            )

            Spacer(minLength: 0)

            OnboardingActionButton(title: "Continue", tone: .cool, action: onContinue)
                .accessibilityLabel("Continue to permissions setup")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
    }
}
