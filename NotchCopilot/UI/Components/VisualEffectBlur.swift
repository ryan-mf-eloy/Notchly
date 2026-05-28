import AppKit
import SwiftUI

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

struct ProtectedContentAccessibilityMarker: NSViewRepresentable {
    var isProtected: Bool

    func makeNSView(context: Context) -> ProtectedContentMarkerView {
        let view = ProtectedContentMarkerView()
        view.isProtected = isProtected
        return view
    }

    func updateNSView(_ nsView: ProtectedContentMarkerView, context: Context) {
        nsView.isProtected = isProtected
    }
}

final class ProtectedContentMarkerView: NSView {
    var isProtected = true {
        didSet {
            updateAccessibilityConfiguration()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
        updateAccessibilityConfiguration()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = false
        updateAccessibilityConfiguration()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func isAccessibilityProtectedContent() -> Bool {
        isProtected
    }

    private func updateAccessibilityConfiguration() {
        setAccessibilityElement(isProtected)
        setAccessibilityLabel("Protected content")
        setAccessibilityRole(.group)
    }
}

extension View {
    func protectedContentRegion(_ isProtected: Bool = true) -> some View {
        background {
            ProtectedContentAccessibilityMarker(isProtected: isProtected)
                .allowsHitTesting(false)
        }
    }
}
