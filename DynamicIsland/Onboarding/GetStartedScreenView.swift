import SwiftUI

struct GetStartedScreenView: View {
    let interactionTick: Int
    let isCompleting: Bool
    let onGetStarted: () -> Void
    let onOpenLater: () -> Void

    var body: some View {
        VStack(spacing: 26) {
            DynamicIslandHeroView(
                mode: .ready,
                interactionTick: interactionTick,
                showsSparkles: isCompleting
            )
            .padding(.top, 12)

            VStack(spacing: 10) {
                Text("You’re all set 🎉")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(OnboardingPalette.textPrimary)
                    .accessibilityAddTraits(.isHeader)

                Text("Your Dynamic Island companion is ready.")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(OnboardingPalette.textSecondary)

                Text("A quick timer, a responsive companion, and a notch-native surface are ready to settle into the top of your Mac.")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(OnboardingPalette.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)
            }

            Spacer(minLength: 0)

            VStack(spacing: 14) {
                OnboardingActionButton(
                    title: isCompleting ? "Launching…" : "Get Started",
                    tone: .warm,
                    isDisabled: isCompleting,
                    action: onGetStarted
                )
                .accessibilityLabel("Get started with DynamicIsland")

                OnboardingActionButton(
                    title: "Open Settings Later",
                    tone: .tertiary,
                    action: onOpenLater
                )
                .accessibilityLabel("Dismiss onboarding and open settings later")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 12)
    }
}
