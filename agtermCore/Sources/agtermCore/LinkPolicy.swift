import Foundation

/// Decides what agterm does when a terminal hyperlink is clicked (`GHOSTTY_ACTION_OPEN_URL`). A terminal
/// renders UNTRUSTED program output, so an escape-sequence link can carry any scheme. `disposition(for:)`
/// maps a raw link to OPEN a web/mail URL (`NSWorkspace.open`, or `agterm-open-link` for a pane's web
/// link when installed), REVEAL a LOCAL `file://` link in Finder
/// (`NSWorkspace.activateFileViewerSelecting`), show a parked cross-agent message for agterm's OWN
/// `agterm-xchat://msg/<id>` scheme, hand a schemeless file path (ghostty's built-in path link) to the
/// `agterm-open-path` viewer script (as is a bare file name minted as `agterm-path:<name>`), hand a forge ref
/// minted as `agterm-ref:<ref>` to `agterm-open-link`, or
/// IGNORE anything else. `file://` is revealed, never
/// opened: opening goes through LaunchServices (the Finder double-click path), so a click on
/// `file:///…/X.app` or `.command` would LAUNCH it, while reveal only selects it. A `file://` whose host is
/// NOT this machine is ignored, since `activateFileViewerSelecting` on a remote host can trigger a Finder
/// network/SMB mount. Host-free (Foundation-only) so it is unit-tested — the local host names are injected;
/// the app-side glue only calls the two `NSWorkspace` methods (same split as `ShellEscape`).
public enum LinkPolicy {
    /// The schemes safe to hand to the system opener — web + mail only, none that hands off to a local
    /// executable/handler.
    public static let permittedSchemes: Set<String> = ["http", "https", "mailto", "ftp"]

    /// The one non-web scheme agterm answers itself: `agterm-xchat://msg/<id>` shows a parked cross-agent
    /// message. Deliberately NOT in `permittedSchemes` — nothing on this route reaches `NSWorkspace` or
    /// LaunchServices, and the id is re-validated below, so terminal output cannot use it to name a path, an
    /// argument or a program. Only agterm's own `link` rule in `ghostty.conf` mints links of this shape.
    public static let xchatScheme = "agterm-xchat"

    /// A whole message id, anchored at both ends: `msg-`, six digits, four hex digits. The shape is fixed by
    /// `xchat-send.py`, which mints it. Nothing else is ever accepted, so `../../.ssh/id_rsa` is a malformed
    /// id rather than a path that gets resolved.
    static let xchatIDPattern = "^msg-[0-9]{6}-[0-9a-f]{4}$"

    /// `agterm-ref:<ref>` carries a forge reference (`!12`, `#34`, a commit hash, `group/proj!12`) minted by the
    /// `link` rules agterm-agents ships, for `agterm-open-link` to resolve against the pane's repository. Not in
    /// `permittedSchemes`, and never parsed through `URL(string:)`: that would move the `34` of `group/proj#34`
    /// into a fragment.
    public static let refScheme = "agterm-ref"

    /// A bare file name (`links.conf`), which ghostty's path link never matches without a `/`. Minted by the
    /// agterm-agents `link` rule beside the ref rules, and read like `refScheme`: on the raw string.
    public static let pathScheme = "agterm-path"

    /// Each accepted ref shape, anchored. A project segment cannot start with `.`, so `..` is never a segment.
    static let refPatterns = [
        #"^[!#][0-9]{1,9}$"#,
        #"^[0-9a-f]{7,40}$"#,
        crossProjectRefPattern,
    ]
    static let crossProjectRefPattern =
        #"^[A-Za-z0-9_][A-Za-z0-9_.-]*(?:/[A-Za-z0-9_][A-Za-z0-9_.-]*)+(?:[!#][0-9]{1,9}|@[0-9a-f]{7,40})$"#

    /// What a link click should do. Carries the target URL for `.open`/`.reveal`.
    public enum LinkDisposition: Equatable {
        case open(URL)
        case reveal(URL)
        case xchat(id: String)
        case openPath(path: String, line: Int?)
        case ref(String)
        case ignore
    }

