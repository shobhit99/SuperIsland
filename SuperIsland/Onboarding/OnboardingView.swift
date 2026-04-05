import AppKit
import SwiftUI

// MARK: - Layout Constants

enum OnboardingLayout {
    static let windowSize = CGSize(width: 680, height: 560)
}

private enum OnboardingMetrics {
    static let contentWidth: CGFloat = 480
}

// MARK: - Steps

private enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcome
    case permissions
    case gestures
    case extensions
    case ready

    var id: Int { rawValue }
}

// MARK: - Design Tokens

private enum OBColors {
    static let accent = Color(red: 0.72, green: 0.96, blue: 0.84)
    static let textPrimary = Color.white.opacity(0.96)
    static let textSecondary = Color.white.opacity(0.55)
    static let textTertiary = Color.white.opacity(0.38)
    static let cardFill = Color.white.opacity(0.035)
    static let cardStroke = Color.white.opacity(0.08)
    static let rowHoverFill = Color.white.opacity(0.055)
}

// MARK: - Animations

private enum OBAnimations {
    static let page = Animation.spring(response: 0.5, dampingFraction: 0.92)
    static let hover = Animation.spring(response: 0.25, dampingFraction: 0.86)
    static let gentle = Animation.easeInOut(duration: 0.3)
}

// MARK: - Permissions ViewModel

@MainActor
final class OnboardingPermissionsViewModel: ObservableObject {
    @Published private(set) var states: [PermissionType: Bool] = [:]

    private var accessibilityEverGranted: Bool
    private var bluetoothEverGranted: Bool
    private var pollTask: Task<Void, Never>?

    init() {
        accessibilityEverGranted = PermissionsManager.shared.checkAccessibility()
        bluetoothEverGranted = PermissionsManager.shared.checkBluetooth()

        // Populate states eagerly so the first render shows already-granted permissions
        var initial: [PermissionType: Bool] = [:]
        for p in PermissionType.allCases {
            switch p {
            case .accessibility:
                initial[p] = accessibilityEverGranted
            case .bluetooth:
                initial[p] = bluetoothEverGranted
            case .notifications:
                // Requires async — will be filled on first refresh
                initial[p] = false
            default:
                initial[p] = PermissionsManager.shared.check(p)
            }
        }
        states = initial
    }

    deinit { pollTask?.cancel() }

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refresh()
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    func refresh() async {
        var next: [PermissionType: Bool] = [:]
        for p in PermissionType.allCases {
            switch p {
            case .accessibility:
                // AXIsProcessTrusted() can be stale within the same process —
                // once granted, latch it so it never flips back to false
                if !accessibilityEverGranted {
                    accessibilityEverGranted = PermissionsManager.shared.checkAccessibility()
                }
                next[p] = accessibilityEverGranted
            case .bluetooth:
                // CBManager.authorization can be stale similarly
                if !bluetoothEverGranted {
                    bluetoothEverGranted = PermissionsManager.shared.checkBluetooth()
                }
                next[p] = bluetoothEverGranted
            case .notifications:
                next[p] = await PermissionsManager.shared.notificationsGranted()
            default:
                // Calendar, location, microphone, screenRecording — always re-check
                next[p] = PermissionsManager.shared.check(p)
            }
        }
        states = next
    }

    func request(_ permission: PermissionType) {
        PermissionsManager.shared.request(permission)
    }

    func isGranted(_ p: PermissionType) -> Bool {
        states[p] ?? false
    }

    var requiredGranted: Bool {
        PermissionType.allCases
            .filter(\.isRequired)
            .allSatisfy { states[$0] ?? false }
    }
}

// MARK: - Root View

struct OnboardingView: View {
    let onComplete: () -> Void
    let onOpenSettings: () -> Void

    @StateObject private var permissions = OnboardingPermissionsViewModel()
    @State private var step: OnboardingStep = .welcome
    @State private var previousStep: OnboardingStep = .welcome
    @State private var launching = false
    @State private var enabledExtensions: Set<String> = []

    private var isForward: Bool {
        step.rawValue >= previousStep.rawValue
    }

