import AppKit

/// Keeps each adopted IDE frame on its session's slot. The slot owns the frame: a size, place, zoom, full
/// screen or minimize the IDE asks for is snapped back. A new frame stays invisible until no IDE change has
/// arrived for `quiet`, so a project opening never shows its restored bounds.
@MainActor
final class RebasedFrameKeeper: RebasedFrames {
    static let quiet: TimeInterval = 0.15

    private struct Kept {
        weak var frame: NSWindow?
        weak var host: NSWindow?
        var observers: [NSObjectProtocol] = []
        var revealed = false
        var generation = 0
    }

    var slotRect: (NSWindow) -> NSRect = { $0.convertToScreen($0.contentLayoutRect) }
    var after: (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, work in
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            work()
        }
    }

    private var kept: [ObjectIdentifier: Kept] = [:]
    private var hostObservers: [ObjectIdentifier: [NSObjectProtocol]] = [:]
    private var fitting = false

    func adopt(_ frame: NSWindow, in host: NSWindow?) {
        let id = ObjectIdentifier(frame)
        if kept[id] == nil {
            frame.alphaValue = 0
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                frame.standardWindowButton(button)?.isHidden = true
            }
            frame.titleVisibility = .hidden
            frame.titlebarAppearsTransparent = true
            frame.collectionBehavior.remove(.fullScreenPrimary)
            frame.collectionBehavior.insert(.fullScreenNone)
            kept[id] = Kept(frame: frame, observers: observe(frame))
        }
        kept[id]?.host = host
        if let host { observeHost(host) }
        attach(frame, to: host)
        if !frame.isVisible { frame.orderFront(nil) }
        fit(frame)
        if kept[id]?.revealed == false { armReveal(frame) }
    }

    func attach(_ window: NSWindow, to host: NSWindow?) {
        guard let host, window.parent !== host else { return }
        window.parent?.removeChildWindow(window)
        host.addChildWindow(window, ordered: .above)
    }

    /// Ends the keeper's hold on `window` until it is adopted again: no refit, minimize undo or reveal acts on
    /// it after this.
    func detach(_ window: NSWindow) {
        release(window)
        window.parent?.removeChildWindow(window)
    }

    private func release(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        kept[id]?.host = nil
        kept[id]?.generation += 1
    }

    private func dispose(_ window: NSWindow) {
        kept.removeValue(forKey: ObjectIdentifier(window))?.observers.forEach(NotificationCenter.default.removeObserver)
    }

    var keptCount: Int { kept.count }

    func orderOut(_ window: NSWindow) {
        window.orderOut(nil)
    }

    /// Moves an adopted frame to another window, for a session moved between windows.
    func reparent(_ frame: NSWindow, to host: NSWindow) {
        adopt(frame, in: host)
    }

    /// Fits every frame kept on `host` to its slot again, after the slot moved or changed size.
    func refit(host: NSWindow) {
        for entry in kept.values where entry.host === host {
            if let frame = entry.frame { fit(frame) }
        }
    }

    func isRevealed(_ frame: NSWindow) -> Bool { kept[ObjectIdentifier(frame)]?.revealed ?? false }

    private func fit(_ frame: NSWindow) {
        guard let host = kept[ObjectIdentifier(frame)]?.host else { return }
        let target = slotRect(host)
        guard frame.frame != target else { return }
        fitting = true
        frame.setFrame(target, display: true)
        fitting = false
    }

    private func observe(_ frame: NSWindow) -> [NSObjectProtocol] {
        let center = NotificationCenter.default
        let moved: @Sendable (Notification) -> Void = { [weak self, weak frame] _ in
            MainActor.assumeIsolated {
                guard let self, let frame else { return }
                self.ideMoved(frame)
            }
        }
        return [
            center.addObserver(forName: NSWindow.didResizeNotification, object: frame, queue: nil, using: moved),
            center.addObserver(forName: NSWindow.didMoveNotification, object: frame, queue: nil, using: moved),
            center.addObserver(forName: NSWindow.didMiniaturizeNotification, object: frame, queue: nil) { [weak self, weak frame] _ in
                MainActor.assumeIsolated {
                    guard let self, let frame, let host = self.kept[ObjectIdentifier(frame)]?.host else { return }
                    frame.deminiaturize(nil)
                    self.attach(frame, to: host)
                    self.fit(frame)
                }
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: frame, queue: nil) { [weak self, weak frame] _ in
                MainActor.assumeIsolated {
                    guard let self, let frame else { return }
                    self.dispose(frame)
                }
            },
        ]
    }

    // A closing host would take its child frames with it; the IDE frame outlives any one window.
    private func observeHost(_ host: NSWindow) {
        let id = ObjectIdentifier(host)
        guard hostObservers[id] == nil else { return }
        let center = NotificationCenter.default
        hostObservers[id] = [
            center.addObserver(forName: NSWindow.didResizeNotification, object: host, queue: nil) { [weak self, weak host] _ in
                MainActor.assumeIsolated {
                    guard let self, let host else { return }
                    self.refit(host: host)
                }
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: host, queue: nil) { [weak self, weak host] _ in
                MainActor.assumeIsolated {
                    guard let self, let host else { return }
                    for child in host.childWindows ?? [] where self.kept[ObjectIdentifier(child)] != nil {
                        self.detach(child)
                        child.orderOut(nil)
                    }
                    self.hostObservers.removeValue(forKey: ObjectIdentifier(host))?.forEach(center.removeObserver)
                }
            },
        ]
    }

    private func ideMoved(_ frame: NSWindow) {
        guard !fitting, let entry = kept[ObjectIdentifier(frame)], entry.host != nil else { return }
        fit(frame)
        if !entry.revealed { armReveal(frame) }
    }

    private func armReveal(_ frame: NSWindow) {
        let id = ObjectIdentifier(frame)
        kept[id]?.generation += 1
        let generation = kept[id]?.generation
        after(Self.quiet) { [weak self, weak frame] in
            guard let self, let frame, self.kept[id]?.generation == generation, self.kept[id]?.host != nil else { return }
            self.kept[id]?.revealed = true
            frame.alphaValue = 1
        }
    }
}
