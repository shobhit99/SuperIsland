import SwiftUI

enum OnboardingStep: Int, CaseIterable, Identifiable {
    case hello
    case permissions
    case getStarted

    var id: Int { rawValue }
}

@MainActor
final class OnboardingPermissionState: ObservableObject {
    @Published private(set) var screenRecordingGranted = PermissionsManager.shared.checkScreenRecording()
    @Published private(set) var accessibilityGranted = PermissionsManager.shared.checkAccessibility()

    var allRequiredGranted: Bool {
        screenRecordingGranted && accessibilityGranted
    }

    func refresh() {
        screenRecordingGranted = PermissionsManager.shared.checkScreenRecording()
        accessibilityGranted = PermissionsManager.shared.checkAccessibility()
    }

    func isGranted(_ permission: OnboardingPermission) -> Bool {
        switch permission {
        case .screenRecording:
            return screenRecordingGranted
        case .accessibility:
            return accessibilityGranted
        }
    }

    func request(_ permission: OnboardingPermission) {
        switch permission {
        case .screenRecording:
            let granted = PermissionsManager.shared.requestScreenRecordingAccess()
            if !granted {
                PermissionsManager.shared.openScreenRecordingSettings()
            }
        case .accessibility:
            PermissionsManager.shared.requestAccessibility()
        }

        Task {
            try? await Task.sleep(for: .milliseconds(500))
            refresh()
        }
    }
}

struct OnboardingView: View {
    let onFinish: () -> Void

    @StateObject private var permissions = OnboardingPermissionState()
    @State private var currentStep: OnboardingStep = .hello
    @State private var interactionTick = 0
    @State private var isCompleting = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                OnboardingBackdropView()

                VStack(spacing: 22) {
                    OnboardingHeaderView(currentStep: currentStep)

                    ZStack {
                        stageContent
                    }
                    .frame(
                        width: min(max(proxy.size.width - 64, 760), 880),
                        height: min(max(proxy.size.height - 110, 520), 590)
                    )
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 900, minHeight: 620)
    }

    @ViewBuilder
    private var stageContent: some View {
        OnboardingStageCard {
            screenView(for: currentStep)
        }
        .id(currentStep)
        .transition(
            .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            )
        )
    }

    @ViewBuilder
    private func screenView(for step: OnboardingStep) -> some View {
        switch step {
        case .hello:
            HelloScreenView(interactionTick: interactionTick) {
                advance(to: .permissions)
            }
        case .permissions:
            PermissionsScreenView(permissions: permissions) {
                advance(to: .getStarted)
            }
        case .getStarted:
            GetStartedScreenView(
                interactionTick: interactionTick,
                isCompleting: isCompleting,
                onGetStarted: finishOnboarding,
                onOpenLater: onFinish
            )
        }
    }

    private func advance(to step: OnboardingStep) {
        interactionTick += 1
        withAnimation(.spring(response: 0.38, dampingFraction: 0.9)) {
            currentStep = step
        }
    }

    private func finishOnboarding() {
        guard !isCompleting else { return }
        interactionTick += 1
        isCompleting = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            onFinish()
        }
    }
}

private struct OnboardingHeaderView: View {
    let currentStep: OnboardingStep

    var body: some View {
        HStack {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .frame(width: 40, height: 40)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.white.opacity(0.34), lineWidth: 1)
                        )

                    Image(systemName: "capsule.lefthalf.filled")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(OnboardingPalette.coolAccent)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("DynamicIsland")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.96))
                    Text("First Run")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.58))
                }
            }

            Spacer()

            HStack(spacing: 10) {
                ForEach(OnboardingStep.allCases) { step in
                    Capsule(style: .continuous)
                        .fill(step == currentStep ? Color.white.opacity(0.86) : Color.white.opacity(0.18))
                        .frame(width: step == currentStep ? 28 : 8, height: 8)
                        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: currentStep)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(0.16), lineWidth: 1)
                    )
            )
        }
        .padding(.horizontal, 6)
    }
}

private struct OnboardingStageCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.35),
                                    Color.white.opacity(0.08)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(color: Color.black.opacity(0.24), radius: 36, y: 18)
                .shadow(color: Color.black.opacity(0.08), radius: 10, y: 3)

            content
                .padding(34)
        }
    }
}

private struct OnboardingBackdropView: View {
    @State private var drift = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(red: 0.10, green: 0.12, blue: 0.16)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(OnboardingPalette.coolAccent.opacity(0.22))
                .frame(width: 420, height: 420)
                .blur(radius: 42)
                .offset(x: drift ? -230 : -180, y: drift ? -170 : -220)

            Circle()
                .fill(OnboardingPalette.warmAccent.opacity(0.20))
                .frame(width: 320, height: 320)
                .blur(radius: 38)
                .offset(x: drift ? 240 : 170, y: drift ? 200 : 160)

            RoundedRectangle(cornerRadius: 54, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .frame(width: 700, height: 480)
                .rotationEffect(.degrees(-10))
                .blur(radius: 2)
                .offset(x: -120, y: 26)
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 8).repeatForever(autoreverses: true)) {
                drift = true
            }
        }
    }
}

