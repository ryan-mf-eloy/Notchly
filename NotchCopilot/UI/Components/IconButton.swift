import AppKit
import SwiftUI

struct MouseDownActionOverlay: NSViewRepresentable {
    var action: () -> Void
    var onHover: (Bool) -> Void = { _ in }
    var onPress: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> MouseDownActionNSView {
        let view = MouseDownActionNSView()
        view.action = action
        view.onHover = onHover
        view.onPress = onPress
        return view
    }

    func updateNSView(_ view: MouseDownActionNSView, context: Context) {
        view.action = action
        view.onHover = onHover
        view.onPress = onPress
    }
}

final class MouseDownActionNSView: NSView {
    var action: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var onPress: ((Bool) -> Void)?
    private var trackingAreaRef: NSTrackingArea?
    private var isHovering = false

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func becomeFirstResponder() -> Bool {
        false
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func updateTrackingAreas() {
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .enabledDuringMouseDrag, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        trackingAreaRef = trackingArea
        addTrackingArea(trackingArea)
        super.updateTrackingAreas()
        refreshHoverStateFromCurrentMouseLocation()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshHoverStateFromCurrentMouseLocation()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refreshHoverStateFromCurrentMouseLocation()
    }

    override func mouseDown(with event: NSEvent) {
        _ = FocusSafeInteractionPolicy.canPerformOverlayActionWithoutActivation {
            updateHoverState(for: event)
            onPress?(true)
            action?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.onPress?(false)
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        onPress?(false)
        super.mouseUp(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHoverState(for: event)
        super.mouseMoved(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        updateHoverState(for: event)
        super.mouseDragged(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        setHovering(true)
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        setHovering(false)
        onPress?(false)
        super.mouseExited(with: event)
    }

    private func updateHoverState(for event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        setHovering(bounds.contains(localPoint))
    }

    private func setHovering(_ hovering: Bool) {
        guard isHovering != hovering else { return }
        isHovering = hovering
        onHover?(hovering)
    }

    private func refreshHoverStateFromCurrentMouseLocation() {
        guard let window else {
            setHovering(false)
            return
        }
        let localPoint = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setHovering(bounds.contains(localPoint))
    }
}

enum IconButtonSize {
    case standard
    case header
    case compact

    var diameter: CGFloat {
        switch self {
        case .standard: 34
        case .header: 30
        case .compact: 28
        }
    }

    var symbolSize: CGFloat {
        switch self {
        case .standard: 12
        case .header: 10.5
        case .compact: 10.5
        }
    }

    var strokeWidth: CGFloat {
        switch self {
        case .standard: 0.7
        case .header: 0.6
        case .compact: 0.55
        }
    }

    var hitDiameter: CGFloat {
        switch self {
        case .standard: 40
        case .header: 36
        case .compact: 32
        }
    }
}

struct IconButton: View {
    var systemName: String
    var help: String
    var role: ButtonRole? = nil
    var isActive: Bool = false
    var isDisabled: Bool = false
    var size: IconButtonSize = .standard
    var feedbackDelayMs: UInt64 = 0
    var action: () -> Void
    @Environment(\.islandDesignMode) private var islandDesignMode
    @State private var isHovering = false
    @State private var isOverlayPressed = false

    var body: some View {
        Button(role: role, action: performAction) {
            Image(systemName: systemName)
        }
        .buttonStyle(IslandIconButtonStyle(
            role: role,
            isActive: isActive,
            isDisabled: isDisabled,
            size: size,
            designMode: islandDesignMode,
            isHovering: isHovering,
            isOverlayPressed: isOverlayPressed
        ))
        .frame(width: size.hitDiameter, height: size.hitDiameter)
        .contentShape(Rectangle())
        .overlay {
            if !isDisabled {
                MouseDownActionOverlay(
                    action: performAction,
                    onHover: { hovering in
                        isHovering = hovering
                    },
                    onPress: { pressing in
                        isOverlayPressed = pressing
                    }
                )
                .frame(width: size.hitDiameter, height: size.hitDiameter)
                .contentShape(Rectangle())
            }
        }
        .disabled(isDisabled)
        .help(help)
        .accessibilityLabel(Text(help))
    }

    private func performAction() {
        guard feedbackDelayMs > 0 else {
            action()
            return
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(feedbackDelayMs))
            action()
        }
    }
}

struct IslandPillButton: View {
    var title: String
    var help: String
    var role: ButtonRole? = nil
    var width: CGFloat
    var height: CGFloat = 42
    var fontSize: CGFloat = 14
    var action: () -> Void
    @Environment(\.islandDesignMode) private var islandDesignMode
    @State private var isHovering = false
    @State private var isOverlayPressed = false

    var body: some View {
        Button(role: role, action: action) {
            Text(title)
        }
        .buttonStyle(IslandPillButtonStyle(
            role: role,
            width: width,
            height: height,
            fontSize: fontSize,
            designMode: islandDesignMode,
            isHovering: isHovering,
            isOverlayPressed: isOverlayPressed
        ))
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .overlay {
            MouseDownActionOverlay(
                action: action,
                onHover: { hovering in
                    isHovering = hovering
                },
                onPress: { pressing in
                    isOverlayPressed = pressing
                }
            )
            .frame(width: width, height: height)
            .contentShape(Rectangle())
        }
        .help(help)
        .accessibilityLabel(Text(help))
    }
}

private struct IslandIconButtonStyle: ButtonStyle {
    var role: ButtonRole?
    var isActive: Bool
    var isDisabled: Bool
    var size: IconButtonSize
    var designMode: IslandDesignMode
    var isHovering: Bool
    var isOverlayPressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed || isOverlayPressed
        configuration.label
            .font(.system(size: size.symbolSize, weight: .semibold))
            .foregroundStyle(Color.white.opacity(foregroundOpacity(isPressed: pressed)))
            .frame(width: size.diameter, height: size.diameter)
            .background(
                IslandGlassFill(
                    shape: Circle(),
                    mode: designMode,
                    solidOpacity: backgroundOpacity(isPressed: pressed),
                    glassTintOpacity: glassTintOpacity(isPressed: pressed),
                    glassFallbackOpacity: glassFallbackOpacity(isPressed: pressed)
                )
            )
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(strokeOpacity(isPressed: pressed)), lineWidth: size.strokeWidth)
            )
            .frame(width: size.hitDiameter, height: size.hitDiameter)
            .contentShape(Rectangle())
            .scaleEffect(scale(isPressed: pressed))
            .opacity(isDisabled ? 0.38 : 1)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.10), value: isOverlayPressed)
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private func foregroundOpacity(isPressed: Bool) -> Double {
        guard !isDisabled else { return 0.52 }
        if isPressed { return 0.98 }
        if isActive { return 0.94 }
        if isHovering { return role == .destructive ? 0.94 : 0.9 }
        return role == .destructive ? 0.88 : 0.74
    }

