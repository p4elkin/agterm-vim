import Foundation
import Testing
@testable import agtermCore

struct RebasedMirrorSyncTests {
    @Test func theBinaryIsTheFirstExecutableCandidate() {
        #expect(RebasedMirrorSync.binary(candidates: ["/a", "/b"], isExecutable: { $0 == "/b" }) == "/b")
        #expect(RebasedMirrorSync.binary(candidates: ["/a", "/b"], isExecutable: { _ in true }) == "/a")
        #expect(RebasedMirrorSync.binary(candidates: ["/a", "/b"], isExecutable: { _ in false }) == nil)
        #expect(RebasedMirrorSync.candidates == ["/opt/homebrew/bin/mutagen", "/usr/local/bin/mutagen"])
    }

    @Test func theStateIDIsTheHashOfTheResolvedStateDirectory() {
        let tmp = RebasedMirrorSync.stateID(stateDirectory: URL(fileURLWithPath: "/tmp"))
        #expect(tmp == RebasedMirror.hash(RebasedMirrorCleanup.projectPath(URL(fileURLWithPath: "/tmp"))))
        #if os(macOS)
        #expect(tmp == RebasedMirrorSync.stateID(stateDirectory: URL(fileURLWithPath: "/private/tmp")))
        #endif
    }

    @Test func namesSeparateStateHostAndRepository() {
        let name = RebasedMirrorSync.treeName(state: "s1", host: "p4linux", top: "/home/s/repo")
        #expect(name == "agterm-s1-\(RebasedMirror.hash("p4linux"))-\(RebasedMirror.hash("/home/s/repo"))")
        #expect(name != RebasedMirrorSync.treeName(state: "s1", host: "other", top: "/home/s/repo"))
        #expect(name != RebasedMirrorSync.treeName(state: "s2", host: "p4linux", top: "/home/s/repo"))
        #expect(RebasedMirrorSync.m2Name(state: "s1", host: "p4linux") == "agterm-s1-m2-\(RebasedMirror.hash("p4linux"))")
    }

