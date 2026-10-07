import Foundation
import Testing
@testable import agtermCore

struct RebasedInstallTests {
    private let bundle = "/Applications/Rebased Test.app"
    private let state = "/tmp/agterm-test"
    private let productPath = "/Applications/Rebased Test.app/Contents/Resources/product-info.json"
    private let optionsPath = "/Applications/Rebased Test.app/Contents/bin/rebased.vmoptions"
    private let releasePath = "/Applications/Rebased Test.app/Contents/jbr/Contents/Home/release"

    private var product: String {
        """
        {
          "buildNumber": "262.10968.SNAPSHOT",
          "minRequiredJavaVersion": 25,
          "launch": [
            {"os": "Linux", "arch": "amd64", "mainClass": "wrong.Main",
             "bootClassPathJarNames": ["wrong.jar"], "additionalJvmArguments": ["-Dwrong=true"]},
            {"os": "macOS", "arch": "aarch64", "mainClass": "com.intellij.idea.Main",
             "bootClassPathJarNames": ["platform-loader.jar", "util.jar"],
             "additionalJvmArguments": ["-Didea.home.path=$APP_PACKAGE/Contents", "-Didea.config.path=standalone"],
             "customCommands": [{"commands": ["inspect"], "additionalJvmArguments": ["-Dwrong=custom"]}]}
          ]
        }
        """
    }

    private func install(product: String? = nil, release: String = "JAVA_VERSION=\"25.0.4\"\n") throws -> RebasedInstall {
        try RebasedInstall(bundlePath: bundle, stateDirectory: state,
                           productInfo: .init(path: productPath, contents: product ?? self.product),
                           vmOptions: .init(path: optionsPath, contents: "# heap\n\n-Xmx2048m\n  # comment\n-Dfixture=$APP_PACKAGE/Contents\n"),
                           runtimeRelease: .init(path: releasePath, contents: release), architecture: "aarch64")
    }

    @Test func optionsFollowLauncherOrderAndOverrideStandalonePaths() throws {
        let install = try install()
        #expect(install.buildNumber == "262.10968.SNAPSHOT")
        #expect(install.mainClass == "com.intellij.idea.Main")
        #expect(install.jvmOptions == [
            "-XX:ErrorFile=\(state)/rebased/log/java_error_in_agterm_%p.log",
            "-XX:HeapDumpPath=\(state)/rebased/log/java_error_in_agterm.hprof",
            "-Xmx2048m", "-Dfixture=\(bundle)/Contents",
            "-Didea.home.path=\(bundle)/Contents", "-Didea.config.path=standalone",
            "-Djava.class.path=\(bundle)/Contents/lib/platform-loader.jar:\(bundle)/Contents/lib/util.jar",
            "-Dide.native.launcher=true", "-Dsun.java.command=com.intellij.idea.Main",
            "-Didea.config.path=\(state)/rebased/config", "-Didea.system.path=\(state)/rebased/system",
            "-Didea.plugins.path=\(state)/rebased/plugins", "-Didea.log.path=\(state)/rebased/log"
        ])
    }

    @Test func requiredJavaVersionErrorNamesBothVersions() {
        #expect(throws: RebasedInstall.InstallError.javaVersion(required: 25, runtime: "24.0.2")) {
            try install(release: "JAVA_VERSION=\"24.0.2\"\n")
        }
    }

    @Test func newerRuntimeAndEarlyAccessVersionAreAccepted() throws {
        _ = try install(release: "JAVA_VERSION=\"26-ea\"\n")
    }

    @Test func missingMacOSLaunchIsAnError() {
        #expect(throws: RebasedInstall.InstallError.missingLaunch(architecture: "aarch64")) {
            try install(product: product.replacingOccurrences(of: "macOS", with: "Windows"))
        }
    }

    @Test func wrongArchitectureDoesNotSelectAnIncompatibleLaunch() {
        #expect(throws: RebasedInstall.InstallError.missingLaunch(architecture: "aarch64")) {
            try install(product: product.replacingOccurrences(of: "aarch64", with: "x86_64"))
        }
    }

    @Test(arguments: ["product", "options", "release"])
    func missingInputNamesItsPath(missing: String) {
        let path = missing == "product" ? productPath : missing == "options" ? optionsPath : releasePath
        #expect(throws: RebasedInstall.InstallError.missingFile(path)) {
            try RebasedInstall(bundlePath: bundle, stateDirectory: state,
                               productInfo: .init(path: productPath, contents: missing == "product" ? nil : product),
                               vmOptions: .init(path: optionsPath, contents: missing == "options" ? nil : "-Xmx2048m"),
                               runtimeRelease: .init(path: releasePath, contents: missing == "release" ? nil : "JAVA_VERSION=\"25.0.4\""),
                               architecture: "aarch64")
        }
    }

    @Test func invalidReleaseNamesTheFile() {
        #expect(throws: RebasedInstall.InstallError.invalidFile(releasePath, "missing or invalid JAVA_VERSION")) {
            try install(release: "IMPLEMENTOR=\"JetBrains\"")
        }
    }

    @Test func invalidProductNamesTheFile() {
        do {
            _ = try install(product: "{")
            Issue.record("invalid JSON must fail")
        } catch {
            #expect(error.localizedDescription.contains(productPath))
        }
    }

    @Test func cacheKeyDependsOnBothInputsWithoutSeparatorCollisions() {
        let key = RebasedInstall.pluginCacheKey(buildNumber: "262", sourceDigest: "abc")
        #expect(key == RebasedInstall.pluginCacheKey(buildNumber: "262", sourceDigest: "abc"))
        #expect(key != RebasedInstall.pluginCacheKey(buildNumber: "263", sourceDigest: "abc"))
        #expect(key != RebasedInstall.pluginCacheKey(buildNumber: "262", sourceDigest: "def"))
        #expect(RebasedInstall.pluginCacheKey(buildNumber: "a:b", sourceDigest: "c")
                != RebasedInstall.pluginCacheKey(buildNumber: "a", sourceDigest: "b:c"))
    }
}
