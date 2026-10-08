import AppKit
import SwiftUI
import agtermCore

/// The overlay slot a Rebased frame sits over. The frame is a child window of agterm's, not a view, so the
/// slot only reports where it is and whether it is on screen; it never owns or dismantles the IDE window.
struct RebasedSlot: View {
    let session: Session
    let visible: Bool
    let foreground: Color

    var body: some View {
        ZStack {
            RebasedSlotView(session: session.id, visible: visible)
            if let message {
                Text(message)
                    .foregroundStyle(foreground.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding()
            }
        }
    }

    private var message: String? {
        switch session.rebasedOverlay?.state {
        case .starting?: "Starting Rebased…"
        case .failed(let error)?: error
        case .shown? where !RebasedHost.shared.isShown(in: session.id): "Rebased is shown in another session"
        default: nil
        }
    }
}

private struct RebasedSlotView: NSViewRepresentable {
    let session: UUID
    let visible: Bool

    func makeNSView(context: Context) -> RebasedSlotNSView { RebasedSlotNSView(session: session) }

    func updateNSView(_ view: RebasedSlotNSView, context: Context) { view.wanted = visible }

    static func dismantleNSView(_ view: RebasedSlotNSView, coordinator: ()) { view.wanted = false }
}

private final class RebasedSlotNSView: NSView {
    let session: UUID
    var wanted = false { didSet { if wanted != oldValue { sync() } } }
    private var observers: [NSObjectProtocol] = []
    // nil until the first report, which is always sent: the host treats an unreported slot as hidden
    private var shown: Bool?

    init(session: UUID) {
        self.session = session
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
            RebasedHost.shared.setSlot(window.convertToScreen(convert(bounds, to: nil)), in: window)
        }
        guard onScreen != shown else { return }
        shown = onScreen
        RebasedHost.shared.setSlotVisible(onScreen, session: session)
    }
}
