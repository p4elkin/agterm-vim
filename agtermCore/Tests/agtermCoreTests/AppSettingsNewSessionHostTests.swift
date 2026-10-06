import Foundation
import Testing
@testable import agtermCore

struct AppSettingsNewSessionHostTests {
    @Test func roundTripsAndDefaultsToNil() throws {
        let settings = AppSettings(newSessionHost: "p4linux")
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.newSessionHost == "p4linux")
        #expect(AppSettings().newSessionHost == nil)
    }

    @Test(arguments: [nil, "", "   ", "p4 linux", "p4linux\u{7}", "-oProxyCommand=x", "  -p4linux "])
    func unusableHostIsNil(_ host: String?) {
        #expect(AppSettings(newSessionHost: host).effectiveNewSessionHost == nil)
    }

    @Test func usableHostIsTrimmed() {
        #expect(AppSettings(newSessionHost: "  sasha@p4linux \n").effectiveNewSessionHost == "sasha@p4linux")
    }
}
