import Foundation
import Testing
@testable import agtermCore

struct RebasedSeedTests {
    private let manager = FileManager.default
    private let dataName = "IntelliJIdea2026.2"
    private let leanOptions = """
    -Xms128m
    -Xmx1g
    -XX:ReservedCodeCacheSize=240m
    -Didea.load.plugins.id=com.intellij.java,org.jetbrains.idea.maven,Git4Idea,IdeaVIM,org.jetbrains.toolbox-enterprise-client,agterm.rebased.bridge,dev.sasha.clauderemarks,org.intellij.plugins.markdown

    """

    private func temporaryDirectory() throws -> URL {
        let root = manager.temporaryDirectory.appendingPathComponent("rebased-seed-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func product(name: String = "IntelliJ IDEA") throws -> RebasedProduct {
        let text = """
        {"name":"\(name)","dataDirectoryName":"\(dataName)","buildNumber":"262","minRequiredJavaVersion":25,
         "launch":[{"os":"macOS","arch":"aarch64","mainClass":"com.intellij.idea.Main",
          "vmOptionsFilePath":"../bin/idea.vmoptions","bootClassPathJarNames":[],"additionalJvmArguments":[]}]}
        """
        return try RebasedProduct(bundlePath: "/Applications/IntelliJ IDEA.app", productInfo: .init(path: "product-info.json", contents: text),
                                  architecture: "aarch64")
    }

    private func source(_ home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/JetBrains/\(dataName)")
    }

    private func write(_ text: String, to file: URL) throws {
        try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    @Test func copiesOnlyApprovedConfigAndPlugins() throws {
        let root = try temporaryDirectory()
        defer { try? manager.removeItem(at: root) }
        let home = root.appendingPathComponent("home"), state = root.appendingPathComponent("state")
        let directories = ["options", "keymaps", "codestyles", "templates", "inspection", "ssl", "tbe"]
        for name in directories { try write(name, to: source(home).appendingPathComponent("\(name)/fixture")) }
        for name in ["idea.key", "early-access-registry.txt", "other.txt"] { try write(name, to: source(home).appendingPathComponent(name)) }
        for name in ["IdeaVIM", "tbe-intellij-plugin", "claude-remarks", "other-plugin"] {
            try write(name, to: source(home).appendingPathComponent("plugins/\(name)/fixture"))
        }
        let plan = try #require(try RebasedSeed.plan(product: product(), stateDirectory: state, homeDirectory: home))
        try RebasedSeed.execute(plan)
        let ideRoot = try product().ideRoot(stateDirectory: state)
        #expect(try manager.contentsOfDirectory(atPath: ideRoot.appendingPathComponent("config").path).sorted()
                == (directories + ["idea.key", "early-access-registry.txt", "idea.vmoptions"]).sorted())
        #expect(try manager.contentsOfDirectory(atPath: ideRoot.appendingPathComponent("plugins").path).sorted()
                == ["IdeaVIM", "claude-remarks", "tbe-intellij-plugin"])
        #expect(try String(contentsOf: ideRoot.appendingPathComponent("config/options/fixture"), encoding: .utf8) == "options")
    }

    @Test func neverCopiesCredentialFiles() throws {
        let root = try temporaryDirectory()
        defer { try? manager.removeItem(at: root) }
        let home = root.appendingPathComponent("home"), state = root.appendingPathComponent("state")
        for name in ["c.kdbx", "c.pwd"] { try write("credential fixture", to: source(home).appendingPathComponent(name)) }
        let plan = try #require(try RebasedSeed.plan(product: product(), stateDirectory: state, homeDirectory: home))
        try RebasedSeed.execute(plan)
        let config = try product().ideRoot(stateDirectory: state).appendingPathComponent("config")
        #expect(try manager.contentsOfDirectory(atPath: config.path) == ["idea.vmoptions"])
    }

    @Test func copiesNoSymbolicLinks() throws {
        let root = try temporaryDirectory()
        defer { try? manager.removeItem(at: root) }
        let home = root.appendingPathComponent("home"), state = root.appendingPathComponent("state")
        let outside = root.appendingPathComponent("standalone-keymaps")
        try write("outside", to: outside.appendingPathComponent("fixture"))
        try manager.createDirectory(at: source(home), withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: source(home).appendingPathComponent("keymaps"), withDestinationURL: outside)
        try write("options", to: source(home).appendingPathComponent("options/fixture"))
        try manager.createSymbolicLink(at: source(home).appendingPathComponent("options/linked"), withDestinationURL: outside)
        let plan = try #require(try RebasedSeed.plan(product: product(), stateDirectory: state, homeDirectory: home))
        try RebasedSeed.execute(plan)
        let config = try product().ideRoot(stateDirectory: state).appendingPathComponent("config")
        #expect(try manager.contentsOfDirectory(atPath: config.path).sorted() == ["idea.vmoptions", "options"])
        #expect(try manager.contentsOfDirectory(atPath: config.appendingPathComponent("options").path) == ["fixture"])
    }

