import agtermCore
import Foundation

extension Headless {
    /// What runs in the foreground of a pane's terminal, as the Mac reads it with sysctl: the foreground process
    /// group of the daemon's login shell (`tpgid`, the eighth field of `/proc/<pid>/stat`), then the argv of that
    /// group's leader, or of a member `CommandRestore.groupDescentCandidates` picks once the leader is gone
    /// (`cat f | less`). Nil before the watcher has listed the daemon, or once a process is gone.
    func paneForeground(_ identity: UUID?) -> CommandRestore.PaneForeground? {
        guard let identity, let shell = daemonLeaders[ZmxSupport.daemonName(for: identity)],
              let fields = statFields(shell), fields.count > 5, let group = Int32(fields[5]), group > 0 else { return nil }
        let shellName = shellLookup().map { URL(fileURLWithPath: $0).lastPathComponent }
        if let argv = argv(group) { return CommandRestore.paneForeground(argv: argv, extra: shellName) }
        for pid in CommandRestore.groupDescentCandidates(pgid: group, members: groupMembers(group)) {
            if let argv = argv(pid) { return CommandRestore.paneForeground(argv: argv, extra: shellName) }
        }
        return nil
    }

    /// The fields after the command name, which may itself hold spaces and parentheses: state, ppid, pgrp, …
    private func statFields(_ pid: Int32) -> [Substring]? {
        guard let stat = Self.read("\(procRoot)/\(pid)/stat").flatMap({ String(data: $0, encoding: .utf8) }),
              let close = stat.lastIndex(of: ")") else { return nil }
        return stat[stat.index(after: close)...].split(separator: " ")
    }

    /// Nil for a gone process and for a zombie, whose cmdline is empty.
    private func argv(_ pid: Int32) -> [String]? {
        guard let cmdline = Self.read("\(procRoot)/\(pid)/cmdline"), !cmdline.isEmpty else { return nil }
        return cmdline.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Every process in `group`, by a scan of procfs: read only when the group's leader has no argv.
    private func groupMembers(_ group: Int32) -> [CommandRestore.ProcessGroupMember] {
        let pids = (try? FileManager.default.contentsOfDirectory(atPath: procRoot))?.compactMap { Int32($0) } ?? []
        return pids.compactMap { pid in
            guard let fields = statFields(pid), fields.count > 2, Int32(fields[2]) == group,
                  let parent = Int32(fields[1]) else { return nil }
            return CommandRestore.ProcessGroupMember(pid: pid, ppid: parent)
        }
    }

    /// procfs files report a size of 0, so they are read to the end rather than by their stat size.
    private static func read(_ path: String) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        return try? handle.readToEnd()
    }
}
