/// An open window's on-screen frame — the read side of write-only `window.move`/`window.resize`, in the
/// SAME coordinate system those accept so a read-then-restore round-trips: `x`/`y` the top-left relative to
/// `display`'s top-left (y down), `width`/`height` the frame size in points, `display` a screen-list index.
public struct ControlWindowFrame: Codable, Sendable, Equatable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    public let display: Int

    public init(x: Int, y: Int, width: Int, height: Int, display: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.display = display
    }
}

/// A window as projected into the `window.list` response. `open` is whether its on-screen window is
/// up; `active` is whether it is the frontmost window.
public struct ControlWindowNode: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let open: Bool
    public let active: Bool
    /// The window's auto-follow-blocked timeout in milliseconds; nil/omitted when disabled. As of the last
    /// cache refresh — `window.list` answers from a nonisolated fast path, so a just-changed setting lags
    /// until the next command; the live `idleMs` is kept off `window.list` (tree-only) for that reason.
    public let autoFollowMs: Int?
    /// How long a session must stay selected before it joins this window's recency order, in milliseconds;
    /// nil/omitted when the dwell is Immediately or the window is closed. Rides the same cache as
    /// `autoFollowMs`, so a just-changed setting lags by one command.
    public let recencyDwellMs: Int?
    /// Whether this window's sidebar is visible; nil/omitted for a CLOSED window with no live store. Read
    /// from the open window's store, mirroring `autoFollowMs`. The read side of `sidebar`, per window.
    public let sidebarVisible: Bool?
    /// The window's on-screen frame (position + size + display); nil/omitted for a CLOSED window with no live
    /// NSWindow. The read side of `window.move`/`window.resize`. Read live app-side on the window cache,
    /// refreshed on move/resize/zoom/fullscreen (`ControlServer` observes the NSWindow notifications), so a
    /// hand-drag or GUI toggle shows up without another command.
    public let geometry: ControlWindowFrame?
    /// Whether the window is in native macOS full screen; nil/omitted for a CLOSED window. The read side of
    /// the write-only `window.fullscreen` toggle, so it can be made idempotent. Read live app-side; like
    /// `geometry` it rides the cache.
    public let fullscreen: Bool?
    /// Whether the window is zoomed (maximized-to-screen, NOT full screen), or nil for a CLOSED window
    /// (omitted from the JSON). The read side of the write-only `window.zoom` toggle. Read live app-side.
    public let zoomed: Bool?
    /// Whether the window is minimized to the Dock; nil/omitted for a CLOSED window. The read side of
    /// `window.minimize`. Live app-side on the cache, refreshed on the NSWindow miniaturize/deminiaturize
    /// notifications so ⌘M or a Dock click shows too. A minimized window still reports its `geometry` (where
    /// it comes back to).
    public let minimized: Bool?
    /// `true` on the ONE window holding normal mode, omitted everywhere else — the read side of `mode`.
    ///
    /// Reported true-only rather than per-window false/true because the mode is a single app-wide state that
    /// leaves on window resign-key: at most one window can hold it, and an untouched install then reports
    /// exactly what it reported before this command existed.
    public let normalMode: Bool?

    public init(id: String, name: String, open: Bool, active: Bool, autoFollowMs: Int? = nil,
                recencyDwellMs: Int? = nil,
                sidebarVisible: Bool? = nil, geometry: ControlWindowFrame? = nil,
                fullscreen: Bool? = nil, zoomed: Bool? = nil, minimized: Bool? = nil,
                normalMode: Bool? = nil) {
        self.id = id
        self.name = name
        self.open = open
        self.active = active
        self.autoFollowMs = autoFollowMs
        self.recencyDwellMs = recencyDwellMs
        self.sidebarVisible = sidebarVisible
        self.geometry = geometry
        self.fullscreen = fullscreen
        self.zoomed = zoomed
        self.minimized = minimized
        self.normalMode = normalMode
    }
}
