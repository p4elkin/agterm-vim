import Foundation
import XCTest
@testable import agterm

final class RebasedPluginBuilderTests: XCTestCase {
    private func installedApp() throws -> URL {
        let app = URL(fileURLWithPath: "/Applications/Rebased.app")
        guard FileManager.default.fileExists(atPath: app.path) else { throw XCTSkip("Rebased is not installed") }
        return app
    }

    func testBuildsAPluginReusesItAndRebuildsForAChangedKey() throws {
        let app = try installedApp()
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("rebased-builder-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: state) }
        let builder = RebasedPluginBuilder(appBundle: app, stateDirectory: state)
        let first = try builder.build(buildNumber: "fixture-build")
        XCTAssertTrue(first.rebuilt)
        let firstBytes = try Data(contentsOf: first.jar)
        let firstDate = try FileManager.default.attributesOfItem(atPath: first.jar.path)[.modificationDate] as? Date
        let archive = Process()
        let output = Pipe()
        archive.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        archive.arguments = ["-Z1", first.jar.path]
        archive.standardOutput = output
        try archive.run()
        let listing = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        archive.waitUntilExit()
        XCTAssertEqual(archive.terminationStatus, 0)
        XCTAssertTrue(listing.contains("META-INF/plugin.xml"))
        XCTAssertTrue(listing.contains("agterm/rebased/Bridge.class"))
        XCTAssertTrue(listing.contains("agterm/rebased/Startup.class"))

        let second = try builder.build(buildNumber: "fixture-build")
        XCTAssertFalse(second.rebuilt)
        XCTAssertEqual(second.key, first.key)
        XCTAssertEqual(try Data(contentsOf: second.jar), firstBytes)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: second.jar.path)[.modificationDate] as? Date, firstDate)

        let third = try builder.build(buildNumber: "fixture-build-changed")
        XCTAssertTrue(third.rebuilt)
        XCTAssertNotEqual(third.key, first.key)
        XCTAssertTrue(FileManager.default.fileExists(atPath: third.jar.path))
    }

    func testAChangedSourceRebuildsAndACompilerFailureKeepsTheLastPlugin() throws {
        let app = try installedApp()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rebased-builder-source-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let resources = try XCTUnwrap(Bundle.main.url(forResource: "rebased", withExtension: nil))
        let source = root.appendingPathComponent("source")
        try FileManager.default.copyItem(at: resources, to: source)
        let builder = RebasedPluginBuilder(appBundle: app, stateDirectory: root.appendingPathComponent("state"), sourceDirectory: source)
        let first = try builder.build(buildNumber: "fixture-build")
        let java = source.appendingPathComponent("src/agterm/rebased/Bridge.java")
        let text = try String(contentsOf: java, encoding: .utf8)
        try (text + "\n// source digest fixture\n").write(to: java, atomically: true, encoding: .utf8)
        let changed = try builder.build(buildNumber: "fixture-build")
        XCTAssertTrue(changed.rebuilt)
        XCTAssertNotEqual(first.key, changed.key)
        let bytes = try Data(contentsOf: changed.jar)

        try "invalid Java source\n".write(to: java, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try builder.build(buildNumber: "fixture-build")) { error in
            XCTAssertTrue(error.localizedDescription.contains("javac"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("Bridge.java"), error.localizedDescription)
        }
        XCTAssertEqual(try Data(contentsOf: changed.jar), bytes)
        try (text + "\n// source digest fixture\n").write(to: java, atomically: true, encoding: .utf8)
        XCTAssertFalse(try builder.build(buildNumber: "fixture-build").rebuilt)
    }
}
