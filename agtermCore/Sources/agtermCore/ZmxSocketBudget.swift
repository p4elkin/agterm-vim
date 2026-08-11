import Foundation

/// Whether a wrapped pane's zmx socket path fits in `sockaddr_un`. A pane whose socket cannot bind must
/// fall back to a plain shell, so the wrap decision asks this first.
///
/// The directory is resolved the way zmx resolves it, and deliberately NOT pinned to an agterm-specific
/// one: Sasha's tooling (`agterm-zmx`, `agterm-zmx-mirror`) and the mosh incantation all read zmx's own
/// default directory, so an agterm-only directory would make `zmx list` look in the wrong place on both
/// machines.
public enum ZmxSocketBudget {
    /// `sockaddr_un.sun_path` is a 104-byte array on Darwin, and the path it holds is NUL-terminated.
    public static let sunPathByteLimit = 104
    /// Held back from the limit so a path that only just fits is treated as over budget. The real setup needs
    /// 99 bytes — a 56-byte directory, a separator and a 42-byte key — so it clears the resulting 101-byte
    /// budget by 2 and no more; a larger margin would reject a configuration that works today.
    public static let safetyMarginBytes = 2
    /// The longest socket path a wrapped pane may use.
    public static var maxPathByteCount: Int { sunPathByteLimit - 1 - safetyMarginBytes }

    /// The directory zmx binds its session sockets in: `ZMX_DIR` verbatim when set, else
    /// `<XDG_RUNTIME_DIR else TMPDIR else /tmp>/zmx-<uid>`. A socket is the bare session name inside it.
    ///
    /// `ZMX_DIR` is the whole directory, not a base — that is the form `agterm-zmx` pins for a remote
    /// attach, where mosh-server's stripped environment drops `TMPDIR` and zmx would otherwise create a
    /// second, empty session under `/tmp/zmx-<uid>`.
    public static func socketDir(env: [String: String], uid: Int = Int(getuid())) -> String {
        if let pinned = normalized(env["ZMX_DIR"]) { return pinned }
        let base = normalized(env["XDG_RUNTIME_DIR"]) ?? normalized(env["TMPDIR"]) ?? "/tmp"
        return appending("zmx-\(uid)", to: base)
    }

    /// Why a wrapped pane must not be attempted, or nil when the worst-case socket path fits.
    /// `keyByteCount` is the longest key a pane can produce — `ZmxSessionKey.maxByteCount`.
    public static func probe(env: [String: String], keyByteCount: Int, uid: Int = Int(getuid())) -> String? {
        let dir = socketDir(env: env, uid: uid)
        let separator = dir.hasSuffix("/") ? 0 : 1
        let pathBytes = dir.utf8.count + separator + keyByteCount
        guard pathBytes > maxPathByteCount else { return nil }
        return "zmx socket path in \(dir) needs \(pathBytes) bytes, over the \(maxPathByteCount)-byte budget"
    }

    /// nil for a missing or empty value; otherwise the path with trailing slashes dropped, except a bare `/`.
    private static func normalized(_ raw: String?) -> String? {
        guard var value = raw, !value.isEmpty else { return nil }
        while value.count > 1, value.hasSuffix("/") { value.removeLast() }
        return value
    }

    private static func appending(_ component: String, to dir: String) -> String {
        dir.hasSuffix("/") ? dir + component : dir + "/" + component
    }
}
