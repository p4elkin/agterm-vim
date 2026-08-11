import Foundation
import Testing
@testable import agtermCore

struct ZmxSocketBudgetTests {
    /// The longest key a pane can produce: a 36-character uuid, a dash, and `right`.
    private let worstCaseKey = 42
    /// The live machine's directory: `/var/folders/<2>/<28>/T/zmx-501`, 56 bytes.
    private let realTmp = "/var/folders/cf/v4dl10nn2c3g0l4l8qnmr8fc0000gn/T/"

    @Test func zmxDirWinsVerbatim() {
        let dir = ZmxSocketBudget.socketDir(env: ["ZMX_DIR": "/tmp/pinned", "TMPDIR": "/var/t/"], uid: 501)
        #expect(dir == "/tmp/pinned")
    }

    @Test func fallsBackThroughXdgRuntimeDirThenTmpdirThenTmp() {
        #expect(ZmxSocketBudget.socketDir(env: ["XDG_RUNTIME_DIR": "/run/user/501", "TMPDIR": "/var/t"], uid: 501)
                == "/run/user/501/zmx-501")
        #expect(ZmxSocketBudget.socketDir(env: ["TMPDIR": "/var/t"], uid: 501) == "/var/t/zmx-501")
        #expect(ZmxSocketBudget.socketDir(env: [:], uid: 501) == "/tmp/zmx-501")
    }

    @Test func emptyValuesFallThrough() {
        #expect(ZmxSocketBudget.socketDir(env: ["ZMX_DIR": "", "TMPDIR": "/var/t"], uid: 7) == "/var/t/zmx-7")
        #expect(ZmxSocketBudget.socketDir(env: ["ZMX_DIR": "", "XDG_RUNTIME_DIR": "", "TMPDIR": ""], uid: 7)
                == "/tmp/zmx-7")
    }

    @Test func trailingSlashTrimmed() {
        // TMPDIR on macOS always ends in a slash, so an untrimmed join would bind under `…T//zmx-501`.
        #expect(ZmxSocketBudget.socketDir(env: ["TMPDIR": realTmp], uid: 501) == realTmp + "zmx-501")
        #expect(ZmxSocketBudget.socketDir(env: ["ZMX_DIR": "/tmp/pinned///"], uid: 501) == "/tmp/pinned")
        #expect(ZmxSocketBudget.socketDir(env: ["TMPDIR": "/"], uid: 501) == "/zmx-501")
    }

    /// ⚠️ The live machine has two spare bytes and no more. Anything that lengthens the directory, the key or
    /// the safety margin silently unwraps every pane, so this pins the pair rather than the constants.
    @Test func realSetupIsUnderBudget() {
        let dir = ZmxSocketBudget.socketDir(env: ["TMPDIR": realTmp], uid: 501)
        #expect(dir.utf8.count == 56)
        #expect(ZmxSessionKey.maxByteCount == worstCaseKey)
        #expect(ZmxSocketBudget.probe(env: ["TMPDIR": realTmp], keyByteCount: worstCaseKey, uid: 501) == nil)
        #expect(dir.utf8.count + 1 + worstCaseKey == ZmxSocketBudget.maxPathByteCount - 2)
    }

    @Test func longZmxDirIsOverBudget() {
        let long = "/tmp/" + String(repeating: "d", count: 80)
        let reason = ZmxSocketBudget.probe(env: ["ZMX_DIR": long], keyByteCount: worstCaseKey, uid: 501)
        #expect(reason != nil)
        #expect(reason?.contains(long) == true)
        #expect(reason?.contains("128 bytes") == true)
        #expect(reason?.contains("101-byte budget") == true)
    }

    @Test func boundaryPathFitsAndOneMoreByteDoesNot() {
        // budget 101 = the directory, the separator, and the key.
        let fitting = "/" + String(repeating: "d", count: ZmxSocketBudget.maxPathByteCount - worstCaseKey - 2)
        #expect(ZmxSocketBudget.probe(env: ["ZMX_DIR": fitting], keyByteCount: worstCaseKey, uid: 501) == nil)
        #expect(ZmxSocketBudget.probe(env: ["ZMX_DIR": fitting + "d"], keyByteCount: worstCaseKey, uid: 501) != nil)
    }

    @Test func rootDirectoryCountsNoDoubleSeparator() {
        #expect(ZmxSocketBudget.probe(env: ["ZMX_DIR": "/"], keyByteCount: worstCaseKey, uid: 501) == nil)
        let reason = ZmxSocketBudget.probe(env: ["ZMX_DIR": "/"], keyByteCount: ZmxSocketBudget.maxPathByteCount,
                                          uid: 501)
        #expect(reason?.contains("\(ZmxSocketBudget.maxPathByteCount + 1) bytes") == true)
    }

    @Test func budgetLeavesRoomForTheNulTerminator() {
        #expect(ZmxSocketBudget.maxPathByteCount < ZmxSocketBudget.sunPathByteLimit)
        #expect(ZmxSocketBudget.maxPathByteCount == 101)
    }

    @Test func pathIsMeasuredInBytesNotCharacters() {
        // a multi-byte directory name eats budget per byte; 40 é are 80 bytes.
        let accented = "/tmp/" + String(repeating: "é", count: 40)
        #expect(accented.count == 45)
        let reason = ZmxSocketBudget.probe(env: ["ZMX_DIR": accented], keyByteCount: worstCaseKey, uid: 501)
        #expect(reason?.contains("128 bytes") == true)
    }
}