    var body: some View {
        ZStack {
            OnboardingBackdrop()

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                ZStack {
                    switch step {
                    case .welcome:
                        WelcomeScreen(next: goTo(.permissions))
                            .transition(pageTransition)
                    case .permissions:
                        PermissionsScreen(
                            permissions: permissions,
                            back: goTo(.welcome),
                            next: goTo(.gestures)
                        )
                        .transition(pageTransition)
                    case .gestures:
                        GesturesScreen(
                            back: goTo(.permissions),
                            next: goTo(.extensions)
                        )
                        .transition(pageTransition)
                    case .extensions:
                        ExtensionsScreen(
                            enabled: $enabledExtensions,
                            back: goTo(.gestures),
                            next: goTo(.ready)
                        )
                        .transition(pageTransition)
                    case .ready:
                        ReadyScreen(
                            permissions: permissions,
                            enabledExtensions: enabledExtensions,
                            launching: launching,
                            back: goTo(.extensions),
                            getStarted: launchApp,
                            openSettings: onOpenSettings
                        )
                        .transition(pageTransition)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Step dots
                StepDots(current: step)
                    .padding(.top, 16)
                    .padding(.bottom, 20)
            }
            .padding(.horizontal, 40)
            .padding(.top, 32)
        }
        .frame(width: OnboardingLayout.windowSize.width, height: OnboardingLayout.windowSize.height)
        .onAppear {
            Task {
                await permissions.refresh()
                permissions.startPolling()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                await permissions.refresh()
            }
        }
    }

    private var pageTransition: AnyTransition {
        if isForward {
            return .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            )
        } else {
            return .asymmetric(
                insertion: .move(edge: .leading).combined(with: .opacity),
                removal: .move(edge: .trailing).combined(with: .opacity)
            )
        }
    }

    private func goTo(_ target: OnboardingStep) -> () -> Void {
        {
            withAnimation(OBAnimations.page) {
                previousStep = step
                step = target
            }
        }
    }

    private func launchApp() {
        guard !launching else { return }
        launching = true

        // Activate selected extensions
        let manager = ExtensionManager.shared
        manager.discoverExtensions()
        for ext in OnboardingExtensionInfo.available where enabledExtensions.contains(ext.id) {
            manager.activate(extensionID: ext.id)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            onComplete()
        }
    }
}

// MARK: - Step Dots

private struct StepDots: View {
    let current: OnboardingStep

    var body: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingStep.allCases) { step in
                Circle()
                    .fill(step == current ? Color.white.opacity(0.9) : Color.white.opacity(0.18))
                    .frame(width: 6, height: 6)
                    .scaleEffect(step == current ? 1.15 : 1)
                    .animation(OBAnimations.gentle, value: current)
            }
        }
    }
}

// MARK: - Screen 1: Welcome

private struct WelcomeScreen: View {
    let next: () -> Void
    @State private var trimEnd: CGFloat = 0
    @State private var showContent = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)

            // Animated "hello" script
            HelloScriptShape()
                .trim(from: 0, to: trimEnd)
                .stroke(
                    Color.white.opacity(0.9),
                    style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round)
                )
                .frame(width: 260, height: 80)
                .padding(.bottom, 24)

            VStack(spacing: 8) {
                Text("Welcome to SuperIsland")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(OBColors.textPrimary)

                Text("Your notch, reimagined. A quick setup\nand you're ready to go.")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(OBColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
            .opacity(showContent ? 1 : 0)
            .offset(y: showContent ? 0 : 10)

            Spacer(minLength: 20)

            PrimaryButton(title: "Get Started", action: next)
                .opacity(showContent ? 1 : 0)
        }
        .frame(maxWidth: OnboardingMetrics.contentWidth)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.8)) {
                trimEnd = 1.0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                withAnimation(.easeOut(duration: 0.6)) {
                    showContent = true
                }
            }
        }
    }
}

// MARK: - Screen 2: Permissions

private struct PermissionsScreen: View {
    @ObservedObject var permissions: OnboardingPermissionsViewModel
    let back: () -> Void
    let next: () -> Void