enum OnboardingPalette {
    static let coolAccent = Color(red: 0.49, green: 0.72, blue: 1.0)
    static let warmAccent = Color(red: 0.98, green: 0.67, blue: 0.39)
    static let textPrimary = Color.white.opacity(0.96)
    static let textSecondary = Color.white.opacity(0.68)
    static let textTertiary = Color.white.opacity(0.48)
    static let outline = Color.white.opacity(0.12)
}

struct OnboardingActionButton: View {
    enum Tone {
        case cool
        case warm
        case secondary
        case tertiary
    }

    let title: String
    var systemImage: String? = nil
    var tone: Tone = .cool
    var isDisabled = false
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                }

                Text(title)
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 22)
            .frame(height: 46)
            .background(background)
            .overlay(stroke)
            .shadow(color: shadowColor, radius: isHovering ? 18 : 10, y: isHovering ? 8 : 5)
        }
        .buttonStyle(.plain)
        .scaleEffect(isDisabled ? 1 : (isHovering ? 1.04 : 1.0))
        .opacity(isDisabled ? 0.48 : 1.0)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: isHovering)
        .onHover { hovering in
            guard !isDisabled else { return }
            isHovering = hovering
        }
        .disabled(isDisabled)
    }

    private var foregroundColor: Color {
        switch tone {
        case .cool, .warm:
            return .white
        case .secondary:
            return Color.white.opacity(0.92)
        case .tertiary:
            return OnboardingPalette.textSecondary
        }
    }

    @ViewBuilder
    private var background: some View {
        RoundedRectangle(cornerRadius: 23, style: .continuous)
            .fill(backgroundFill)
    }

    @ViewBuilder
    private var stroke: some View {
        RoundedRectangle(cornerRadius: 23, style: .continuous)
            .stroke(borderColor, lineWidth: 1)
    }

    private var backgroundFill: LinearGradient {
        switch tone {
        case .cool:
            return LinearGradient(
                colors: [
                    OnboardingPalette.coolAccent.opacity(isHovering ? 0.95 : 0.84),
                    Color(red: 0.29, green: 0.53, blue: 0.97)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .warm:
            return LinearGradient(
                colors: [
                    OnboardingPalette.warmAccent.opacity(isHovering ? 0.98 : 0.9),
                    Color(red: 0.92, green: 0.47, blue: 0.25)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .secondary:
            return LinearGradient(
                colors: [
                    Color.white.opacity(isHovering ? 0.16 : 0.12),
                    Color.white.opacity(0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .tertiary:
            return LinearGradient(
                colors: [
                    Color.clear,
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var borderColor: Color {
        switch tone {
        case .cool, .warm:
            return Color.white.opacity(0.18)
        case .secondary:
            return Color.white.opacity(0.12)
        case .tertiary:
            return Color.clear
        }
    }

    private var shadowColor: Color {
        switch tone {
        case .cool:
            return OnboardingPalette.coolAccent.opacity(isHovering ? 0.28 : 0.18)
        case .warm:
            return OnboardingPalette.warmAccent.opacity(isHovering ? 0.32 : 0.2)
        case .secondary, .tertiary:
            return Color.black.opacity(isHovering ? 0.18 : 0.1)
        }
    }
}

struct DynamicIslandHeroView: View {
    enum Mode {
        case hello
        case permissions
        case ready
    }

    let mode: Mode
    let interactionTick: Int
    var showsSparkles = false

    @State private var isFloating = false
    @State private var reactionBump = false
    @State private var isExpanded = false

    var body: some View {
        ZStack(alignment: .top) {
            if mode == .ready {
                readyIsland
            } else {
                compactIsland
            }

            if mode == .hello {
                helloCompanion
            } else if mode == .permissions {
                permissionsCompanion
            }

            if showsSparkles {
                SparkleBurstView()
                    .offset(y: 22)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: mode == .ready ? 190 : 150)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .onAppear {
            withAnimation(.easeInOut(duration: 3.6).repeatForever(autoreverses: true)) {
                isFloating = true
            }

            if mode == .ready {
                withAnimation(.spring(response: 0.56, dampingFraction: 0.84).delay(0.18)) {
                    isExpanded = true
                }
            }
        }
        .onChange(of: interactionTick) { _, _ in
            withAnimation(.spring(response: 0.22, dampingFraction: 0.62)) {
                reactionBump = true
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                    reactionBump = false
                }
            }
        }
    }

    private var compactIsland: some View {
        Capsule(style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.98),
                        Color.black.opacity(0.9)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 214, height: 40)
            .shadow(color: Color.black.opacity(0.4), radius: 22, y: 12)
            .scaleEffect(reactionBump ? 1.03 : 1.0)
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
    }

    private var helloCompanion: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
                .frame(width: 292, height: 92)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(0.16), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.12), radius: 24, y: 12)
                .overlay(alignment: .leading) {
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Focus, right where you are.")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(OnboardingPalette.textPrimary)
                            Text("The island stays close, quiet, and useful.")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(OnboardingPalette.textSecondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 20)
                    .padding(.trailing, 88)
                }

            CompanionAvatarView(size: 72, interactionTick: interactionTick)
                .offset(x: 12, y: -8)
        }
        .offset(y: 26 + (isFloating ? 6 : -2))
    }

    private var permissionsCompanion: some View {
        HStack(spacing: 12) {
            PermissionHeroChip(iconName: "display")
            PermissionHeroChip(iconName: "figure.stand")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.16), lineWidth: 1)
                )
        )
        .shadow(color: Color.black.opacity(0.12), radius: 24, y: 12)
        .offset(y: 28 + (isFloating ? 6 : -2))
    }

    private var readyIsland: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.98),
                            Color.black.opacity(0.86)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: isExpanded ? 330 : 286, height: 90)
                .shadow(color: Color.black.opacity(0.46), radius: 32, y: 14)
                .overlay(
                    RoundedRectangle(cornerRadius: 32, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
                .scaleEffect(reactionBump ? 1.03 : 1.0)

            HStack(spacing: 16) {
                CompanionAvatarView(size: 54, interactionTick: interactionTick)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Pomodoro")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.58))
                    Text("24:58")
                        .font(.system(size: 28, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(Color.white.opacity(0.96))
                }

                Spacer(minLength: 0)

                HStack(spacing: 4) {
                    ForEach(0..<5, id: \.self) { index in
                        Capsule(style: .continuous)
                            .fill(index < 3 ? OnboardingPalette.coolAccent : Color.white.opacity(0.18))
                            .frame(width: 6, height: CGFloat(18 + (index * 4)))
                    }
                }
                .padding(.trailing, 4)
            }
            .padding(.horizontal, 18)
            .frame(width: isExpanded ? 330 : 286, height: 90)
        }
        .offset(y: 12 + (isFloating ? 6 : -1))
    }

    private var accessibilityLabel: String {
        switch mode {
        case .hello:
            return "Dynamic Island hello preview with animated companion avatar"
        case .permissions:
            return "Dynamic Island permissions preview"
        case .ready:
            return "Dynamic Island expanded preview showing a Pomodoro timer"
        }
    }
}

private struct PermissionHeroChip: View {
    let iconName: String

    var body: some View {
        Image(systemName: iconName)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.92))
            .frame(width: 50, height: 50)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.09))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
            )
    }
}