    /// Lowercased host names counting as "this machine" for a `file://` link: `localhost` and the
    /// `gethostname()` name (what GNU `ls --hyperlink` emits, e.g. `file://<host>/…`; `eza` uses an empty
    /// host, covered by the empty-host rule). Deliberately NOT `Host.current()`/`ProcessInfo.hostName`:
    /// those resolve via mDNS/Bonjour, tripping the macOS "find devices on local networks" prompt on first
    /// click, while `gethostname()` is a pure syscall. Computed ONCE, the default for `disposition`.
    public static let localHostNames: Set<String> = {
        var raw: Set<String> = ["localhost"]
        var buffer = [CChar](repeating: 0, count: 256)   // gethostname() — the name GNU ls uses, no network
        if gethostname(&buffer, buffer.count) == 0 {
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }   // trim at NUL, then decode
            raw.insert(String(decoding: bytes, as: UTF8.self))
        }
        return expandedHostNames(from: raw)
    }()

    /// Normalize each raw host name and add the `.local`-stripped short form beside the full one. Pure (no
    /// syscalls), so the normalization + `.local` expansion feeding `localHostNames` stays unit-testable.
    static func expandedHostNames(from raw: Set<String>) -> Set<String> {
        var out: Set<String> = []
        for name in raw {
            let norm = normalizedHost(name)
            guard !norm.isEmpty else { continue }
            out.insert(norm)
            if norm.hasSuffix(".local") {
                let short = String(norm.dropLast(6))                               // add the short form too,
                if !short.isEmpty { out.insert(short) }                            // but a bare ".local" → "" is skipped
            }
        }
        return out
    }

    /// Lowercase a host and drop a trailing FQDN dot so matching is stable.
    static func normalizedHost(_ host: String) -> String {
        let lower = host.lowercased()
        return lower.hasSuffix(".") ? String(lower.dropLast()) : lower
    }

    /// The macOS auto-mount roots where a Finder reveal can trigger an NFS/SMB automount: `/net` (`-hosts`),
    /// `/Network` (`/Network/Servers`), `/home` (`auto_home`), PLUS their canonical `/System/Volumes/Data/…`
    /// paths — `/home` is a firmlink/symlink and `auto_home` really lives at `/System/Volumes/Data/home`, so
    /// a LITERAL `/System/Volumes/Data/home/<user>` link would slip past the `/home` entry and still mount.
    /// Matched EXACT or as a `<root>/…` child, case-insensitively (the boot volume is case-insensitive, so
    /// `/NET/…` mounts too), so `/networkx` is NOT caught; the Data root `/System/Volumes/Data` is
    /// deliberately unlisted, backing every real file. The path must already be dot-normalized.
    static func isAutomountPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        return ["/net", "/network", "/home",
                "/system/volumes/data/home",
                "/system/volumes/data/net",
                "/system/volumes/data/network/servers"].contains { lower == $0 || lower.hasPrefix($0 + "/") }
    }

    /// Collapse `.`/`..` in an ABSOLUTE path with a purely LEXICAL, string-only normalizer — no filesystem
    /// access (unlike `URL.standardizedFileURL`, which stats the target) and no symlink resolution, so the
    /// classifier never touches the automount path it may be about to deny (a `stat` inside autofs could
    /// itself trigger the mount). A leading `..` at the root is dropped; the caller guarantees an absolute
    /// input (`hasPrefix("/")`).
    static func lexicallyNormalizedAbsolutePath(_ path: String) -> String {
        var out: [Substring] = []
        for comp in path.split(separator: "/", omittingEmptySubsequences: true) {
            if comp == "." { continue }
            if comp == ".." { if !out.isEmpty { out.removeLast() }; continue }
            out.append(comp)
        }
        return "/" + out.joined(separator: "/")
    }

    /// Maps a raw terminal link to an action: a permitted web/mail scheme → `.open`; a LOCAL `file://` link
    /// (empty host, or a host in `localHosts`) → `.reveal` of the HOST-STRIPPED, dot-normalized local path,
    /// so Finder only ever sees a plain `/…` path and never leans on the original authority for host
    /// handling; a `file://` with a non-local host, an empty/relative path, a UNC-style `//`-path, an
    /// auto-mount path (`/net`, `/Network`, `/home`, checked AFTER `..` normalization so `/tmp/../net/x`
    /// can't sneak through), or any other scheme / schemeless / unparseable input → `.ignore`. `localHosts`
    /// is injected (default: this machine's names) so the decision stays host-free and unit-testable.
    public static func disposition(for raw: String, localHosts: Set<String> = localHostNames) -> LinkDisposition {
        if raw.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) == nil {
            return reclaimedRefDisposition(raw, path: openPathDisposition(raw))
        }
        if raw.hasPrefix(refScheme + ":") { return refDisposition(String(raw.dropFirst(refScheme.count + 1))) }
        if raw.hasPrefix(pathScheme + ":") { return bareNameDisposition(String(raw.dropFirst(pathScheme.count + 1))) }
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased() else { return .ignore }
        if permittedSchemes.contains(scheme) { return .open(url) }
        if scheme == xchatScheme { return xchatDisposition(url) }
        guard scheme == "file" else { return .ignore }
        let host = normalizedHost(url.host(percentEncoded: false) ?? "")
        guard host.isEmpty || localHosts.contains(host) else { return .ignore }
        // reject an empty/relative path (empty would make `URL(fileURLWithPath:)` the process CWD) and a
        // UNC-style `//` path (a remote target hidden where the host check can't see it).
        let rawPath = url.path(percentEncoded: false)
        guard rawPath.hasPrefix("/"), !rawPath.hasPrefix("//") else { return .ignore }
        // reveal a host-stripped local path, collapsing `.`/`..` LEXICALLY so `/tmp/../net/x` can't sneak
        // past the automount check and the classifier never stats — never risks triggering — the automount
        // path it is about to deny. It also never resolves symlinks: `/tmp/link -> /net` reveals the link,
        // not the target. Do NOT swap in `standardizedFileURL`/`resolvingSymlinksInPath()`, which touch the
        // filesystem.
        let normalizedPath = Self.lexicallyNormalizedAbsolutePath(rawPath)
        guard !isAutomountPath(normalizedPath) else { return .ignore }
        return .reveal(URL(fileURLWithPath: normalizedPath, isDirectory: false))
    }

    /// `agterm-xchat://msg/<id>` → `.xchat(id)`; anything else under the scheme → `.ignore`. The host must be
    /// exactly `msg` (the only route the scheme has), the path must be one component, and that component must
    /// be a whole message id. A query or a fragment is REFUSED rather than dropped: this shape is minted by
    /// agterm's own `link` rule, so anything extra means the input is not what it claims to be. The newline
    /// guard closes the one hole the anchored pattern leaves — a percent-encoded `%0A` decodes into the path,
    /// and a regex `$` can match just before a trailing newline.
    static func xchatDisposition(_ url: URL) -> LinkDisposition {
        guard normalizedHost(url.host(percentEncoded: false) ?? "") == "msg" else { return .ignore }
        guard url.query == nil, url.fragment == nil else { return .ignore }
        let path = url.path(percentEncoded: false)
        guard path.hasPrefix("/") else { return .ignore }
        let id = String(path.dropFirst())
        guard !id.contains(where: \.isNewline) else { return .ignore }
        guard id.range(of: xchatIDPattern, options: .regularExpression) != nil else { return .ignore }
        return .xchat(id: id)
    }

    /// The newline guard covers a regex `$` matching just before a trailing newline; `%0A` stays literal and
    /// fails every pattern.
    static func refDisposition(_ payload: String, patterns: [String] = refPatterns) -> LinkDisposition {
        guard payload.count <= 300, !payload.contains(where: \.isNewline) else { return .ignore }
        guard patterns.contains(where: { payload.range(of: $0, options: .regularExpression) != nil })
        else { return .ignore }
        return .ref(payload)
    }

    /// Ghostty's built-in path link is checked before user rules, so it claims a dotted cross-project ref such as
    /// `group/my.proj!12`, with whatever prose punctuation its greedy match kept. Only the cross-project shape is
    /// taken back: a bare `!12` or hash never reaches here through the path link. When a file of that name exists,
    /// ghostty delivers its absolute path instead, and that is left alone: which segments named the project is lost.
    static func reclaimedRefDisposition(_ raw: String, path: LinkDisposition) -> LinkDisposition {
        guard path == .ignore else { return path }
        var payload = Substring(raw)
        while let last = payload.last, ".,;:)?!*=&".contains(last) { payload = payload.dropLast() }
        return refDisposition(String(payload), patterns: [crossProjectRefPattern])
    }

    /// Extensions a clicked path may carry: markdown for plannotator, the rest for revdiff.
    static let openPathExtensions: Set<String> = [
        "md", "markdown", "swift", "py", "go", "ts", "tsx", "js", "jsx", "java", "kt", "sh", "zsh", "zig",
        "rs", "c", "h", "m", "mm", "yaml", "yml", "json", "toml", "conf",
    ]

    /// Relative paths need a `/` and no leading `-` (the script takes the path after `--`, but a gate should
    /// not lean on that); a bare name comes only through `pathScheme`. Only an absolute path may hold a space: ghostty resolves a match against the pane's
    /// pwd, so a pane under `Application Support` delivers one.
    static let openPathPatterns = [
        #"^[\w.@+][\w.@+~-]*(?:/[\w.@+~-]+)+$"#,
        #"^~(?:/[\w.@+~-]+)+$"#,
        #"^(?:/[\w.@+~ -]+)+$"#,
    ]

    /// A schemeless link is terminal text or an OSC 8 target, so it is refused unless it looks exactly like a
    /// file path with an allowed extension. Trailing prose punctuation ghostty's regex keeps (`.`, markdown
    /// `**`) is stripped, then an editor-style `:N`, `:N-M` or `:N:C` suffix becomes the line.
    static func openPathDisposition(_ raw: String) -> LinkDisposition {
        guard raw.count <= 1024, !raw.contains(where: { $0.isNewline || $0.asciiValue.map { $0 < 0x20 } == true })
        else { return .ignore }
        var path = Substring(raw)
        while let last = path.last, ".*;!?".contains(last) { path = path.dropLast() }
        guard let (candidate, line) = splitLine(path),
              openPathPatterns.contains(where: { candidate.range(of: $0, options: .regularExpression) != nil }),
              hasOpenableExtension(candidate.split(separator: "/").last ?? "")
        else { return .ignore }
        return .openPath(path: candidate, line: line)
    }

    static func bareNameDisposition(_ payload: String) -> LinkDisposition {
        guard payload.count <= 255, !payload.contains(where: { $0.isNewline || $0.asciiValue.map { $0 < 0x20 } == true })
        else { return .ignore }
        var name = Substring(payload)
        while let last = name.last, ".,;:)?!*".contains(last) { name = name.dropLast() }
        guard let (candidate, line) = splitLine(name),
              candidate.range(of: #"^[\w@+][\w.@+~-]*$"#, options: .regularExpression) != nil,
              hasOpenableExtension(Substring(candidate))
        else { return .ignore }
        return .openPath(path: candidate, line: line)
    }

    /// The path and its `:N`, `:N-M` or `:N:M` line, or nil for line 0.
    private static func splitLine(_ path: Substring) -> (String, Int?)? {
        guard let suffix = path.range(of: #":([0-9]+)(?:-[0-9]+|:[0-9]+)?$"#, options: .regularExpression) else {
            return (String(path), nil)
        }
        guard let value = Int(path[suffix].dropFirst().prefix { $0.isNumber }), value > 0 else { return nil }
        return (String(path[..<suffix.lowerBound]), value)
    }

    private static func hasOpenableExtension(_ name: Substring) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        return openPathExtensions.contains(name[name.index(after: dot)...].lowercased())
    }
}
