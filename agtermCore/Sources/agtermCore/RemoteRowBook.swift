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
        public var daemonsByPane: [ZmxPaneRole: String]
        public var splitAxis: SplitAxis
        /// The row's name as this Mac last showed it. Nil in a file an older build wrote, which kept only the
        /// name the origin reported at attach (`sessionName`).
        public var name: Name?
        /// The remote id of the row this one is a companion of, on the same host. Nil for a top-level row and
        /// in a file an older build wrote.
        public var parentRemoteSessionID: String?
        /// The attach nonce each pane's next attach takes the lead back from (`ZmxLeadBook.savedLead`); nil when
        /// no pane led, and in a file an older build wrote.
        public var leads: [ZmxPaneRole: String]?
        /// The origin companions this row has handled and whether it took its baseline, as the window snapshot keeps
        /// them for the rows it owns (`AttachedSessionSnapshot`).
        public var followedCompanions: [String]?
        public var companionsBaselined: Bool?

        public struct Name: Codable, Equatable, Sendable {
            /// The custom name, nil when the row shows its automatic one.
            public var value: String?
            /// A rename made here the origin has not confirmed yet.
            public var pending: Bool

            public init(value: String?, pending: Bool) {
                self.value = value
                self.pending = pending
            }
        }

        /// covers is whether the book records `session`, the test `init` applies.
        @MainActor
        public static func covers(_ session: Session) -> Bool {
            guard session.remoteHost != nil, let binding = session.remotePresentation?.binding, binding.origin != nil else { return false }
            return binding.daemon(forLocalPane: session.paneIdentity) != nil
        }

        @MainActor
        public init?(session: Session, windowID: UUID, workspaceID: UUID, position: Int,
                     parentRemoteSessionID: String? = nil) {
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
            daemonsByPane = [.left: primary]
            if session.hasSplit, let split = session.splitPaneIdentity, let daemon = binding.daemon(forLocalPane: split) {
                daemonsByPane[.right] = daemon
            }
            splitAxis = session.splitAxis
            name = Name(value: session.customName, pending: session.remotePresentation?.namePending ?? false)
            self.parentRemoteSessionID = parentRemoteSessionID
            var leads: [ZmxPaneRole: String] = [:]
            leads[.left] = ZmxLeadBook.shared.savedLead(pane: session.paneIdentity)
            if daemonsByPane[.right] != nil, let split = session.splitPaneIdentity {
                leads[.right] = ZmxLeadBook.shared.savedLead(pane: split)
            }
            self.leads = leads.isEmpty ? nil : leads
            followedCompanions = session.followedCompanions.isEmpty ? nil : session.followedCompanions.sorted()
            companionsBaselined = session.companionsBaselined ? true : nil
        }

        /// markingHandled is this record with origin companions `ids` of origin session `parent` on `host`'s zmx at
        /// `endpoint` recorded as handled, the book's half of `WindowLibrary.markOriginCompanionsHandled`.
        @MainActor
        public func markingHandled(_ ids: [String], parent: String, host: String, endpoint: ControlZmxEndpoint) -> Record {
            guard self.host == host, self.endpoint == endpoint,
                  WindowLibrary.originID(remoteSessionID) == WindowLibrary.originID(parent) else { return self }
            let followed = Set(followedCompanions ?? [])
            let marks = ids.map(WindowLibrary.originID)
            guard !followed.isSuperset(of: marks) else { return self }
            var copy = self
            copy.followedCompanions = followed.union(marks).sorted()
            return copy
        }

        /// A parent id that could not reach an argv or an error message drops the link, never the row.
        fileprivate var sanitized: Record {
            guard let parent = parentRemoteSessionID, !RemoteSession.isPlain(parent) else { return self }
            var copy = self
            copy.parentRemoteSessionID = nil
            return copy
        }

        /// The name to create the row with, and whether a rename made here is still to reach the origin.
        public var restoredName: (value: String?, pending: Bool) {
            guard let name else { return (sessionName, false) }
            return (name.value, name.pending)
        }

        public func binding(daemonsByLocalPane: [UUID: String]) -> RemoteBinding {
            RemoteBinding(remoteSessionID: remoteSessionID, daemonsByLocalPane: daemonsByLocalPane,
                presentationVersion: presentationVersion,
                origin: RemoteBinding.Origin(host: host, endpoint: endpoint, sessionName: sessionName))
        }

        fileprivate var isValid: Bool {
            guard position >= 0, RemoteSession.isPlain(host), !host.hasPrefix("-"),
                  RemoteSession.isPlain(remoteSessionID), Self.isPath(endpoint.executable), Self.isPath(endpoint.socketDirectory),
                  daemonsByPane[.left] != nil, daemonsByPane.values.allSatisfy(ZmxSupport.isDaemonName),
                  Set(daemonsByPane.values).count == daemonsByPane.count else { return false }
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

    public struct LoadReport: Equatable, Sendable {
        public let records: [Record]
        /// `host/remoteSessionID` of each record an older build saved with the removed mosh transport, which is not loaded.
        public let droppedMosh: [String]
    }

    /// Invalid records are discarded independently; a missing or corrupt file is empty.
    public func load() -> [Record] { loadReport().records }

    public func loadReport() -> LoadReport {
        guard let data = try? Data(contentsOf: fileURL),
              let loaded = try? JSONDecoder().decode([Loaded].self, from: data) else { return LoadReport(records: [], droppedMosh: []) }
        return LoadReport(records: loaded.filter { !$0.savedOverMosh }.map(\.record).filter(\.isValid).map(\.sanitized),
                          droppedMosh: loaded.filter(\.savedOverMosh).map { "\($0.record.host)/\($0.record.remoteSessionID)" })
    }

    /// A record read together with the `transport` key older builds wrote, `{"ssh":{}}` or `{"mosh":{…}}`.
    private struct Loaded: Decodable {
        let record: Record
        let savedOverMosh: Bool

        private enum Key: String, CodingKey { case transport }
        private enum Transport: String, CodingKey { case mosh }

        init(from decoder: any Decoder) throws {
            record = try Record(from: decoder)
            let transport = try? decoder.container(keyedBy: Key.self).nestedContainer(keyedBy: Transport.self, forKey: .transport)
            savedOverMosh = transport?.contains(.mosh) ?? false
        }
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
            let siblings = rows[workspaceID] ?? []
            return siblings.enumerated().compactMap { position, session in
                let parent = siblings.first { $0.id == session.parentID }?.remotePresentation?.binding.remoteSessionID
                return Record(session: session, windowID: windowID, workspaceID: workspaceID, position: position,
                              parentRemoteSessionID: parent)
            }
        }
    }
}
