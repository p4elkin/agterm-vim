import AppKit
import SwiftUI
import agtermCore

/// Reports a held IDE's geometry and visibility; the child window stays owned by the host.
struct RebasedSlot: View {
    let session: Session
    let pane: OverlayPane?
    let visible: Bool
    let foreground: Color

    static func isVisible(_ visible: Bool, session: Session, pane: OverlayPane? = nil,
                          overlaid: Bool = false, covered: Bool = false) -> Bool {
        guard visible, !overlaid, !covered, session.rebasedPlacement?.overlay.hidden != true else { return false }
        if session.askPending != nil, pane == nil || session.askPaneIdentity == nil || session.askTargetPane == pane { return false }
        return true
    }

    static func message(for overlay: RebasedOverlay, shownElsewhere: Bool, visible: Bool = true) -> String? {
        guard visible, !overlay.hidden else { return nil }
        switch overlay.state {
        case .fetching: return "Fetching \(overlay.source ?? "the repository")…"
        case .starting: return "Starting Rebased…"
        case .failed(let error): return error
        case .shown: return shownElsewhere ? "Rebased is shown in another session" : nil
        }
    }

    private var overlay: RebasedOverlay? {
        if let pane { return session.paneOverlay(pane)?.rebased }
        return session.rebasedOverlay
    }

    var body: some View {
        let localVisible = Self.isVisible(visible, session: session, pane: pane)
        ZStack {
            if let overlay {
                RebasedSlotView(overlay: overlay.id, visible: localVisible)
                    .id(overlay.id)
                if let message = Self.message(for: overlay, shownElsewhere: RebasedHost.shared.isShownElsewhere(overlay: overlay.id),
                                              visible: localVisible) {
                    Text(message)
                        .foregroundStyle(foreground.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
        }
    }
}

private struct RebasedSlotView: NSViewRepresentable {
    let overlay: UUID
    let visible: Bool

    func makeNSView(context: Context) -> RebasedSlotNSView { RebasedSlotNSView(overlay: overlay) }

    func updateNSView(_ view: RebasedSlotNSView, context: Context) { view.wanted = visible }

    static func dismantleNSView(_ view: RebasedSlotNSView, coordinator: ()) { view.wanted = false }
}

private final class RebasedSlotNSView: NSView {
    let overlay: UUID
    let reporter = UUID()
    var wanted = false { didSet { if wanted != oldValue { sync() } } }
    private var observers: [NSObjectProtocol] = []
    private var shown: Bool?

    init(overlay: UUID) {
        self.overlay = overlay
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let window {
            let names: [Notification.Name] = [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                                              NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification]
            observers = names.map {
                NotificationCenter.default.addObserver(forName: $0, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.sync() }
                }
            }
        }
        sync()
    }

    override func layout() {
        super.layout()
        sync()
    }

    private func sync() {
        let onScreen = wanted && window.map { !$0.isMiniaturized && $0.isVisible } == true
        if onScreen, let window {
            RebasedHost.shared.setSlot(window.convertToScreen(convert(bounds, to: nil)), overlay: overlay, in: window)
        }
        guard onScreen != shown else { return }
        shown = onScreen
        RebasedHost.shared.setSlotVisible(onScreen, overlay: overlay, reporter: reporter)
    }
}