struct CompanionAvatarView: View {
    let size: CGFloat
    let interactionTick: Int

    @State private var isBreathing = false
    @State private var isBlinking = false
    @State private var reactionLift = false

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.98),
                            Color(red: 0.91, green: 0.95, blue: 1.0)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Circle()
                .stroke(Color.white.opacity(0.46), lineWidth: 1)

            VStack(spacing: size * 0.08) {
                HStack(spacing: size * 0.14) {
                    Capsule(style: .continuous)
                        .fill(Color.black.opacity(0.82))
                        .frame(width: size * 0.1, height: isBlinking ? 2 : size * 0.14)
                    Capsule(style: .continuous)
                        .fill(Color.black.opacity(0.82))
                        .frame(width: size * 0.1, height: isBlinking ? 2 : size * 0.14)
                }

                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.68))
                    .frame(width: size * 0.2, height: size * 0.06)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: Color.black.opacity(0.16), radius: 16, y: 10)
        .scaleEffect(isBreathing ? 1.03 : 0.97)
        .offset(y: reactionLift ? -5 : (isBreathing ? -2 : 2))
        .animation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true), value: isBreathing)
        .onAppear {
            isBreathing = true
            scheduleBlinkLoop()
        }
        .onChange(of: interactionTick) { _, _ in
            withAnimation(.spring(response: 0.26, dampingFraction: 0.62)) {
                reactionLift = true
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                    reactionLift = false
                }
            }
        }
    }

    private func scheduleBlinkLoop() {
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double.random(in: 2.5...4.8)))
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        isBlinking = true
                    }
                }

                try? await Task.sleep(for: .milliseconds(120))

                await MainActor.run {
                    withAnimation(.easeOut(duration: 0.16)) {
                        isBlinking = false
                    }
                }
            }
        }
    }
}

private struct SparkleBurstView: View {
    @State private var animate = false

    var body: some View {
        ZStack {
            ForEach(0..<6, id: \.self) { index in
                let angle = Double(index) * 60
                Image(systemName: index.isMultiple(of: 2) ? "sparkles" : "star.fill")
                    .font(.system(size: index.isMultiple(of: 2) ? 14 : 8, weight: .semibold))
                    .foregroundStyle(index.isMultiple(of: 2) ? Color.white.opacity(0.9) : OnboardingPalette.warmAccent)
                    .offset(
                        x: animate ? CGFloat(cos(angle * .pi / 180) * 84) : 0,
                        y: animate ? CGFloat(sin(angle * .pi / 180) * 46) : 0
                    )
                    .scaleEffect(animate ? 1 : 0.3)
                    .opacity(animate ? 0 : 1)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.7)) {
                animate = true
            }
        }
    }
}
