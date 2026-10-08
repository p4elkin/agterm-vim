import CryptoKit
import Foundation
import agtermCore

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
    let stateDirectory: URL
    var sourceDirectory: URL?

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
        let key = RebasedInstall.pluginCacheKey(buildNumber: buildNumber, sourceDigest: digest.finalize().map { String(format: "%02x", $0) }.joined())
        let plugins = stateDirectory.appendingPathComponent("rebased/plugins")
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
        try run(appBundle.appendingPathComponent("Contents/jbr/Contents/Home/bin/javac"),
                arguments: ["--release", "21", "-cp", appBundle.appendingPathComponent("Contents/lib/*").path, "-d", classes.path] + java.map(\.path),
                directory: staging, stderr: staging.appendingPathComponent("javac.stderr"))
        try manager.copyItem(at: source.appendingPathComponent("res/META-INF"), to: classes.appendingPathComponent("META-INF"))
        let archive = staging.appendingPathComponent("agterm-bridge.jar")
        try run(URL(fileURLWithPath: "/usr/bin/zip"), arguments: ["-q", "-r", "-X", archive.path, "."],
                directory: classes, stderr: staging.appendingPathComponent("zip.stderr"))
        try manager.createDirectory(at: jar.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contentsOf: archive).write(to: jar, options: .atomic)
        try key.write(to: stamp, atomically: true, encoding: .utf8)
        return BuildResult(jar: jar, key: key, rebuilt: true)
    }

    private func sourceFiles(in source: URL) throws -> [URL] {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(at: source.appendingPathComponent("src"), includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw BuildError.missingSource(source.appendingPathComponent("src").path)
        }
        let java = try enumerator.compactMap { $0 as? URL }.filter { url in
            try url.pathExtension == "java" && url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        }
        let descriptor = source.appendingPathComponent("res/META-INF/plugin.xml")
        guard !java.isEmpty, manager.fileExists(atPath: descriptor.path) else { throw BuildError.missingSource(source.path) }
        return (java + [descriptor]).sorted { $0.path < $1.path }
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
