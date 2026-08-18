import AppKit
import Darwin
import Foundation
import agtermCore

/// Reads the argv of a pane's foreground process. The libghostty pid lookup lives on
/// `GhosttySurfaceView.foregroundPid()`; this owns the macOS `sysctl` syscalls and defers every judgement
/// (parse, shell-detection, dash-stripping) to the host-free `CommandRestore`.
///
/// Two entry points, because the restore capture and the `tree` read-side ask different questions. See
/// `running(for:shellBasename:)` for why only one of them descends into the process group.
enum ForegroundProcess {
    /// The pane's foreground command for the RESTORE capture: the process-group leader's argv only, or nil
    /// when the pane is at its shell prompt, the surface isn't realized, or the syscall fails.
    /// `shellBasename` is the user's `$SHELL` basename so a non-standard login shell is recognized too.
    ///
    /// Deliberately does NOT descend the group. A non-nil capture sets `hadForeground`, which preempts
    /// `initialCommand` in `CommandRestore.restorePlan` — so a descending capture would restore a
    /// `--command` session by typing its command into a login shell instead of taking the exec path,
    /// losing the `--wait` hold and the close-on-exit shape.
    /// `ownedKey` is the pane's recorded zmx session (`Session.zmxPrimaryKey`/`zmxSplitKey`).
    @MainActor
    static func command(for view: GhosttySurfaceView, shellBasename: String?, ownedKey: String?) -> [String]? {
        guard let pid = view.foregroundPid(), let argv = procArgs(pid: pid),
              let usable = usable(argv, shellBasename: shellBasename) else { return nil }
        // THIS pane's own `zmx attach <key>` is agterm's own doing, never something the user ran: capturing it
        // would make a restore re-attach to a key this app now generates itself, and the persistent session
        // already holds whatever was running. An attach to any OTHER name is the user's — `agterm-zmx pick`
        // binds a row to another row's session with exactly this shape — and must survive the restart.
        guard let ownedKey, ZmxForegroundSelection.wrappedKey(argv: usable) == ownedKey else { return usable }
        return nil
    }

    /// The pane's foreground command for the `tree` read-side: as `command`, plus a descent into the
    /// process group when the leader's argv is unreadable.
    ///
    /// libghostty's `foreground_pid` is `tcgetpgrp`, a process GROUP id. An interactive shell puts each
    /// job in its own group, so the leader IS the program. A pane with no job-control shell (a
    /// `--command` session) runs its program as a child of setuid-root `login`, whose argv
    /// `KERN_PROCARGS2` refuses for a non-root caller — so without the descent every such pane reads as
    /// idle. A setuid leader under a job-control shell (`top`, `sudo`) still reads as idle while it is
    /// alive, because the descent takes only the leader's own children: `sudo`'s child runs as root and
    /// stays unreadable, and a pipeline's other elements are children of the shell rather than of the
    /// leader. Once the leader is reaped there is no parentage to test and every survivor qualifies, so a
    /// pipeline that outlives its `sudo` does report — see `groupDescentCandidates`.
    ///
    /// `zmx` resolves one step further, past a wrapped pane's own `zmx attach <key>`, so the row reports the
    /// program running inside its persistent session. Nil skips that entirely, which is what the restore
    /// capture and every test without a resolver want.
    @MainActor
    static func running(for view: GhosttySurfaceView, shellBasename: String?,
                        zmx: ZmxForegroundResolver? = nil, ownedKey: String? = nil) -> [String]? {
        guard let pgid = view.foregroundPid(),
              let argv = groupArgv(pgid: pgid, shellBasename: shellBasename) else { return nil }
        // only past THIS pane's own wrapper: a session the user picked by hand is a zmx client the row really
        // runs, and reporting what lives inside it would name a program this row does not own.
        guard let ownedKey, ZmxForegroundSelection.wrappedKey(argv: argv) == ownedKey,
              let leader = zmx?.leaderPID(behind: argv) else { return argv }
        // the pane's own tty carries the zmx CLIENT. What runs in the session is on the daemon's pty, whose
        // descriptor this process does not hold — so ask the leader's kinfo_proc for that pty's foreground
        // group, then read it exactly as a pane's own group is read. A shell at its prompt in there reads
        // idle, which is the truth about the row.
        guard let inner = terminalForegroundGroup(of: leader) else { return argv }
        return groupArgv(pgid: inner, shellBasename: shellBasename)
    }

    /// The reportable argv for one process group: the leader's own, else its readable children's.
    @MainActor
    private static func groupArgv(pgid: pid_t, shellBasename: String?) -> [String]? {
        if let argv = procArgs(pid: pgid) { return usable(argv, shellBasename: shellBasename) }
        let members = CommandRestore.groupDescentCandidates(pgid: pgid, members: processGroup(pgid: pgid))
        for pid in members {
            if let argv = procArgs(pid: pid) { return usable(argv, shellBasename: shellBasename) }
        }
        return nil
    }

    /// The foreground process group of `pid`'s controlling terminal, read from `kinfo_proc.kp_eproc.e_tpgid`.
    /// This is `tcgetpgrp` for a pty this process has no descriptor for. nil when the process is gone or has
    /// no controlling terminal.
    static func terminalForegroundGroup(of pid: pid_t) -> pid_t? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let group = info.kp_eproc.e_tpgid
        return group > 0 ? group : nil
    }

    /// Normalize a raw argv and drop it when it is an idle shell: a shell is skipped ONLY at its prompt (no
    /// script/command argument); a shell running a script (a `#!/bin/sh` wrapper like `cld`) is a real
    /// foreground process to report.
    private static func usable(_ argv: [String], shellBasename: String?) -> [String]? {
        guard !argv.isEmpty else { return nil }
        if CommandRestore.isIdleShell(argv: argv, extra: shellBasename) { return nil }
        return CommandRestore.stripLoginDash(argv)
    }

    /// Fetch and parse a process's argv via `sysctl(KERN_PROCARGS2)`; nil on any syscall failure, which is
    /// what a process owned by another user (setuid `login`, `sudo`) returns.
    private static func procArgs(pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }
        return CommandRestore.parseProcArgs(Data(buffer[0..<size]))
    }

    /// Every member of `pgid`'s process group via `sysctl(KERN_PROC_PGRP)`, with each one's parent; empty
    /// on any syscall failure. The count comes from the second call, because the group can shrink between
    /// the two and leave fewer entries than the buffer holds.
    ///
    /// A group that GROWS past the sizing call's slop (a fixed handful of entries) returns ENOMEM, and
    /// macOS reports `oldlen` 0 there, so nothing can be salvaged from the buffer however full it is.
    /// Retry with a widening margin instead, rather than reporting a busy pane as idle.
    private static func processGroup(pgid: pid_t) -> [CommandRestore.ProcessGroupMember] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PGRP, pgid]
        let stride = MemoryLayout<kinfo_proc>.stride
        for margin in [0, 32, 256] {
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
            var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + margin)
            guard !procs.isEmpty else { return [] }
            size = procs.count * stride
            if sysctl(&mib, u_int(mib.count), &procs, &size, nil, 0) == 0 {
                return procs.prefix(size / stride).map { .init(pid: $0.kp_proc.p_pid, ppid: $0.kp_eproc.e_ppid) }
            }
            if errno != ENOMEM { return [] }
        }
        return []
    }
}
