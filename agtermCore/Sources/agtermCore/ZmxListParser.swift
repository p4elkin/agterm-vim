import Foundation

/// Parses `zmx list` into structured entries. Host-free so the reaper and the foreground resolver can be
/// unit-tested without spawning zmx; the app target owns only the subprocess call.
///
/// One line per session, tab-separated `key=value` fields, in practice
/// `name=… pid=… clients=… created=… start_dir=… cmd=… agterm_name=…`. zmx marks the session the calling
/// client is attached to with a leading `→`, and a session it could not reach carries `err=` with no
/// `clients=` field at all.
public enum ZmxListParser {
    /// One listed session. `clients == nil` means the count is UNKNOWN, never zero: the reaper must not
    /// treat a session it failed to read as an orphan and kill it.
    public struct Entry: Equatable, Sendable {
        public let name: String
        public let clients: Int?
        public let leaderPID: Int32?
        public init(name: String, clients: Int?, leaderPID: Int32?) {
            self.name = name
            self.clients = clients
            self.leaderPID = leaderPID
        }
    }

    /// Parse a whole `zmx list` dump. Any line whose first field is not `name=<non-empty>` is dropped, which
    /// covers the "no sessions found in …" notice and anything zmx prints outside the listing.
    public static func parse(_ output: String) -> [Entry] {
        // split on newline CHARACTERS, not on the literal "\n": Swift reads a CRLF as one grapheme, so a
        // `\r\n` listing would come back as a single unparseable line.
        output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).compactMap(entry(from:))
    }

    private static func entry(from raw: Substring) -> Entry? {
        var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("→") {
            line = String(line.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let fields = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let name = fields.first.flatMap({ value(of: "name", in: $0) }), !name.isEmpty else { return nil }

        let rest = fields.dropFirst()
        // An unreachable session reports `err=` instead of a client count. Forcing the count to unknown even
        // when a stale `clients=` accompanies it keeps that line out of the reaper's hands.
        let failed = rest.contains { value(of: "err", in: $0) != nil }
        let clients = failed ? nil : rest.compactMap { value(of: "clients", in: $0) }.first.flatMap(Int.init)
        let pid = rest.compactMap { value(of: "pid", in: $0) }.first.flatMap(Int32.init)
        return Entry(name: name, clients: clients.flatMap { $0 >= 0 ? $0 : nil },
                     leaderPID: pid.flatMap { $0 > 0 ? $0 : nil })
    }

    private static func value(of key: String, in field: String) -> String? {
        field.hasPrefix(key + "=") ? String(field.dropFirst(key.count + 1)) : nil
    }
}