    private func backgroundOpacity(isPressed: Bool) -> Double {
        guard designMode == .solid else { return glassFallbackOpacity(isPressed: isPressed) }
        let compactMultiplier = size == .compact ? 0.82 : 1
        guard !isDisabled else { return 0.055 * compactMultiplier }
        if isPressed { return (role == .destructive ? 0.24 : 0.19) * compactMultiplier }
        if isHovering { return role == .destructive ? 0.18 : 0.14 }
        if isActive { return 0.18 * compactMultiplier }
        return (role == .destructive ? 0.13 : 0.085) * compactMultiplier
    }

    private func strokeOpacity(isPressed: Bool) -> Double {
        if designMode == .liquidGlass {
            guard !isDisabled else { return 0.055 }
            if isPressed { return role == .destructive ? 0.24 : 0.21 }
            if isHovering || isActive { return 0.15 }
            return 0.095
        }
        guard !isDisabled else { return 0.045 }
        if isPressed { return 0.24 }
        if isHovering || isActive { return 0.16 }
        return 0.07
    }

    private func glassTintOpacity(isPressed: Bool) -> Double {
        let compactMultiplier = size == .compact ? 0.88 : 1
        guard !isDisabled else { return 0.035 * compactMultiplier }
        if isPressed { return (role == .destructive ? 0.15 : 0.13) * compactMultiplier }
        if isHovering { return (role == .destructive ? 0.12 : 0.095) * compactMultiplier }
        if isActive { return 0.10 * compactMultiplier }
        return 0.052 * compactMultiplier
    }

    private func glassFallbackOpacity(isPressed: Bool) -> Double {
        let compactMultiplier = size == .compact ? 0.76 : 1
        guard !isDisabled else { return 0.038 * compactMultiplier }
        if isPressed { return (role == .destructive ? 0.16 : 0.13) * compactMultiplier }
        if isHovering { return (role == .destructive ? 0.125 : 0.095) * compactMultiplier }
        if isActive { return 0.10 * compactMultiplier }
        return 0.050 * compactMultiplier
    }

    private func scale(isPressed: Bool) -> CGFloat {
        guard !isDisabled else { return 1 }
        if isPressed { return 0.955 }
        if isHovering { return 1.035 }
        return 1
    }
}

private struct IslandPillButtonStyle: ButtonStyle {
    var role: ButtonRole?
    var width: CGFloat
    var height: CGFloat
    var fontSize: CGFloat
    var designMode: IslandDesignMode
    var isHovering: Bool
    var isOverlayPressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed || isOverlayPressed
        configuration.label
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(Color.white.opacity(pressed ? 0.98 : 0.92))
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .padding(.horizontal, 14)
            .frame(width: width, height: height)
            .background(
                IslandGlassFill(
                    shape: Capsule(style: .continuous),
                    mode: designMode,
                    solidOpacity: backgroundOpacity(isPressed: pressed),
                    glassTintOpacity: glassTintOpacity(isPressed: pressed),
                    glassFallbackOpacity: glassFallbackOpacity(isPressed: pressed)
                )
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(strokeOpacity(isPressed: pressed)), lineWidth: 0.7)
            )
            .contentShape(Capsule(style: .continuous))
            .scaleEffect(pressed ? 0.975 : (isHovering ? 1.012 : 1))
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.10), value: isOverlayPressed)
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private func backgroundOpacity(isPressed: Bool) -> Double {
        guard designMode == .solid else { return glassFallbackOpacity(isPressed: isPressed) }
        if isPressed { return role == .destructive ? 0.20 : 0.17 }
        if isHovering { return role == .destructive ? 0.15 : 0.125 }
        return role == .destructive ? 0.11 : 0.095
    }

    private func strokeOpacity(isPressed: Bool) -> Double {
        if designMode == .liquidGlass {
            if isPressed { return 0.20 }
            if isHovering { return 0.14 }
            return 0.09
        }
        if isPressed { return 0.18 }
        if isHovering { return 0.12 }
        return 0.07
    }

    private func glassTintOpacity(isPressed: Bool) -> Double {
        if isPressed { return role == .destructive ? 0.15 : 0.13 }
        if isHovering { return role == .destructive ? 0.11 : 0.095 }
        return role == .destructive ? 0.075 : 0.058
    }

    private func glassFallbackOpacity(isPressed: Bool) -> Double {
        if isPressed { return role == .destructive ? 0.14 : 0.12 }
        if isHovering { return role == .destructive ? 0.105 : 0.088 }
        return role == .destructive ? 0.065 : 0.052
    }
}