    private let permissionOrder: [PermissionType] = [
        .accessibility, .calendar, .location, .bluetooth
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavBackButton(action: back)
                .padding(.bottom, 20)

            VStack(alignment: .leading, spacing: 6) {
                Text("Permissions")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(OBColors.textPrimary)

                Text("SuperIsland needs a few permissions to work properly.")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(OBColors.textSecondary)
            }
            .padding(.bottom, 20)

            VStack(spacing: 1) {
                ForEach(permissionOrder, id: \.self) { permission in
                    PermissionRow(
                        permission: permission,
                        isGranted: permissions.isGranted(permission),
                        action: { permissions.request(permission) }
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Spacer(minLength: 0)

            PrimaryButton(title: "Continue", action: next)
        }
        .frame(maxWidth: OnboardingMetrics.contentWidth, maxHeight: .infinity, alignment: .top)
    }
}

private struct PermissionRow: View {
    let permission: PermissionType
    let isGranted: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            Image(systemName: permission.iconName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isGranted ? OBColors.accent : Color.white.opacity(0.7))
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.white.opacity(isGranted ? 0.08 : 0.04)))

            // Info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(permission.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(OBColors.textPrimary)

                    if permission.isRequired {
                        Text("Required")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.4))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.white.opacity(0.06)))
                    }
                }

                Text(permission.description)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(OBColors.textTertiary)
            }

            Spacer(minLength: 4)

            // Status / Action
            if isGranted {
                GrantedBadge()
            } else {
                Button(action: action) {
                    Text(permission == .bluetooth ? "Open Settings" : "Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                        .overlay(Capsule().stroke(OBColors.cardStroke, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(hovering ? OBColors.rowHoverFill : OBColors.cardFill)
        .onHover { active in
            withAnimation(OBAnimations.hover) { hovering = active }
        }
    }
}

private struct GrantedBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark")
                .font(.system(size: 8, weight: .bold))
            Text("Granted")
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(OBColors.accent)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(OBColors.accent.opacity(0.1)))
    }
}

// MARK: - Screen 3: Gestures

private struct GesturesScreen: View {
    let back: () -> Void
    let next: () -> Void
    @State private var handOffset: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                NavBackButton(action: back)
                Spacer()
            }
            .frame(maxWidth: OnboardingMetrics.contentWidth)
            .padding(.bottom, 12)

            // GIF with swipe hand overlay
            ZStack {
                Color.black

                AnimatedGIFView(name: "Area")
                    .frame(width: 520, height: 252)

                // Animated swipe hand
                SwipeIndicator()
                    .offset(x: handOffset)
            }
            .frame(width: 520, height: 252)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(OBColors.cardStroke, lineWidth: 1)
            )

            Spacer(minLength: 16)

            // Gesture instructions
            VStack(spacing: 6) {
                Text("Swipe the island")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(OBColors.textPrimary)

                Text("Swipe left or right on the notch to switch between modules.")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(OBColors.textSecondary)
                    .multilineTextAlignment(.center)
            }

            Spacer(minLength: 0)

            PrimaryButton(title: "Continue", action: next)
        }
        .frame(maxWidth: OnboardingMetrics.contentWidth, maxHeight: .infinity)
        .onAppear {
            // Smooth left-right animation with wide travel
            withAnimation(
                .easeInOut(duration: 1.4)
                .repeatForever(autoreverses: true)
            ) {
                handOffset = 50
            }
        }
    }
}

private struct SwipeIndicator: View {
    var body: some View {
        VStack(spacing: 3) {
            ArcShape()
                .stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .frame(width: 26, height: 14)

            Image(systemName: "hand.point.up.fill")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(.white.opacity(0.85))

            Text("SWIPE")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
                .tracking(1.5)
        }
        .shadow(color: .black.opacity(0.6), radius: 12, y: 4)
    }
}

