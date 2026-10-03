import ArgumentParser
import Foundation
import Testing
import agtermCore
@testable import agtermctlKit

struct MiscCommandsTests {
    @Test func keymapRunSendsTheNameWithItsTargetAndWindow() throws {
        let plain = try Keymap.Run.parse(["lazy git"]).makeRequest()
        #expect(plain.cmd == .keymapRun)
        #expect(plain.args?.name == "lazy git")

        let targeted = try Keymap.Run.parse(["Zed", "--target", "s1", "--window", "w1"]).makeRequest()
        #expect(targeted.target == "s1")
        #expect(targeted.args?.window == "w1")
        #expect(throws: (any Error).self) { try Keymap.Run.parse([]) }
    }
}
