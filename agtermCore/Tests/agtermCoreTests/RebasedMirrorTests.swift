import Foundation
import Testing
@testable import agtermCore

struct RebasedMirrorTests {
    @Test(arguments: [("", "/r"), ("-oProxyCommand=x", "/r"), ("a b", "/r"), ("a/b", "/r"), ("h\n", "/r"),
                      ("p4linux", ""), ("p4linux", "repo"), ("p4linux", "/r\n"), ("p4linux", "/r\u{7}")])
    func refusesAHostOrPathSshWouldMisread(_ host: String, _ path: String) {
        #expect(RebasedMirror(host: host, path: path) == nil)
    }

    @Test func theToplevelQueryQuotesThePathForTheRemoteShell() throws {
        let mirror = try #require(RebasedMirror(host: "sasha@p4linux", path: "/home/s/it's here"))
        #expect(mirror.toplevelCommand == ["/usr/bin/ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "--",
                                           "sasha@p4linux", "git -C '/home/s/it'\\''s here' rev-parse --show-toplevel"])
    }

    @Test(arguments: [("/home/s/repo\n", "/home/s/repo"), ("repo\n", nil), ("", nil), ("/a\n/b\n", nil)])
    func readsTheToplevelFromTheQuerysOutput(_ output: String, _ top: String?) {
        #expect(RebasedMirror.toplevel(fromOutput: output) == top)
    }

    @Test func theDirectoryIsPerHostAndRepositoryAndNamedAfterTheRepository() throws {
        let state = URL(fileURLWithPath: "/state")
        let mirror = try #require(RebasedMirror(host: "p4linux", path: "/home/s/repo/sub"))
        let directory = mirror.directory(top: "/home/s/repo", stateDirectory: state)
        #expect(directory.lastPathComponent == "repo")
        #expect(directory.path.hasPrefix("/state/rebased/mirrors/p4linux/"))
        #expect(directory == mirror.directory(top: "/home/s/repo", stateDirectory: state))
        #expect(directory != mirror.directory(top: "/home/t/repo", stateDirectory: state))
        let other = try #require(RebasedMirror(host: "other", path: "/home/s/repo"))
        #expect(directory != other.directory(top: "/home/s/repo", stateDirectory: state))
    }

    @Test func theRefreshTakesTheHostsBranchesRemoteBranchesTagsAndHead() throws {
        let mirror = try #require(RebasedMirror(host: "p4linux", path: "/home/s/repo"))
        #expect(mirror.refreshCommands(top: "/home/s/repo", directory: "/m/repo") == [
            ["/usr/bin/git", "init", "-q", "/m/repo"],
            ["/usr/bin/git", "-C", "/m/repo", "fetch", "-q", "--prune", "--force", "--update-head-ok", "p4linux:/home/s/repo",
             "+refs/heads/*:refs/heads/*", "+refs/remotes/*:refs/remotes/*", "+refs/tags/*:refs/tags/*",
             "+HEAD:refs/agterm/head"],
            ["/usr/bin/git", "-C", "/m/repo", "checkout", "-q", "--force", "--detach", "refs/agterm/head"],
        ])
        #expect(RebasedMirror.environment["GIT_SSH_COMMAND"] == "ssh -o BatchMode=yes -o ConnectTimeout=10")
    }

    @Test(arguments: [("p4linux", "/home/s/repo", true), ("p4linux", "/home/s/repo/sub", true),
                      ("p4linux", "/home/s/repository", false), ("other", "/home/s/repo", false)])
    func aSourceCoversItsRepositoryAndNothingBeside(_ host: String, _ path: String, _ covered: Bool) {
        #expect(RebasedMirror.covers(source: "p4linux:/home/s/repo", host: host, path: path) == covered)
    }

    @MainActor @Test func theOverlayNodeReportsFetchingAndTheSource() {
        let overlay = RebasedOverlay(project: "/home/s/repo", state: .fetching, source: "p4linux:/home/s/repo")
        #expect(overlay.controlNode == ControlRebasedOverlayNode(project: "/home/s/repo", state: "fetching",
                                                                 source: "p4linux:/home/s/repo", hidden: false))
    }
}
