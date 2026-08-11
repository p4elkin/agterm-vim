import Foundation

/// Whether a pane's foreground argv is the zmx client agterm put there, and where the real program is when
/// it is. Pure: the app target owns the `zmx list` call and the sysctl that turns a session leader into its
/// pty's foreground process group.
///
/// Without this a wrapped pane reports `zmx attach <key>` for everything it runs, which is the one read
/// `agtermctl tree` exists to give: what is running in that row.
public enum ZmxForegroundSelection {
    /// What the `tree` read should report for the pane.
    public enum Decision: Equatable, Sendable {
        /// The argv already in hand: not a wrapper, or a wrapper the listing could not place.
        case keepArgv
        /// A wrapped pane. Report what runs inside zmx session `key`, whose leader process is `leaderPID`.
        case inspect(leaderPID: Int32, key: String)
    }

    /// The zmx session key this argv attaches to, or nil when it is not agterm's own wrapper.
    ///
    /// A `zmx attach` for a name agterm does not own — a session the user picked by hand, or a remote one —
    /// is deliberately NOT a wrapper. That pane really is running a zmx client, and looking past it would
    /// report a process the row does not own.
    public static func wrappedKey(argv: [String]) -> String? {
        guard argv.count >= 3, CommandRestore.basename(argv[0]) == binaryName, argv[1] == attachSubcommand,
              ZmxSessionKey.isOwned(argv[2])
        else { return nil }
        return argv[2]
    }

    /// `listing` nil means `zmx list` could not be read; the wrapper then reports itself, which is exactly
    /// today's answer rather than a claim of an idle pane. Same for a key the listing does not carry or one
    /// whose leader pid is unknown.
    public static func decide(argv: [String], listing: [ZmxListParser.Entry]?) -> Decision {
        guard let key = wrappedKey(argv: argv), let listing,
              let leaderPID = listing.first(where: { $0.name == key })?.leaderPID
        else { return .keepArgv }
        return .inspect(leaderPID: leaderPID, key: key)
    }

    private static let binaryName = "zmx"
    private static let attachSubcommand = "attach"
}
