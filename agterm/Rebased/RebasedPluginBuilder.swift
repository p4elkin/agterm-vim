import CryptoKit
import Foundation
import agtermCore
import os

private let builderLogger = Logger(subsystem: "com.umputun.agterm", category: "RebasedPluginBuilder")

struct RebasedPluginBuilder: Sendable {
    struct BuildResult: Sendable {
        let jar: URL
        let key: String
        let rebuilt: Bool
    }

    enum BuildError: Error, LocalizedError {
        case missingSource(String)
        case toolFailed(String, Int32, String)

        var errorDescription: String? {
            switch self {
            case .missingSource(let path): "Rebased bridge source is missing: \(path)"
            case let .toolFailed(tool, status, stderr): "Rebased plugin \(tool) failed (\(status)): \(stderr)"
            }
        }
    }

    let appBundle: URL
    let ideRoot: URL
    var sourceDirectory: URL?
    /// `RebasedProduct.pluginClassPaths`. The optional Maven hook compiles only against a product's Maven plugin.
    var pluginClassPaths: [String: [String]] = [:]

    private static let mavenPlugin = "org.jetbrains.idea.maven"
    private static let mavenDepends = #"<depends optional="true" config-file="agterm-maven.xml">org.jetbrains.idea.maven</depends>"#

    func build(buildNumber: String) throws -> BuildResult {
        guard let source = sourceDirectory ?? Bundle.main.url(forResource: "rebased", withExtension: nil) else {
            throw BuildError.missingSource("bundled rebased folder")
        }
        let files = try sourceFiles(in: source)
        var digest = SHA256()
        for file in files {
            let data = try Data(contentsOf: file)
            let path = String(file.path.dropFirst(source.path.count))
            digest.update(data: Data("\(path.utf8.count):\(path)\(data.count):".utf8))
            digest.update(data: data)
        }
        for id in [Self.mavenPlugin, "com.intellij.java"] {
            digest.update(data: Data("\(id)=\((pluginClassPaths[id] ?? []).joined(separator: ":"));".utf8))
        }
        let key = RebasedInstall.pluginCacheKey(buildNumber: buildNumber, sourceDigest: digest.finalize().map { String(format: "%02x", $0) }.joined())
        let plugins = ideRoot.appendingPathComponent("plugins")
        let plugin = plugins.appendingPathComponent("agterm-bridge")
        let jar = plugin.appendingPathComponent("lib/agterm-bridge.jar")
        let stamp = plugin.appendingPathComponent(".build-key")
        let manager = FileManager.default
        if (try? String(contentsOf: stamp, encoding: .utf8)) == key, manager.fileExists(atPath: jar.path) {
            return BuildResult(jar: jar, key: key, rebuilt: false)
        }
        try manager.createDirectory(at: plugins, withIntermediateDirectories: true)
        let staging = plugins.appendingPathComponent(".agterm-bridge-build-\(UUID().uuidString)")
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        let classes = staging.appendingPathComponent("classes")
        try manager.createDirectory(at: classes, withIntermediateDirectories: false)
        let java = files.filter { $0.pathExtension == "java" }
        // the enumerator can return `/private/var/…` for a `/var/…` source, so no prefix test
        let isMaven = { (file: URL) in file.path.contains("/src/agterm/rebased/maven/") }
        let bridgeJava = java.filter { !isMaven($0) }
        let classpath = ["Contents/lib/*", "Contents/plugins/vcs-git/lib/*"].map { appBundle.appendingPathComponent($0).path }
        try run(javac, arguments: ["--release", "21", "-cp", classpath.joined(separator: ":"), "-d", classes.path] + bridgeJava.map(\.path),
                directory: staging, stderr: staging.appendingPathComponent("javac.stderr"))
        let meta = classes.appendingPathComponent("META-INF")
        try manager.copyItem(at: source.appendingPathComponent("res/META-INF"), to: meta)
        let withMaven = compileMaven(java.filter(isMaven), classes: classes, staging: staging)
        if withMaven {
            let descriptor = meta.appendingPathComponent("plugin.xml")
            let text = try String(contentsOf: descriptor, encoding: .utf8)
            guard let close = text.range(of: "</idea-plugin>", options: .backwards) else { throw BuildError.missingSource(descriptor.path) }
            try text.replacingCharacters(in: close, with: "  \(Self.mavenDepends)\n</idea-plugin>")
                .write(to: descriptor, atomically: true, encoding: .utf8)
        } else {
            try? manager.removeItem(at: meta.appendingPathComponent("agterm-maven.xml"))
        }
        let archive = staging.appendingPathComponent("agterm-bridge.jar")
        try run(URL(fileURLWithPath: "/usr/bin/zip"), arguments: ["-q", "-r", "-X", archive.path, "."],
                directory: classes, stderr: staging.appendingPathComponent("zip.stderr"))
        try manager.createDirectory(at: jar.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contentsOf: archive).write(to: jar, options: .atomic)
        // a failed Maven compile on a product that has Maven is stamped apart, so the next start retries it
        let retry = !withMaven && pluginClassPaths[Self.mavenPlugin]?.isEmpty == false
        try (retry ? key + "-nomaven" : key).write(to: stamp, atomically: true, encoding: .utf8)
        return BuildResult(jar: jar, key: key, rebuilt: true)
    }

