import Foundation

extension Session {
    /// htmlOverlayActive means a page covers the session: it owns input like a program but has no terminal
    /// surface, zoom target or exit status, so it never counts as `programOverlayActive`.
    public var htmlOverlayActive: Bool { overlayActive && htmlOverlay != nil }
    public var rebasedOverlayActive: Bool { overlayActive && rebasedOverlay != nil && rebasedOverlay?.hidden != true }

    /// coverOverlayActive is the input-exclusion question; terminal-surface questions ask
    /// `programOverlayActive` instead.
    public var coverOverlayActive: Bool { programOverlayActive || htmlOverlayActive || rebasedOverlayActive }

    public var rebasedPlacement: (overlay: RebasedOverlay, pane: OverlayPane?)? {
        if let overlay = rebasedOverlay { return (overlay, nil) }
        for pane in OverlayPane.allCases {
            if let overlay = paneOverlay(pane)?.rebased { return (overlay, pane) }
        }
        return nil
    }

    @discardableResult
    public func updateRebasedOverlay(_ id: UUID, _ change: (inout RebasedOverlay) -> Void) -> Bool {
        if var overlay = rebasedOverlay, overlay.id == id {
            change(&overlay)
            rebasedOverlay = overlay
            return true
        }
        for pane in OverlayPane.allCases {
            guard var slot = paneOverlay(pane), var overlay = slot.rebased, overlay.id == id else { continue }
            change(&overlay)
            slot.rebased = overlay
            setPaneOverlay(slot, pane: pane)
            return true
        }
        return false
    }

    public func paneOverlayCovers(_ pane: OverlayPane) -> Bool {
        guard let overlay = paneOverlay(pane) else { return false }
        return overlay.rebased?.hidden != true
    }

    public func paneOverlayIsProgram(_ pane: OverlayPane) -> Bool {
        guard let overlay = paneOverlay(pane) else { return false }
        return overlay.html == nil && overlay.rebased == nil
    }

    public func paneOverlayIsHtml(_ pane: OverlayPane) -> Bool { paneOverlay(pane)?.html != nil }

    /// htmlCovers checks the slot a `--pane` command addresses, the session-wide one for nil.
    public func htmlCovers(_ pane: OverlayPane?) -> Bool {
        guard let pane else { return htmlOverlayActive }
        return paneOverlayIsHtml(pane)
    }

    /// htmlHidesTerminal says whether a page covers the terminal a `--pane` font command addresses: the
    /// session-wide page covers both split panes and a shown scratch, a pane page only its own pane.
    public func htmlHidesTerminal(_ pane: StatusPane?) -> Bool {
        if rebasedOverlayActive { return false }
        switch pane {
        case .scratch: return htmlOverlayActive && scratchActive
        case nil, .left: return htmlOverlayActive || paneOverlayIsHtml(.left)
        case .right: return htmlOverlayActive || paneOverlayIsHtml(.right)
        }
    }

    /// topmostHtmlOverlay is the page that takes the keyboard when focus returns to this session, in the
    /// order `topmostSurface` resolves covers; nil when a terminal is on top.
    public var topmostHtmlOverlay: HtmlOverlay? {
        if htmlOverlayActive { return htmlOverlay }
        if programOverlayActive || rebasedOverlayActive || scratchActive { return nil }
        return focusedOverlayPane.flatMap { paneOverlay($0)?.html }
    }

    /// teardownOverlaySlot discards the session-wide occupant where the whole session goes away; a page has
    /// no surface, so tearing down `overlaySurface` alone would leave it running.
    public func teardownOverlaySlot() {
        overlaySurface?.teardown()
        HtmlOverlayReleases.shared.release(htmlOverlay)
        htmlOverlay = nil
        RebasedOverlayReleases.shared.release(rebasedOverlay)
        rebasedOverlay = nil
    }

    // false when no slot of this session holds page `id`
    func updateHtmlOverlay(_ id: UUID, _ change: (inout HtmlOverlay) -> Void) -> Bool {
        if var page = htmlOverlay, page.id == id {
            change(&page)
            htmlOverlay = page
            return true
        }
        for pane in OverlayPane.allCases {
            guard var overlay = paneOverlay(pane), var page = overlay.html, page.id == id else { continue }
            change(&page)
            overlay.html = page
            setPaneOverlay(overlay, pane: pane)
            return true
        }
        return false
    }
}
