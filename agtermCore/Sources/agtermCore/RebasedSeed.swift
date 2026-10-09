import Foundation

public enum RebasedSeed {
    public struct Plan: Sendable {
        let root: URL
        let copies: [Copy]
        let vmOptions: String
    }

    struct Copy: Sendable {
        let source: URL
        let destination: String
    }

    private static let configEntries = ["options", "keymaps", "codestyles", "templates", "inspection", "ssl",
                                        "idea.key", "early-access-registry.txt", "tbe"]
    private static let pluginEntries = ["IdeaVIM", "tbe-intellij-plugin", "claude-remarks"]
    private static let leanOptions = """
    -Xms128m
    -Xmx1g
    -XX:ReservedCodeCacheSize=240m
    -Didea.load.plugins.id=com.intellij.java,org.jetbrains.idea.maven,Git4Idea,IdeaVIM,org.jetbrains.toolbox-enterprise-client,agterm.rebased.bridge,dev.sasha.clauderemarks,org.intellij.plugins.markdown

    """

    public static func plan(product: RebasedProduct, stateDirectory: URL,
                            homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) throws -> Plan? {
        let manager = FileManager.default
        let root = product.ideRoot(stateDirectory: stateDirectory)
        guard product.name.hasPrefix("IntelliJ IDEA"), !manager.fileExists(atPath: root.path) else { return nil }
        let source = homeDirectory.appendingPathComponent("Library/Application Support/JetBrains", isDirectory: true)
            .appendingPathComponent(product.dataDirectoryName, isDirectory: true)
        let config = configEntries.map { Copy(source: source.appendingPathComponent($0), destination: "config/\($0)") }
        let plugins = pluginEntries.map { Copy(source: source.appendingPathComponent("plugins/\($0)"), destination: "plugins/\($0)") }
        let copies = (config + plugins).filter { manager.fileExists(atPath: $0.source.path) }
        let optionsFile = source.appendingPathComponent("idea.vmoptions")
        let standalone = manager.fileExists(atPath: optionsFile.path) ? try String(contentsOf: optionsFile, encoding: .utf8) : ""
        let separator = standalone.isEmpty || standalone.hasSuffix("\n") ? "" : "\n"
        return Plan(root: root, copies: copies, vmOptions: standalone + separator + leanOptions)
    }

    /// The caller holds `RebasedStateLock` through planning and execution.
    public static func execute(_ plan: Plan) throws {
        let manager = FileManager.default
        let parent = plan.root.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let prefix = ".\(plan.root.lastPathComponent)-seed-"
        for entry in try manager.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) where entry.lastPathComponent.hasPrefix(prefix) {
            try manager.removeItem(at: entry)
        }
        guard !manager.fileExists(atPath: plan.root.path) else { return }
        let staging = parent.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        try manager.createDirectory(at: staging.appendingPathComponent("config"), withIntermediateDirectories: false)
        for copy in plan.copies {
            let destination = staging.appendingPathComponent(copy.destination)
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.copyItem(at: copy.source, to: destination)
            try removeLinks(at: destination)
        }
        try plan.vmOptions.write(to: staging.appendingPathComponent("config/idea.vmoptions"), atomically: true, encoding: .utf8)
        try manager.moveItem(at: staging, to: plan.root)
    }

    // A copied link would let the embedded IDE write through to the standalone config.
    private static func removeLinks(at url: URL) throws {
        let manager = FileManager.default
        func isLink(_ item: URL) -> Bool { (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true }
        if isLink(url) { return try manager.removeItem(at: url) }
        let links = (manager.enumerator(at: url, includingPropertiesForKeys: [.isSymbolicLinkKey])?.allObjects ?? [])
            .compactMap { $0 as? URL }.filter(isLink)
        for link in links { try manager.removeItem(at: link) }
    }
}