    private var javac: URL { appBundle.appendingPathComponent("Contents/jbr/Contents/Home/bin/javac") }

    /// The second `javac` step; false leaves the bridge without the hook, which only Maven projects miss.
    private func compileMaven(_ java: [URL], classes: URL, staging: URL) -> Bool {
        guard !java.isEmpty, let maven = pluginClassPaths[Self.mavenPlugin], !maven.isEmpty else {
            builderLogger.info("Rebased bridge built without the Maven hook: the product has no Maven plugin")
            return false
        }
        let contents = appBundle.appendingPathComponent("Contents")
        let jars = (maven + (pluginClassPaths["com.intellij.java"] ?? [])).map { contents.appendingPathComponent($0).path }
        let output = staging.appendingPathComponent("maven-classes")
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            let classpath = [classes.path] + jars + [contents.appendingPathComponent("lib/*").path]
            try run(javac, arguments: ["--release", "21", "-cp", classpath.joined(separator: ":"), "-d", output.path] + java.map(\.path),
                    directory: staging, stderr: staging.appendingPathComponent("maven-javac.stderr"))
            try FileManager.default.copyItem(at: output.appendingPathComponent("agterm/rebased/maven"),
                                             to: classes.appendingPathComponent("agterm/rebased/maven"))
            return true
        } catch {
            builderLogger.error("Rebased bridge built without the Maven hook: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func sourceFiles(in source: URL) throws -> [URL] {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(at: source.appendingPathComponent("src"), includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw BuildError.missingSource(source.appendingPathComponent("src").path)
        }
        let java = try enumerator.compactMap { $0 as? URL }.filter { url in
            try url.pathExtension == "java" && url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        }
        let meta = source.appendingPathComponent("res/META-INF")
        guard !java.isEmpty, manager.fileExists(atPath: meta.appendingPathComponent("plugin.xml").path),
              let metaEnumerator = manager.enumerator(at: meta, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw BuildError.missingSource(source.path)
        }
        let resources = try metaEnumerator.compactMap { $0 as? URL }.filter { try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }
        return (java + resources).sorted { $0.path < $1.path }
    }

    private func run(_ executable: URL, arguments: [String], directory: URL, stderr: URL) throws {
        guard FileManager.default.createFile(atPath: stderr.path, contents: nil) else { throw BuildError.missingSource(stderr.path) }
        let handle = try FileHandle(forWritingTo: stderr)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = handle
        do { try process.run() } catch { throw BuildError.toolFailed(executable.lastPathComponent, -1, error.localizedDescription) }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw BuildError.toolFailed(executable.lastPathComponent, process.terminationStatus,
                                        (try? String(contentsOf: stderr, encoding: .utf8)) ?? "stderr unavailable")
        }
    }
}