private struct ArcShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + 2, y: rect.maxY))
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX - 2, y: rect.minY + 4),
            control: CGPoint(x: rect.minX + 4, y: rect.minY - 4)
        )
        p.move(to: CGPoint(x: rect.maxX - 2, y: rect.minY + 4))
        p.addLine(to: CGPoint(x: rect.maxX - 8, y: rect.minY))
        p.move(to: CGPoint(x: rect.maxX - 2, y: rect.minY + 4))
        p.addLine(to: CGPoint(x: rect.maxX + 2, y: rect.minY + 12))
        return p
    }
}

// MARK: - Screen 4: Extensions

private struct OnboardingExtensionInfo: Identifiable {
    let id: String
    let name: String
    let description: String
    let fallbackIcon: String
    let badge: String?

    @MainActor
    var iconImage: NSImage? {
        ExtensionManager.shared.installed.first(where: { $0.id == id })?.iconImage
    }

    static let available: [OnboardingExtensionInfo] = [
        OnboardingExtensionInfo(
            id: "com.workview.pomodoro",
            name: "Pomodoro Timer",
            description: "Focus timer with countdown in the island",
            fallbackIcon: "timer",
            badge: nil
        ),
        OnboardingExtensionInfo(
            id: "com.workview.whatsapp-web",
            name: "WhatsApp Web",
            description: "Route WhatsApp messages to the island",
            fallbackIcon: "message.fill",
            badge: "Requires Login"
        ),
        OnboardingExtensionInfo(
            id: "com.workview.ai-usage",
            name: "AI Usage",
            description: "Claude & Codex usage rings in the notch",
            fallbackIcon: "brain.head.profile",
            badge: nil
        ),
    ]
}

private struct ExtensionsScreen: View {
    @Binding var enabled: Set<String>
    let back: () -> Void
    let next: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavBackButton(action: back)
                .padding(.bottom, 20)

            VStack(alignment: .leading, spacing: 6) {
                Text("Extensions")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(OBColors.textPrimary)

                Text("Add extra capabilities to your island.")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(OBColors.textSecondary)
            }
            .padding(.bottom, 20)

            VStack(spacing: 1) {
                ForEach(OnboardingExtensionInfo.available) { ext in
                    ExtensionRow(
                        ext: ext,
                        isEnabled: enabled.contains(ext.id),
                        toggle: {
                            if enabled.contains(ext.id) {
                                enabled.remove(ext.id)
                            } else {
                                enabled.insert(ext.id)
                            }
                        }
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Spacer(minLength: 0)

            PrimaryButton(title: "Continue", action: next)
        }
        .frame(maxWidth: OnboardingMetrics.contentWidth, maxHeight: .infinity, alignment: .top)
    }
}

private struct ExtensionRow: View {
    let ext: OnboardingExtensionInfo
    let isEnabled: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            extensionIcon

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(ext.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(OBColors.textPrimary)

                    if let badge = ext.badge {
                        Text(badge)
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.45))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.white.opacity(0.06)))
                    }
                }

                Text(ext.description)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(OBColors.textTertiary)
            }

            Spacer(minLength: 4)

            Button(action: toggle) {
                Text(isEnabled ? "Added" : "Add")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isEnabled ? OBColors.accent : Color.white.opacity(0.85))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill(isEnabled ? OBColors.accent.opacity(0.1) : Color.white.opacity(0.08))
                    )
                    .overlay(
                        Capsule().stroke(
                            isEnabled ? OBColors.accent.opacity(0.2) : OBColors.cardStroke,
                            lineWidth: 1
                        )
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(hovering ? OBColors.rowHoverFill : OBColors.cardFill)
        .onHover { active in
            withAnimation(OBAnimations.hover) { hovering = active }
        }
    }

    @ViewBuilder
    private var extensionIcon: some View {
        if let nsImage = ext.iconImage {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 22, height: 22)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.white.opacity(0.06)))
        } else {
            Image(systemName: ext.fallbackIcon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.7))
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.white.opacity(0.06)))
        }
    }
}

// MARK: - Screen 5: Ready

private struct ReadyScreen: View {
    @ObservedObject var permissions: OnboardingPermissionsViewModel
    let enabledExtensions: Set<String>
    let launching: Bool
    let back: () -> Void
    let getStarted: () -> Void
    let openSettings: () -> Void

