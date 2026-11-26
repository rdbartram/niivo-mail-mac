import AppKit
import SwiftUI

// Region-level capture protection (Ryan 2026-11-19: "should only block that part of the UI, not the whole app").
// macOS can only omit whole windows from screenshots / screen sharing (NSWindow.sharingType). So a protected region
// is hosted in its own borderless child window with sharingType = .none, pinned exactly over a placeholder in the
// main window. Captures show the app with only that rectangle blank; everything else stays capturable.
// The child moves with its parent (child-window ordering), follows the placeholder's frame on layout/resize, and
// hides while the parent shows a sheet (otherwise it would float above it).
// Caveat (same as WindowSharingGuard): ScreenCaptureKit on recent macOS may not honour sharingType; best effort.

extension View {
    /// Host this view in a capture-excluded child window while `active`; inline otherwise.
    func captureShield<E: View>(_ active: Bool, environment: @escaping (AnyView) -> E) -> some View {
        modifier(CaptureShieldModifier(active: active, wrap: { AnyView(environment($0)) }))
    }
}

private struct CaptureShieldModifier: ViewModifier {
    var active: Bool
    var wrap: (AnyView) -> AnyView
    func body(content: Content) -> some View {
        if active {
            // Placeholder keeps the layout; the real content lives in the shield window above it.
            Color.clear
                .overlay(ShieldHost(content: wrap(AnyView(content))))
        } else {
            content
        }
    }
}

private struct ShieldHost: NSViewRepresentable {
    var content: AnyView
    func makeNSView(context: Context) -> ShieldAnchorView { ShieldAnchorView() }
    func updateNSView(_ v: ShieldAnchorView, context: Context) { v.setContent(content) }
    static func dismantleNSView(_ v: ShieldAnchorView, coordinator: ()) { v.tearDown() }
}

/// A key-capable borderless window (borderless windows can't become key by default; the reader needs keyboard).
private final class ShieldWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class ShieldAnchorView: NSView {
    private var shield: ShieldWindow?
    private var host: NSHostingView<AnyView>?
    private var observers: [NSObjectProtocol] = []

    func setContent(_ v: AnyView) {
        if let host { host.rootView = v } else {
            let h = NSHostingView(rootView: v)
            host = h
            let w = ShieldWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
            w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false
            w.sharingType = .none
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
            w.contentView = h
            shield = w
        }
        attach()
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach() }
    override func layout() { super.layout(); place() }
    override func setFrameSize(_ s: NSSize) { super.setFrameSize(s); place() }

    private func attach() {
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        guard let parent = window, let shield else { return }
        if shield.parent !== parent { shield.parent?.removeChildWindow(shield); parent.addChildWindow(shield, ordered: .above) }
        let nc = NotificationCenter.default
        for n in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification, NSWindow.didEnterFullScreenNotification,
                  NSWindow.didExitFullScreenNotification] {
            observers.append(nc.addObserver(forName: n, object: parent, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.place() }
            })
        }
        observers.append(nc.addObserver(forName: NSWindow.willBeginSheetNotification, object: parent, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shield?.orderOut(nil) }
        })
        observers.append(nc.addObserver(forName: NSWindow.didEndSheetNotification, object: parent, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.attach() }
        })
        observers.append(nc.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tearDown() }
        })
        place()
        if parent.isVisible && parent.attachedSheet == nil { shield.orderFront(nil) }
    }

    private func place() {
        guard let parent = window, let shield, superview != nil else { return }
        let inWindow = convert(bounds, to: nil)
        let onScreen = parent.convertToScreen(inWindow)
        if shield.frame != onScreen { shield.setFrame(onScreen, display: true) }
    }

    func tearDown() {
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        if let shield { shield.parent?.removeChildWindow(shield); shield.orderOut(nil); shield.contentView = nil }
        shield = nil; host = nil
    }
}