    @Test func missingSourceWritesOnlyLeanVmOptions() throws {
        let root = try temporaryDirectory()
        defer { try? manager.removeItem(at: root) }
        let state = root.appendingPathComponent("state")
        let plan = try #require(try RebasedSeed.plan(product: product(), stateDirectory: state, homeDirectory: root.appendingPathComponent("missing")))
        try RebasedSeed.execute(plan)
        let ideRoot = try product().ideRoot(stateDirectory: state)
        #expect(try manager.contentsOfDirectory(atPath: ideRoot.path) == ["config"])
        #expect(try String(contentsOf: ideRoot.appendingPathComponent("config/idea.vmoptions"), encoding: .utf8) == leanOptions)
    }

    @Test(arguments: ["-Xmx4g\n-Djetbrains.tbe.enabled=true\n", "-Xmx4g"])
    func standaloneOptionsPrecedeLeanBlock(standalone: String) throws {
        let root = try temporaryDirectory()
        defer { try? manager.removeItem(at: root) }
        let home = root.appendingPathComponent("home"), state = root.appendingPathComponent("state")
        try write(standalone, to: source(home).appendingPathComponent("idea.vmoptions"))
        let plan = try #require(try RebasedSeed.plan(product: product(), stateDirectory: state, homeDirectory: home))
        try RebasedSeed.execute(plan)
        let file = try product().ideRoot(stateDirectory: state).appendingPathComponent("config/idea.vmoptions")
        #expect(try String(contentsOf: file, encoding: .utf8) == standalone + (standalone.hasSuffix("\n") ? "" : "\n") + leanOptions)
    }

    @Test(arguments: ["Rebased", "Other IDE"])
    func otherProductsHaveNoSeed(name: String) throws {
        let root = try temporaryDirectory()
        defer { try? manager.removeItem(at: root) }
        let plan = try RebasedSeed.plan(product: product(name: name), stateDirectory: root.appendingPathComponent("state"), homeDirectory: root)
        #expect(plan == nil)
        #expect(try manager.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func existingRootAndEditedOptionsAreLeftAlone() throws {
        let root = try temporaryDirectory()
        defer { try? manager.removeItem(at: root) }
        let home = root.appendingPathComponent("home"), state = root.appendingPathComponent("state")
        let file = try product().ideRoot(stateDirectory: state).appendingPathComponent("config/idea.vmoptions")
        try write("-Xmx2g\n", to: file)
        try write("standalone config", to: source(home).appendingPathComponent("options/fixture"))
        #expect(try RebasedSeed.plan(product: product(), stateDirectory: state, homeDirectory: home) == nil)
        #expect(try String(contentsOf: file, encoding: .utf8) == "-Xmx2g\n")
        #expect(!manager.fileExists(atPath: file.deletingLastPathComponent().appendingPathComponent("options").path))
    }

    @Test func failedCopyLeavesNoRootOrStagingAndCanRetry() throws {
        let root = try temporaryDirectory()
        defer { try? manager.removeItem(at: root) }
        let home = root.appendingPathComponent("home"), state = root.appendingPathComponent("state")
        let options = source(home).appendingPathComponent("options")
        try write("settings", to: options.appendingPathComponent("fixture"))
        let plan = try #require(try RebasedSeed.plan(product: product(), stateDirectory: state, homeDirectory: home))
        try manager.removeItem(at: options)
        #expect(throws: (any Error).self) { try RebasedSeed.execute(plan) }
        let ideRoot = try product().ideRoot(stateDirectory: state)
        #expect(!manager.fileExists(atPath: ideRoot.path))
        #expect(try manager.contentsOfDirectory(atPath: ideRoot.deletingLastPathComponent().path).isEmpty)
        try write("retry settings", to: options.appendingPathComponent("fixture"))
        let retry = try #require(try RebasedSeed.plan(product: product(), stateDirectory: state, homeDirectory: home))
        try RebasedSeed.execute(retry)
        #expect(try String(contentsOf: ideRoot.appendingPathComponent("config/options/fixture"), encoding: .utf8) == "retry settings")
    }

    @Test func removesStaleStagingOnlyForThisProduct() throws {
        let root = try temporaryDirectory()
        defer { try? manager.removeItem(at: root) }
        let state = root.appendingPathComponent("state"), home = root.appendingPathComponent("home")
        let parent = try product().ideRoot(stateDirectory: state).deletingLastPathComponent()
        let stale = parent.appendingPathComponent(".\(dataName)-seed-old")
        let other = parent.appendingPathComponent(".OtherIDE-seed-old")
        try write("partial config", to: stale.appendingPathComponent("config/options/fixture"))
        try write("other product", to: other.appendingPathComponent("fixture"))
        let plan = try #require(try RebasedSeed.plan(product: product(), stateDirectory: state, homeDirectory: home))
        try RebasedSeed.execute(plan)
        #expect(!manager.fileExists(atPath: stale.path))
        #expect(manager.fileExists(atPath: other.path))
        #expect(try manager.contentsOfDirectory(atPath: parent.path).sorted() == [".OtherIDE-seed-old", dataName])
    }
}
