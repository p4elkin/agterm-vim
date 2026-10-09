import Foundation

/// `<hash>/mirror.json`, beside a mirror's clone: which repository it copies and when it was last opened.
public struct RebasedMirrorMarker: Codable, Equatable, Sendable {
    public static let fileName = "mirror.json"

    public let source: String
    public let lastOpened: Date

    public init(source: String, lastOpened: Date) {
        self.source = source
        self.lastOpened = lastOpened
    }

    public func write(to hashDirectory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: hashDirectory.appendingPathComponent(Self.fileName), options: .atomic)
    }

    /// Writes `{source, lastOpened: now}` into `hashDirectory` only when it exists; a failed write is dropped.
    public static func touch(hashDirectory: URL, source: String, now: Date) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: hashDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else { return }
        try? RebasedMirrorMarker(source: source, lastOpened: now).write(to: hashDirectory)
    }

    /// Nil for a missing or unreadable file.
    public static func read(from hashDirectory: URL) -> RebasedMirrorMarker? {
        guard let data = try? Data(contentsOf: hashDirectory.appendingPathComponent(fileName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RebasedMirrorMarker.self, from: data)
    }
}
