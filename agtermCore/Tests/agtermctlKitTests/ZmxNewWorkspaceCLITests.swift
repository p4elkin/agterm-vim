import Foundation
import Testing
@testable import agtermctlKit
import agtermCore

struct ZmxNewWorkspaceCLITests {
    @Test func newCarriesTheWorkspace() throws {
        let request = try Zmx.New.parse(["p4linux", "--workspace", "5FDA"]).makeRequest()

        #expect(request.args?.host == "p4linux")
        #expect(request.args?.workspace == "5FDA")
        #expect(try JSONDecoder().decode(ControlRequest.self, from: JSONEncoder().encode(request)) == request)
    }

    @Test func newWithoutAWorkspaceSendsNone() throws {
        #expect(try Zmx.New.parse(["p4linux"]).makeRequest().args?.workspace == nil)
    }
}
