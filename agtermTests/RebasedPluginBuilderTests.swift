import Foundation
import XCTest
@testable import agterm

final class RebasedPluginBuilderTests: XCTestCase {
    func testBridgeRetainsClosedProjectsAndComparesSavedFileBytes() throws {
        let app = try installedApp()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rebased-bridge-contracts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let built = try RebasedPluginBuilder(appBundle: app, stateDirectory: root).build(buildNumber: "fixture-contracts")
        let source = root.appendingPathComponent("BridgeContracts.java")
        try """
        package agterm.rebased;
        import java.nio.charset.StandardCharsets;
        import java.nio.file.Files;
        import java.nio.file.Path;
        import java.util.Arrays;
        import java.util.List;

        public final class BridgeContracts {
          @SuppressWarnings("unchecked")
          public static void main(String[] args) throws Exception {
            Bridge.openedProject(null, "/repo", 42);
            Bridge.closedProject(null);
            Bridge.closedProject(null);
            var field = Bridge.class.getDeclaredField("pending");
            field.setAccessible(true);
            var events = (List<String[]>) field.get(null);
            assert events.size() == 2 : "unadopted frames must not report a close";
            assert Arrays.equals(events.get(0), new String[]{"frameOpened", "/repo\\t42"});
            assert Arrays.equals(events.get(1), new String[]{"frameClosed", "/repo"});

            var unsafeField = sun.misc.Unsafe.class.getDeclaredField("theUnsafe");
            unsafeField.setAccessible(true);
            var unsafe = (sun.misc.Unsafe) unsafeField.get(null);
            var parent = java.awt.Component.class.getDeclaredField("parent");
            parent.setAccessible(true);
            var frameA = (java.awt.Frame) unsafe.allocateInstance(java.awt.Frame.class);
            var frameB = (java.awt.Frame) unsafe.allocateInstance(java.awt.Frame.class);
            var dialogA = (java.awt.Dialog) unsafe.allocateInstance(java.awt.Dialog.class);
            var dialogB = (java.awt.Dialog) unsafe.allocateInstance(java.awt.Dialog.class);
            var nested = (java.awt.Dialog) unsafe.allocateInstance(java.awt.Dialog.class);
            parent.set(dialogA, frameA);
            parent.set(dialogB, frameB);
            parent.set(nested, dialogA);
            Bridge.openedProject(frameA, "/repo-owner-a", 77);
            Bridge.openedProject(frameB, "/repo-owner-b", 78);
            Bridge.windowOpened(dialogA, 80, "dialog");
            Bridge.windowOpened(dialogB, 81, "dialog");
            Bridge.windowOpened(nested, 82, "popup");
            Bridge.windowOpened(null, 83, "welcome");
            assert Arrays.equals(events.get(4), new String[]{"windowOpened", "80\\tdialog\\t/repo-owner-a"});
            assert Arrays.equals(events.get(5), new String[]{"windowOpened", "81\\tdialog\\t/repo-owner-b"});
            assert Arrays.equals(events.get(6), new String[]{"windowOpened", "82\\tpopup\\t/repo-owner-a"});
            assert Arrays.equals(events.get(7), new String[]{"windowOpened", "83\\twelcome\\t"});

            byte[] utf8 = new byte[]{(byte)0xef, (byte)0xbb, (byte)0xbf, 97, 10};
            byte[] little = new byte[]{(byte)0xff, (byte)0xfe, 97, 0, 13, 0, 10, 0};
            byte[] big = new byte[]{(byte)0xfe, (byte)0xff, 0, 97, 0, 10};
            byte[] latin = new byte[]{(byte)0xe9, 10};
            assert Arrays.equals(Bridge.savedBytes("a\\n", "\\n", StandardCharsets.UTF_8,
                               new byte[]{(byte)0xef, (byte)0xbb, (byte)0xbf}), utf8);
            assert Arrays.equals(Bridge.savedBytes("a\\n", "\\r\\n", StandardCharsets.UTF_16LE,
                               new byte[]{(byte)0xff, (byte)0xfe}), little);
            assert Arrays.equals(Bridge.savedBytes("a\\n", "\\n", StandardCharsets.UTF_16,
                               new byte[]{(byte)0xfe, (byte)0xff}), big) : "BOM must not be doubled";
            assert Arrays.equals(Bridge.savedBytes("é\\n", null, StandardCharsets.ISO_8859_1, null), latin);
            var file = Path.of(args[0]);
            Files.write(file, little);
            assert Arrays.equals(Bridge.diffFields("main\\tHEAD\\t1\\t/repo\\twith tab"),
                                 new String[]{"main", "HEAD", "1", "/repo\\twith tab"});
            assert Bridge.diffFields("main\\tHEAD") == null;
            assert Bridge.onDisk(file.toString(), little);
            assert !Bridge.onDisk(file.toString(), utf8);
            Files.delete(file);
            assert !Bridge.onDisk(file.toString(), little);
            System.out.println("bridge contracts passed");
          }
        }
        """.write(to: source, atomically: true, encoding: .utf8)
        let classes = root.appendingPathComponent("contract-classes")
        try FileManager.default.createDirectory(at: classes, withIntermediateDirectories: true)
        let classpath = built.jar.path + ":" + app.appendingPathComponent("Contents/lib/*").path
        let home = app.appendingPathComponent("Contents/jbr/Contents/Home/bin")
        _ = try runJavaTool(home.appendingPathComponent("javac"), arguments: ["--release", "21", "-cp", classpath, "-d", classes.path, source.path], root: root)
        let output = try runJavaTool(home.appendingPathComponent("java"),
                                    arguments: ["-ea", "-Djava.awt.headless=true", "--add-opens=java.desktop/java.awt=ALL-UNNAMED",
                                                "-cp", classes.path + ":" + classpath,
                                                "agterm.rebased.BridgeContracts", root.appendingPathComponent("saved.txt").path], root: root)
        XCTAssertTrue(output.contains("bridge contracts passed"), output)
    }

    private func runJavaTool(_ executable: URL, arguments: [String], root: URL) throws -> String {
        let log = root.appendingPathComponent("\(executable.lastPathComponent)-contracts.log")
        XCTAssertTrue(FileManager.default.createFile(atPath: log.path, contents: nil))
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        process.waitUntilExit()
        let output = try String(contentsOf: log, encoding: .utf8)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "RebasedBridgeContracts", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: output])
        }
        return output
    }

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
