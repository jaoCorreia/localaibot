import SwiftUI
import AppKit

/// Height of the unified title bar. Every column's top bar uses it so the
/// traffic lights and the app's own controls share one centered row.
let titleBarHeight: CGFloat = 52

/// Native-looking chrome without a system toolbar: the title bar stays the
/// standard thin (transparent) strip so clicks reach our own controls, and
/// the traffic lights are moved down to sit centered in our 52 pt top row.
struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ChromeView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ChromeView: NSView {
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            window.styleMask.insert(.fullSizeContentView)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            // AppKit re-lays the buttons out on resize and full-screen changes.
            for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                         NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.placeTrafficLights()
                })
            }
            DispatchQueue.main.async { self.placeTrafficLights() }
        }

        override func layout() {
            super.layout()
            placeTrafficLights()
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }

        private func placeTrafficLights() {
            guard let window, !window.styleMask.contains(.fullScreen) else { return }
            // Grow the (transparent) title bar container to our row height so the
            // moved buttons aren't clipped, keeping it pinned to the top edge.
            if let container = window.standardWindowButton(.closeButton)?.superview?.superview,
               container.frame.height != titleBarHeight {
                var frame = container.frame
                frame.size.height = titleBarHeight
                frame.origin.y = window.frame.height - titleBarHeight
                container.frame = frame
            }
            let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            for (i, type) in buttons.enumerated() {
                guard let button = window.standardWindowButton(type), let bar = button.superview else { continue }
                let y = (bar.bounds.height - button.frame.height) / 2
                button.setFrameOrigin(NSPoint(x: 20 + CGFloat(i) * 20, y: y))
            }
        }
    }
}

extension View {
    /// Empty parts of a top bar move the window, like a real title bar.
    /// The drag lives in the background so buttons in the bar keep their clicks.
    func dragsWindow() -> some View {
        background {
            if #available(macOS 15.0, *) {
                Color.clear.contentShape(Rectangle()).gesture(WindowDragGesture())
            }
        }
    }
}

extension View {
    /// Keeps scrolling content out of the title-bar row and fades it out at
    /// the top edge instead of letting it slide under the controls.
    func fadesUnderTopBar(_ color: Color, height: CGFloat = 18) -> some View {
        self
            .clipped()
            .overlay(alignment: .top) {
                LinearGradient(colors: [color, color.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: height)
                    .allowsHitTesting(false)
            }
    }
}

/// Forces slim overlay scrollers (the ones that fade out) on the enclosing
/// NSScrollView, even when System Settings asks for always-visible bars.
struct ThinScrollers: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            // macOS resets the style when the system preference changes.
            observer = NotificationCenter.default.addObserver(
                forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.apply() }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        private func apply() {
            guard let scrollView = enclosingScrollView else { return }
            scrollView.scrollerStyle = .overlay
            scrollView.verticalScroller?.controlSize = .small
            scrollView.horizontalScroller?.controlSize = .small
        }
    }
}

extension View {
    func thinScrollers() -> some View { background(ThinScrollers()) }
}

/// Round toolbar button (Grok-style): a soft circle that brightens on hover.
struct ToolbarButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(hovering ? Theme.text : Theme.secondary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(hovering ? Theme.hover : Theme.raised.opacity(0.7)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}