    private var grantedCount: Int {
        [PermissionType.accessibility, .calendar, .location, .bluetooth]
            .filter { permissions.isGranted($0) }
            .count
    }

    private var enabledNames: String {
        let names = OnboardingExtensionInfo.available
            .filter { enabledExtensions.contains($0.id) }
            .map(\.name)
        if names.isEmpty { return "None" }
        return names.joined(separator: ", ")
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)

            // Checkmark
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(OBColors.accent)
                .padding(.bottom, 20)

            VStack(spacing: 8) {
                Text("You're all set")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(OBColors.textPrimary)

                Text("SuperIsland will run in the background.")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(OBColors.textSecondary)
            }
            .padding(.bottom, 24)

            // Summary
            VStack(spacing: 1) {
                SummaryRow(
                    icon: "checkmark.shield.fill",
                    title: "Permissions",
                    detail: "\(grantedCount) of 4 granted",
                    isFirst: true
                )
                SummaryRow(
                    icon: "puzzlepiece.extension.fill",
                    title: "Extensions",
                    detail: enabledNames,
                    isFirst: false
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .frame(maxWidth: 360)

            Spacer(minLength: 20)

            VStack(spacing: 10) {
                PrimaryButton(
                    title: launching ? "Launching..." : "Get Started",
                    isDisabled: launching,
                    action: getStarted
                )

                Button(action: openSettings) {
                    Text("Open Settings Instead")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.35))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: OnboardingMetrics.contentWidth, maxHeight: .infinity)
    }
}

private struct SummaryRow: View {
    let icon: String
    let title: String
    let detail: String
    let isFirst: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(OBColors.accent)
                .frame(width: 24)

            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(OBColors.textPrimary)

            Spacer()

            Text(detail)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(OBColors.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(OBColors.cardFill)
    }
}

// MARK: - Shared Components

private struct PrimaryButton: View {
    let title: String
    var isDisabled: Bool = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.black.opacity(isDisabled ? 0.5 : 0.92))
                .frame(width: 200, height: 42)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(isDisabled ? 0.4 : 0.92))
                )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .scaleEffect(hovering && !isDisabled ? 1.02 : 1)
        .onHover { active in
            withAnimation(OBAnimations.hover) { hovering = active }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct NavBackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                Text("Back")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(Color.white.opacity(0.55))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Backdrop

private struct OnboardingBackdrop: View {
    @State private var animate = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(red: 0.02, green: 0.02, blue: 0.03)

                // Subtle animated glow
                Circle()
                    .fill(Color(red: 0.14, green: 0.2, blue: 0.28).opacity(0.7))
                    .frame(width: proxy.size.width * 0.7)
                    .blur(radius: 130)
                    .offset(
                        x: animate ? proxy.size.width * 0.2 : proxy.size.width * 0.3,
                        y: animate ? -proxy.size.height * 0.2 : -proxy.size.height * 0.28
                    )

                Circle()
                    .fill(Color(red: 0.08, green: 0.1, blue: 0.14).opacity(0.8))
                    .frame(width: proxy.size.width * 0.5)
                    .blur(radius: 100)
                    .offset(
                        x: animate ? -proxy.size.width * 0.18 : -proxy.size.width * 0.24,
                        y: animate ? proxy.size.height * 0.25 : proxy.size.height * 0.3
                    )
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 14).repeatForever(autoreverses: true)) {
                    animate = true
                }
            }
        }
        .clipped()
    }
}

// MARK: - Hello Script Shape (Lottie path data)

