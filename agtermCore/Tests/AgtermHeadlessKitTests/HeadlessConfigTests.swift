import Foundation
import Testing
import agtermCore
import AgtermHeadlessKit

struct HeadlessConfigTests {
    @Test func environmentOverridesStateAndZmx() {
        let config = HeadlessConfig.fromEnvironment([
            "AGTERM_HEADLESS_STATE": "/tmp/headless-config-test",
            "AGTERM_HEADLESS_ZMX": "/tmp/headless-config-test/fake-zmx",
        ])

        #expect(config.stateDirectory == "/tmp/headless-config-test")
        #expect(config.zmxExecutable == "/tmp/headless-config-test/fake-zmx")
        #expect(config.zmxDirectory == "/tmp/headless-config-test/zmx")
        #expect(config.endpoint == ControlZmxEndpoint(executable: config.zmxExecutable, socketDirectory: config.zmxDirectory))
    }

    @Test(arguments: ["/tmp/headless-config-test", "/tmp/headless-config-test/"])
    func socketUsesTheControlResolver(_ stateDirectory: String) {
        let config = HeadlessConfig.fromEnvironment(["AGTERM_HEADLESS_STATE": stateDirectory])

        #expect(config.socketPath == ControlResolve.socketPath(stateDir: stateDirectory, appSupport: ""))
    }

    @Test func emptyEnvironmentUsesHomeDefaults() {
        let config = HeadlessConfig.fromEnvironment([:])
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        #expect(config.stateDirectory == home + "/.local/state/agterm-headless")
        #expect(config.zmxExecutable == home + "/.local/opt/agterm-headless/zmx")
    }

    @Test func theLocaleIsTheServersLangAndLcVariablesOnly() {
        let config = HeadlessConfig.fromEnvironment(["LANG": "en_US.UTF-8", "LC_CTYPE": "C.UTF-8", "LANGUAGE": "en", "PATH": "/bin"])

        #expect(config.locale == ["LANG": "en_US.UTF-8", "LC_CTYPE": "C.UTF-8"])
    }

    @Test func thePageHostAndPortComeFromTheEnvironment() {
        let config = HeadlessConfig.fromEnvironment(["AGTERM_HEADLESS_PAGE_HOST": "p4linux.example.ts.net",
                                                     "AGTERM_HEADLESS_PAGE_PORT": "19600"])

        #expect(config.pageHost == "p4linux.example.ts.net")
        #expect(config.pagePort == 19600)
    }

    @Test(arguments: [[:], ["AGTERM_HEADLESS_PAGE_HOST": "", "AGTERM_HEADLESS_PAGE_PORT": "not-a-port"]])
    func noPageHostAndAnUnreadablePortFallBack(_ env: [String: String]) {
        let config = HeadlessConfig.fromEnvironment(env)

        #expect(config.pageHost == nil)
        #expect(config.pagePort == HeadlessConfig.defaultPagePort)
    }
}
