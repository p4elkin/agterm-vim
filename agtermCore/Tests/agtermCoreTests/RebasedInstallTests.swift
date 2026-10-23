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
          "name": "Rebased", "dataDirectoryName": "IdeaIC1.1", "productCode": "IC",
          "buildNumber": "262.10968.SNAPSHOT",
          "minRequiredJavaVersion": 25,
          "launch": [
            {"os": "Linux", "arch": "amd64", "mainClass": "wrong.Main",
             "vmOptionsFilePath": "../bin/wrong.vmoptions",
             "bootClassPathJarNames": ["wrong.jar"], "additionalJvmArguments": ["-Dwrong=true"]},
            {"os": "macOS", "arch": "aarch64", "mainClass": "com.intellij.idea.Main",
             "vmOptionsFilePath": "../bin/rebased.vmoptions",
             "bootClassPathJarNames": ["platform-loader.jar", "util.jar"],
             "additionalJvmArguments": ["-Didea.home.path=$APP_PACKAGE/Contents", "-Didea.config.path=standalone"],
             "customCommands": [{"commands": ["inspect"], "additionalJvmArguments": ["-Dwrong=custom"]}]}
          ]
        }
        """
    }

    private func install(product: String? = nil, release: String = "JAVA_VERSION=\"25.0.4\"\n",
                         agtermVmOptions: String? = nil) throws -> RebasedInstall {
        try RebasedInstall(bundlePath: bundle, stateDirectory: state,
                           product: RebasedProduct(bundlePath: bundle, productInfo: .init(path: productPath, contents: product ?? self.product),
                                                   architecture: "aarch64"),
                           vmOptions: .init(path: optionsPath, contents: "# heap\n\n-Xmx2048m\n  # comment\n-Dfixture=$APP_PACKAGE/Contents\n-Dhome=$USER_HOME/x\n"),
                           agtermVmOptions: agtermVmOptions, runtimeRelease: .init(path: releasePath, contents: release),
                           homeDirectory: "/Users/tester")
    }

    @Test func optionsFollowLauncherOrderAndOverrideStandalonePaths() throws {
        let install = try install(agtermVmOptions: "# tuning\n-Xmx1g\n-XX:ErrorFile=standalone\n-XX:HeapDumpPath=standalone\n"
                                  + "-Didea.config.path=user\n-Djava.class.path=user\n-Dide.native.launcher=false\n"
                                  + "-DjbScreenMenuBar.enabled=true\n-Dapple.laf.useScreenMenuBar=true\n")
        #expect(install.buildNumber == "262.10968.SNAPSHOT")
        #expect(install.mainClass == "com.intellij.idea.Main")
        #expect(install.jvmOptions == [
            "-Xmx2048m", "-Dfixture=\(bundle)/Contents", "-Dhome=/Users/tester/x",
            "-Didea.home.path=\(bundle)/Contents", "-Didea.config.path=standalone",
            "-Xmx1g", "-XX:ErrorFile=standalone", "-XX:HeapDumpPath=standalone",
            "-Didea.config.path=user", "-Djava.class.path=user", "-Dide.native.launcher=false",
            "-DjbScreenMenuBar.enabled=true", "-Dapple.laf.useScreenMenuBar=true",
            "-XX:ErrorFile=\(state)/rebased/log/java_error_in_agterm_%p.log",
            "-XX:HeapDumpPath=\(state)/rebased/log/java_error_in_agterm.hprof",
            "-Djava.class.path=\(bundle)/Contents/lib/platform-loader.jar:\(bundle)/Contents/lib/util.jar",
            "-Didea.config.path=\(state)/rebased/config", "-Didea.system.path=\(state)/rebased/system",
            "-Didea.plugins.path=\(state)/rebased/plugins", "-Didea.log.path=\(state)/rebased/log",
            "-Dide.native.launcher=true", "-Dsun.java.command=com.intellij.idea.Main",
            "-DjbScreenMenuBar.enabled=false", "-Dapple.laf.useScreenMenuBar=false"
        ])
    }

    @Test func ideaUsesItsLaunchOptionsPathAndProductRoot() throws {
        let text = product.replacingOccurrences(of: "\"Rebased\"", with: "\"IntelliJ IDEA\"")
            .replacingOccurrences(of: "IdeaIC1.1", with: "IntelliJIdea2026.2")
            .replacingOccurrences(of: "../bin/rebased.vmoptions", with: "../bin/idea.vmoptions")
        let metadata = try RebasedProduct(bundlePath: bundle, productInfo: .init(path: productPath, contents: text), architecture: "aarch64")
        #expect(metadata.name == "IntelliJ IDEA")
        #expect(metadata.vmOptionsPath == "\(bundle)/Contents/bin/idea.vmoptions")
        #expect(metadata.ideRoot(stateDirectory: URL(fileURLWithPath: state)).path == "\(state)/rebased/ide/IntelliJIdea2026.2")
        #expect(try install(product: text).jvmOptions.contains("-Didea.system.path=\(state)/rebased/ide/IntelliJIdea2026.2/system"))
    }

    @Test func rebasedNameKeepsLegacyRootRegardlessOfProductCode() throws {
        let text = product.replacingOccurrences(of: "\"IC\"", with: "\"IU\"")
        let metadata = try RebasedProduct(bundlePath: bundle, productInfo: .init(path: productPath, contents: text), architecture: "aarch64")
        #expect(metadata.ideRoot(stateDirectory: URL(fileURLWithPath: state)).path == "\(state)/rebased")
    }

    @Test(arguments: ["", ".", "..", "one/two", "/absolute"])
    func invalidDataDirectoryNameIsRefused(name: String) {
        #expect(throws: RebasedInstall.InstallError.invalidFile(productPath, "dataDirectoryName must be a single path component")) {
            try install(product: product.replacingOccurrences(of: "IdeaIC1.1", with: name))
        }
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