private struct HelloScriptShape: Shape {
    func path(in rect: CGRect) -> Path {
        let srcW: CGFloat = 284
        let srcH: CGFloat = 74
        let scaleX = rect.width / srcW
        let scaleY = rect.height / srcH
        let scale = min(scaleX, scaleY)
        let offsetX = rect.midX - (srcW * scale) / 2
        let offsetY = rect.midY - (srcH * scale) / 2

        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: (x + 146) * scale + offsetX, y: (y + 30) * scale + offsetY)
        }

        let v: [(CGFloat, CGFloat)] = [
            (-145.66, 43.747), (-81.851, -26.162), (-101.426, -23.013),
            (-109.596, 40.561), (-85.851, 1.753), (-69, 40.305),
            (-26.873, 10.943), (-50.022, 11.966), (-23.54, 40.581),
            (23.936, -26.077), (6.574, -29.397), (12.958, 41.583),
            (67.086, -23.779), (50.234, -30.673), (59.937, 41.326),
            (102.898, -0.05), (118.532, 21.029), (95.809, 40.943),
            (83.425, 17.072), (102.898, -0.05), (124.149, 5.199),
            (138.27, -2.922)
        ]
        let inT: [(CGFloat, CGFloat)] = [
            (0, 0), (-4.256, 36.426), (2.853, -21.124),
            (0, 0), (-18.128, -1.787), (-22.979, -0.255),
            (-0.766, 11.745), (5.66, -16.852), (-20.044, 4.321),
            (-1.453, 15.25), (7.149, -14.297), (-24.203, -4.498),
            (-2.809, 17.873), (8.422, -15.279), (-32.094, 2.751),
            (-25.982, 2.314), (0.854, -11.109), (10.851, 1.532),
            (-2.587, 8.901), (-6.236, 0.17), (-7.915, 0.128),
            (0, 0)
        ]
        let outT: [(CGFloat, CGFloat)] = [
            (0, 0), (2.427, -20.781), (-2.331, 17.258),
            (0, 0), (19.915, 2.33), (20.427, 0.227),
            (0.883, -13.542), (-5.204, 15.495), (30.881, -6.659),
            (1.531, -16.085), (-6.678, 13.357), (28.851, 5.361),
            (2.716, -17.287), (-9.068, 16.45), (26.809, -2.298),
            (11.664, -1.038), (-0.894, 11.617), (-9.911, -1.399),
            (3.192, -10.978), (8.868, -0.24), (7.03, -0.113),
            (0, 0)
        ]

        var path = Path()
        path.move(to: pt(v[0].0, v[0].1))
        for i in 1..<v.count {
            let cp1 = pt(v[i-1].0 + outT[i-1].0, v[i-1].1 + outT[i-1].1)
            let cp2 = pt(v[i].0 + inT[i].0, v[i].1 + inT[i].1)
            let end = pt(v[i].0, v[i].1)
            path.addCurve(to: end, control1: cp1, control2: cp2)
        }
        return path
    }
}

// MARK: - Animated GIF View

private struct AnimatedGIFView: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> AnimatedGIFNSView {
        let view = AnimatedGIFNSView()
        view.configure(resourceName: name)
        return view
    }

    func updateNSView(_ nsView: AnimatedGIFNSView, context: Context) {
        nsView.configure(resourceName: name)
    }
}

private final class AnimatedGIFNSView: NSView {
    private let imageView = NSImageView()
    private var currentResourceName: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        imageView.imageAlignment = .alignCenter
        imageView.imageScaling = .scaleAxesIndependently
        imageView.animates = true
        imageView.autoresizingMask = [.width, .height]

        addSubview(imageView)
    }

    override func layout() {
        super.layout()
        imageView.frame = bounds
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        restartAnimationIfNeeded()
    }

    func configure(resourceName: String) {
        if currentResourceName != resourceName {
            currentResourceName = resourceName

            if let url = Bundle.main.url(forResource: resourceName, withExtension: "gif"),
               let image = NSImage(contentsOf: url) {
                imageView.image = image
            } else {
                imageView.image = nil
            }
        }

        restartAnimationIfNeeded()
    }

    private func restartAnimationIfNeeded() {
        guard imageView.image != nil else { return }
        imageView.animates = false
        imageView.animates = true
        imageView.needsDisplay = true
    }
}

// MARK: - Permission Extension

private extension PermissionType {
    var requestActionTitle: String {
        switch self {
        case .bluetooth:
            return "Open Settings"
        default:
            return "Request Access"
        }
    }
}