    @Test func theTreeSessionIsAReadOnlyReplicaWithoutBuildOutput() {
        let clone = URL(fileURLWithPath: "/state/rebased/mirrors/p4linux/h/repo")
        let argv = RebasedMirrorSync.createTree(binary: "/m", state: "s1", host: "p4linux", top: "/home/s/repo", clone: clone)
        #expect(argv == ["/m", "sync", "create", "--no-global-configuration",
                         "--name", RebasedMirrorSync.treeName(state: "s1", host: "p4linux", top: "/home/s/repo"),
                         "--label", "agterm-state=s1", "--label", "agterm-kind=tree",
                         "--mode", "one-way-replica", "--ignore-vcs",
                         "--ignore", ".idea/", "--ignore", "node_modules/", "--ignore", "**/target/*",
                         "--ignore", "!**/target/generated-sources/", "--ignore", "!**/target/generated-test-sources/",
                         "--default-file-mode-beta", "0444", "--default-directory-mode-beta", "0755",
                         "p4linux:/home/s/repo", "/state/rebased/mirrors/p4linux/h/repo"])
    }

    @Test func theM2SessionKeepsWhatTheMacAdds() {
        let argv = RebasedMirrorSync.createM2(binary: "/m", state: "s1", host: "p4linux",
                                              stateDirectory: URL(fileURLWithPath: "/state"))
        #expect(argv == ["/m", "sync", "create", "--no-global-configuration",
                         "--name", RebasedMirrorSync.m2Name(state: "s1", host: "p4linux"),
                         "--label", "agterm-state=s1", "--label", "agterm-kind=m2",
                         "--mode", "one-way-safe", "p4linux:.m2/repository", "/state/rebased/m2/p4linux/repository"])
    }

    @Test func listFlushResumeAndTerminateAddressOneStateOrOneName() {
        #expect(RebasedMirrorSync.list(binary: "/m", state: "s1")
            == ["/m", "sync", "list", "--label-selector", "agterm-state=s1", "--template", "{{json .}}"])
        #expect(RebasedMirrorSync.flush(binary: "/m", name: "n") == ["/m", "sync", "flush", "n"])
        #expect(RebasedMirrorSync.resume(binary: "/m", name: "n") == ["/m", "sync", "resume", "n"])
        #expect(RebasedMirrorSync.terminate(binary: "/m", name: "n") == ["/m", "sync", "terminate", "n"])
    }

    @Test func theParserReadsTheCapturedList() throws {
        let sessions = try RebasedMirrorSync.sessions(fromListOutput: Data(Self.captured.utf8))
        #expect(sessions == [
            .init(name: "probe-tree", kind: "tree", status: "watching", betaPath: "/STATE/list1.json",
                  alphaFiles: 6, betaFiles: 6),
            .init(name: "probe-m2", kind: "m2", status: "watching", betaPath: "/STATE/list-m2.json",
                  alphaFiles: 3, betaFiles: 2, conflictRoots: ["org/z/c/3.0/c-3.0.jar"]),
            .init(name: "probe-realm2", kind: "m2", status: "staging-beta", betaPath: "/STATE/m2/p4linux/repository",
                  alphaFiles: 26616, betaFiles: nil,
                  rootProblem: "unable to walk to transition root parent: unable to open synchronization root parent directory: "
                      + "no such file or directory"),
        ])
        #expect(!sessions[0].copying)
        #expect(!sessions[1].copying)
        #expect(sessions[2].copying)
    }

    @Test func theParserReadsPausedErrorsAndHalts() throws {
        let json = """
        [{"name": "n", "status": "halted-on-root-emptied", "paused": true, "lastError": "boom",
          "alpha": {"path": "a", "files": 2, "scanProblems": [{"path": "x", "error": "target is absolute"}]},
          "beta": {"path": "/b", "files": 1, "transitionProblems": [{"path": "Readme", "error": "file exists"}]}}]
        """
        let session = try #require(try RebasedMirrorSync.sessions(fromListOutput: Data(json.utf8)).first)
        #expect(session == .init(name: "n", kind: nil, status: "halted-on-root-emptied", paused: true, error: "boom",
                                 betaPath: "/b", alphaFiles: 2, betaFiles: 1, fileProblems: 2))
        #expect(session.halted)
        #expect(!session.copying)
        #expect(try RebasedMirrorSync.sessions(fromListOutput: Data("[]".utf8)).isEmpty)
    }

    @Test func theReadBackStateComesFromTheTreeSessionOnTheClone() {
        let clone = URL(fileURLWithPath: "/state/rebased/mirrors/p4linux/h/repo")
        let tree = RebasedMirrorSync.Session(name: "t", kind: "tree", status: "watching", betaPath: clone.path)
        let paused = RebasedMirrorSync.Session(name: "t", kind: "tree", status: "watching", paused: true, betaPath: clone.path)
        let m2 = RebasedMirrorSync.Session(name: "m", kind: "m2", status: "watching", betaPath: clone.path)
        #expect(RebasedMirrorSync.syncState(clone: clone, listing: nil) == .init(state: "none"))
        #expect(RebasedMirrorSync.syncState(clone: clone, listing: .failure(.init(reason: "no daemon")))
            == .init(state: "unknown", error: "no daemon"))
        #expect(RebasedMirrorSync.syncState(clone: clone, listing: .success([m2, tree])) == .init(state: "watching"))
        #expect(RebasedMirrorSync.syncState(clone: clone, listing: .success([paused])) == .init(state: "paused"))
        #expect(RebasedMirrorSync.syncState(clone: clone, listing: .success([m2])) == .init(state: "none"))
    }

    @Test(arguments: ["", "null", "{}", "Error: unable to connect to daemon", "[{\"name\": \"n\"}]"])
    func malformedOutputIsAnErrorNotAnEmptyList(_ output: String) {
        #expect(throws: (any Error).self) { try RebasedMirrorSync.sessions(fromListOutput: Data(output.utf8)) }
    }

    // `mutagen sync list --template '{{json .}}'`, mutagen 0.18.1, task 1 probes; beta paths replaced.
    static let captured = """
    [
     {
      "identifier": "sync_2n97SsfIoO3FodVBxFVJLIGL4oMDqHyVo9QDR9RkaW2",
      "version": 1,
      "creationTime": "2026-10-23T12:06:49.398758Z",
      "creatingVersion": "0.18.1",
      "alpha": {
       "protocol": "ssh",
       "host": "p4linux",
       "path": "agterm-probe/repo",
       "ignore": {},
       "symlink": {},
       "watch": {},
       "permissions": {},
       "compression": {},
       "connected": true,
       "scanned": true,
       "directories": 9,
       "files": 6,
       "totalFileSize": 59
      },
      "beta": {
       "protocol": "local",
       "path": "/STATE/list1.json",
       "ignore": {},
       "symlink": {},
       "watch": {},
       "permissions": {
        "defaultFileMode": "0444",
        "defaultDirectoryMode": "0755"
       },
       "compression": {},
       "connected": true,
       "scanned": true,
       "directories": 9,
       "files": 6,
       "totalFileSize": 59
      },
      "mode": "one-way-replica",
      "ignore": {
       "paths": [
        ".idea/",
        "node_modules/",
        "**/target/*",
        "!**/target/generated-sources/",
        "!**/target/generated-test-sources/"
       ],
       "vcs": true
      },
      "symlink": {},
      "watch": {},
      "permissions": {},
      "compression": {},
      "name": "probe-tree",
      "labels": {
       "agterm-kind": "tree",
       "agterm-probe": "1"
      },
      "paused": false,
      "status": "watching",
      "successfulCycles": 3
     },
     {
      "identifier": "sync_Htpqnfo09kbQUJFhQ8vwazQkx3okTAegJzgGsUZySZS",
      "version": 1,
      "creationTime": "2026-10-23T12:07:54.554023Z",
      "creatingVersion": "0.18.1",
      "alpha": {
       "protocol": "ssh",
       "host": "p4linux",
       "path": "agterm-probe-m2/repository",
       "ignore": {},
       "symlink": {},
       "watch": {},
       "permissions": {},
       "compression": {},
       "connected": true,
       "scanned": true,
       "directories": 8,
       "files": 3,
       "totalFileSize": 23
      },
      "beta": {
       "protocol": "local",
       "path": "/STATE/list-m2.json",
       "ignore": {},
       "symlink": {},
       "watch": {},
       "permissions": {},
       "compression": {},
       "connected": true,
       "scanned": true,
       "directories": 8,
       "files": 2,
       "totalFileSize": 12
      },
      "mode": "one-way-safe",
      "ignore": {},
      "symlink": {},
      "watch": {},
      "permissions": {},
      "compression": {},
      "name": "probe-m2",
      "labels": {
       "agterm-kind": "m2",
       "agterm-probe": "1"
      },
      "paused": false,
      "status": "watching",
      "successfulCycles": 4,
      "conflicts": [
       {
        "root": "org/z/c/3.0/c-3.0.jar",
        "alphaChanges": [
         {
          "path": "org/z/c/3.0/c-3.0.jar",
          "old": null,
          "new": {
           "kind": "file",
           "digest": "8ae2493ac0b6df3fb9fa73d6f7be121fd597f30b"
          }
         }
        ],
        "betaChanges": [
         {
          "path": "org/z/c/3.0/c-3.0.jar",
          "old": null,
          "new": {
           "kind": "file",
           "digest": "7821919a6468b8341802b1c12210930264a362f6"
          }
         }
        ]
       }
      ]
     },
     {
      "identifier": "sync_fwkHbFL5DtmRvFFr9WT0RhWVNMnyfvDXgL5kuu00R0U",
      "version": 1,
      "creationTime": "2026-10-23T12:08:39.137415Z",
      "creatingVersion": "0.18.1",
      "alpha": {
       "protocol": "ssh",
       "host": "p4linux",
       "path": ".m2/repository",
       "ignore": {},
       "symlink": {},
       "watch": {},
       "permissions": {},
       "compression": {},
       "connected": true,
       "scanned": true,
       "directories": 8056,
       "files": 26616,
       "totalFileSize": 2725834603
      },
      "beta": {
       "protocol": "local",
       "path": "/STATE/m2/p4linux/repository",
       "ignore": {},
       "symlink": {},
       "watch": {},
       "permissions": {},
       "compression": {},
       "connected": true,
       "scanned": true,
       "transitionProblems": [
        {
         "path": "",
         "error": "unable to walk to transition root parent: unable to open synchronization root parent directory: no such file or directory"
        }
       ]
      },
      "mode": "one-way-safe",
      "ignore": {},
      "symlink": {},
      "watch": {},
      "permissions": {},
      "compression": {},
      "name": "probe-realm2",
      "labels": {
       "agterm-kind": "m2",
       "agterm-probe": "1"
      },
      "paused": false,
      "status": "staging-beta",
      "successfulCycles": 26
     }
    ]
    """
}
