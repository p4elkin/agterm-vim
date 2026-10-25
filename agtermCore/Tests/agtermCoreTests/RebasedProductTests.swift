import Foundation
import Testing
@testable import agtermCore

struct RebasedProductTests {
    private static let ideaInfo = "/Applications/IntelliJ IDEA.app/Contents/Resources/product-info.json"
    private static let rebasedInfo = "/Applications/Rebased.app/Contents/Resources/product-info.json"

    private func product(layout: String?) throws -> RebasedProduct {
        let text = """
        {"name": "IntelliJ IDEA", "dataDirectoryName": "IntelliJIdea2026.2", "buildNumber": "262.1",
         "minRequiredJavaVersion": 25,
         "launch": [{"os": "macOS", "arch": "aarch64", "mainClass": "com.intellij.idea.Main",
                     "vmOptionsFilePath": "../bin/idea.vmoptions", "bootClassPathJarNames": [], "additionalJvmArguments": []}]
         \(layout.map { ", \"layout\": \($0)" } ?? "")}
        """
        return try RebasedProduct(bundlePath: "/Applications/Test.app", productInfo: .init(path: "/p", contents: text),
                                  architecture: "aarch64")
    }

    @Test func pluginLayoutEntriesGiveTheirClassPaths() throws {
        let product = try product(layout: """
        [{"name": "org.jetbrains.idea.maven", "kind": "plugin", "classPath": ["plugins/maven-plugin/lib/a.jar", "plugins/maven-plugin/lib/b.jar"]},
         {"name": "intellij.maven", "kind": "moduleV2", "classPath": ["plugins/maven-plugin/lib/modules/m.jar"]},
         {"name": "com.intellij.marketplace", "kind": "pluginAlias"},
         {"name": "com.intellij.java", "kind": "plugin", "classPath": ["plugins/java/lib/java-impl.jar"]}]
        """)
        #expect(product.pluginClassPaths == [
            "org.jetbrains.idea.maven": ["plugins/maven-plugin/lib/a.jar", "plugins/maven-plugin/lib/b.jar"],
            "com.intellij.java": ["plugins/java/lib/java-impl.jar"],
        ])
    }

    @Test func aProductWithoutALayoutHasNoPluginClassPaths() throws {
        #expect(try product(layout: nil).pluginClassPaths.isEmpty)
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: ideaInfo)))
    func installedIdeaNamesItsMavenPluginUnderMavenPlugin() throws {
        let product = try RebasedProduct(bundlePath: "/Applications/IntelliJ IDEA.app",
                                         productInfo: .init(path: Self.ideaInfo, contents: String(contentsOfFile: Self.ideaInfo, encoding: .utf8)))
        let maven = try #require(product.pluginClassPaths["org.jetbrains.idea.maven"])
        #expect(!maven.isEmpty)
        #expect(maven.allSatisfy { $0.hasPrefix("plugins/maven-plugin/lib/") })
        #expect(product.pluginClassPaths["com.intellij.java"]?.isEmpty == false)
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: rebasedInfo)))
    func installedRebasedHasNoMavenPlugin() throws {
        let product = try RebasedProduct(bundlePath: "/Applications/Rebased.app",
                                         productInfo: .init(path: Self.rebasedInfo, contents: String(contentsOfFile: Self.rebasedInfo, encoding: .utf8)))
        #expect(product.pluginClassPaths["org.jetbrains.idea.maven"] == nil)
    }
}
