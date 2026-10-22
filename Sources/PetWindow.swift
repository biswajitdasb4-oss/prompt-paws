import AppKit

/// A borderless, see-through panel that floats above every app, on every Space (also over
/// full-screen apps), and never takes keyboard focus from the app you are using.
final class PetPanel: NSPanel {
    init(size: CGFloat) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lies over the web view and turns mouse input into pet events. Positions are in screen
/// coordinates, so they stay right while the window moves under the pointer.
final class GrabView: NSView {
    var onDown: ((NSPoint) -> Void)?
    var onDrag: ((NSPoint) -> Void)?
    var onUp: ((NSPoint) -> Void)?
    var onMenu: ((NSEvent) -> Void)?
    private var controlClick = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        controlClick = event.modifierFlags.contains(.control)
        if controlClick { onMenu?(event) } else { onDown?(NSEvent.mouseLocation) }
    }

    override func mouseDragged(with event: NSEvent) {
        if !controlClick { onDrag?(NSEvent.mouseLocation) }
    }

    override func mouseUp(with event: NSEvent) {
        if !controlClick { onUp?(NSEvent.mouseLocation) }
        controlClick = false
    }

    override func rightMouseDown(with event: NSEvent) { onMenu?(event) }
}
