import Foundation

/// Remote rows live outside snapshots so restore modes never replay a saved shell command.
public struct RemoteRowBook {
    public struct Record: Codable, Equatable, Sendable {
        public var windowID: UUID
        public var workspaceID: UUID
        public var position: Int
        public var host: String
        public var endpoint: ControlZmxEndpoint
        public var sessionName: String
        public var remoteSessionID: String
        public var presentationVersion: Int?
        public var transport: RemoteTransport
        public var daemonsByPane: [ZmxPaneRole: String]
        public var splitAxis: SplitAxis

        @MainActor
        public init?(session: Session, windowID: UUID, workspaceID: UUID, position: Int) {
            guard session.remoteHost != nil, let binding = session.remotePresentation?.binding,
                  let origin = binding.origin, let primary = binding.daemon(forLocalPane: session.paneIdentity) else { return nil }
            self.windowID = windowID
            self.workspaceID = workspaceID
            self.position = position
            host = origin.host
            endpoint = origin.endpoint
            sessionName = origin.sessionName
            remoteSessionID = binding.remoteSessionID
            presentationVersion = binding.presentationVersion
            transport = origin.transport
            daemonsByPane = [.left: primary]
            if session.hasSplit, let split = session.splitPaneIdentity, let daemon = binding.daemon(forLocalPane: split) {
                daemonsByPane[.right] = daemon
            }
            splitAxis = session.splitAxis
        }

        public func binding(daemonsByLocalPane: [UUID: String]) -> RemoteBinding {
            RemoteBinding(remoteSessionID: remoteSessionID, daemonsByLocalPane: daemonsByLocalPane,
                presentationVersion: presentationVersion,
                origin: RemoteBinding.Origin(host: host, endpoint: endpoint, sessionName: sessionName, transport: transport))
        }

        fileprivate var isValid: Bool {
            guard position >= 0, RemoteSession.isPlain(host), !host.hasPrefix("-"),
                  RemoteSession.isPlain(remoteSessionID), Self.isPath(endpoint.executable), Self.isPath(endpoint.socketDirectory),
                  daemonsByPane[.left] != nil, daemonsByPane.values.allSatisfy(ZmxSupport.isDaemonName),
                  Set(daemonsByPane.values).count == daemonsByPane.count else { return false }
            if case .mosh(let server, let client) = transport {
                return [server, client].compactMap { $0 }.allSatisfy(RemoteSession.isPlainMoshServer)
            }
            return true
        }

        private static func isPath(_ value: String) -> Bool {
            !value.isEmpty && !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
        }
    }

    public struct RestoreEntry: Equatable, Sendable {
        public let record: Record
        public let workspaceID: UUID
        public let position: Int
    }

    @MainActor
    public static func restorePlan(records: [Record], windowID: UUID, store: AppStore) -> [RestoreEntry] {
        let order = Dictionary(uniqueKeysWithValues: store.workspaces.enumerated().map { ($0.element.id, $0.offset) })
        let matching = records.enumerated().filter { $0.element.windowID == windowID && $0.element.isValid }
        let known = matching.filter { order[$0.element.workspaceID] != nil }.sorted {
            let lhs = (order[$0.element.workspaceID] ?? 0, $0.element.position, $0.offset)
            let rhs = (order[$1.element.workspaceID] ?? 0, $1.element.position, $1.offset)
            return lhs < rhs
        }
        var plan = known.map { RestoreEntry(record: $0.element, workspaceID: $0.element.workspaceID, position: $0.element.position) }
        guard let workspaceID = store.currentWorkspaceID,
              let workspace = store.workspaces.first(where: { $0.id == workspaceID }) else { return plan }
        var position = workspace.sessions.count + plan.count { $0.workspaceID == workspaceID }
        for (_, record) in matching where order[record.workspaceID] == nil {
            plan.append(RestoreEntry(record: record, workspaceID: workspaceID, position: position))
            position += 1
        }
        return plan
    }

    public let fileURL: URL

    public init(directory: URL = PersistenceStore.defaultDirectory) {
        fileURL = directory.appendingPathComponent("remote-rows.json")
    }

    /// Invalid records are discarded independently; a missing or corrupt file is empty.
    public func load() -> [Record] {
        guard let data = try? Data(contentsOf: fileURL),
              let records = try? JSONDecoder().decode([Record].self, from: data) else { return [] }
        return records.filter(\.isValid)
    }

    public func save(_ records: [Record]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: fileURL, options: .atomic)
    }

    @MainActor
    public static func records(from library: WindowLibrary, previous: [Record]) -> [Record] {
        library.windows.flatMap { window in
            guard let store = library.store(for: window.id) else {
                // Closed windows stay reopenable; only an open store can establish that a row was removed.
                return previous.filter { $0.windowID == window.id }
            }
            return records(in: store, windowID: window.id)
        }
    }

    @MainActor
    private static func records(in store: AppStore, windowID: UUID) -> [Record] {
        let pending = store.pendingCloseMembers()
        var workspaceIDs = store.workspaces.map(\.id)
        var rows = Dictionary(uniqueKeysWithValues: store.workspaces.map { ($0.id, $0.sessions) })
        var present = Set(store.workspaces.flatMap(\.sessions).map(\.id))
        var closeIDs: [UUID] = []
        var seenCloses: Set<UUID> = []
        for member in pending {
            if rows[member.workspaceID] == nil {
                workspaceIDs.append(member.workspaceID)
                rows[member.workspaceID] = []
            }
            if seenCloses.insert(member.closeID).inserted { closeIDs.append(member.closeID) }
        }
        let groups = Dictionary(grouping: pending, by: \.closeID)
        // Undo newest closes first, but restore a batch's members in saved index order.
        for closeID in closeIDs.reversed() {
            for member in (groups[closeID] ?? []).sorted(by: { $0.sessionIndex < $1.sessionIndex }) {
                guard present.insert(member.session.id).inserted else { continue }
                let position = max(0, min(member.sessionIndex, rows[member.workspaceID]?.count ?? 0))
                rows[member.workspaceID, default: []].insert(member.session, at: position)
            }
        }
        return workspaceIDs.flatMap { workspaceID in
            (rows[workspaceID] ?? []).enumerated().compactMap { position, session in
                Record(session: session, windowID: windowID, workspaceID: workspaceID, position: position)
            }
        }
    }
}
