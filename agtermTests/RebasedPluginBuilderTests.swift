import Foundation
import XCTest
import agtermCore
@testable import agterm

final class RebasedPluginBuilderTests: XCTestCase {
    func testBridgeRetainsClosedProjectsAndComparesSavedFileBytes() throws {
        let app = try installedApp()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rebased-bridge-contracts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let built = try RebasedPluginBuilder(appBundle: app, ideRoot: root.appendingPathComponent("rebased")).build(buildNumber: "fixture-contracts")
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
            assert Arrays.equals(Bridge.diffFields("req\\tmain\\tHEAD\\t1\\t1\\tpane\\t/repo\\twith tab"),
                                 new String[]{"req", "main", "HEAD", "1", "1", "pane", "/repo\\twith tab"});
            assert Bridge.diffFields("main\\tHEAD") == null;
            assert Arrays.equals(Bridge.fileFields("req\\t3\\t/repo/a.kt\\t/repo\\twith tab"),
                                 new String[]{"req", "3", "/repo/a.kt", "/repo\\twith tab"});
            assert Bridge.fileFields("req\\t-1\\t/repo/a.kt\\t/repo") == null;
            assert Bridge.fileFields("req\\tNaN\\t/repo/a.kt\\t/repo") == null;
            assert RangeDiff.title("main", "HEAD", false, false).equals("main..HEAD");
            assert RangeDiff.title("main", "HEAD", true, false).equals("main...HEAD");
            assert RangeDiff.title("main", "HEAD", false, true).equals("main (working tree)");
            assert RangeDiff.title("main", "HEAD", true, true).equals("main...HEAD + working tree");
            var closedProject = (com.intellij.openapi.project.Project) java.lang.reflect.Proxy.newProxyInstance(
                BridgeContracts.class.getClassLoader(), new Class<?>[]{com.intellij.openapi.project.Project.class},
                (proxy, method, arguments) -> method.getName().equals("isDisposed") ? true : null);
            assert RangeDiff.projectClosed(closedProject, "closed-request");
            assert Arrays.equals(events.get(events.size() - 1), new String[]{"viewFailed", "closed-request\\tproject closed"});
            Bridge.beginView("/repo", "older");
            Bridge.beginView("/repo", "newer");
            assert Bridge.superseded("/repo", "older");
            assert !Bridge.superseded("/repo", "newer");
            assert Bridge.superseded("/other", "newer");
            assert Bridge.onDisk(file.toString(), little);
            assert !Bridge.onDisk(file.toString(), utf8);
            Files.delete(file);
            assert !Bridge.onDisk(file.toString(), little);

            events.clear();
            System.getProperties().put(Bridge.PROPERTY, new Bridge());
            assert "ok".equals(new Bridge().apply("hello", ""));
            assert System.getProperties().get(Bridge.PROPERTY) == null : "hello must drop the bridge property";
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

    func testBuildsIntoTheIdeaProductRoot() throws {
        let app = try installedApp()
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("idea-builder-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: state) }
        let ideRoot = state.appendingPathComponent("rebased/ide/IntelliJIdea2026.2")
        let built = try RebasedPluginBuilder(appBundle: app, ideRoot: ideRoot).build(buildNumber: "fixture-idea")
        XCTAssertEqual(built.jar, ideRoot.appendingPathComponent("plugins/agterm-bridge/lib/agterm-bridge.jar"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: built.jar.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.appendingPathComponent("rebased/plugins").path))
    }

    func testBuiltPluginContainsEveryRebasedViewVerb() throws {
        let app = try installedApp()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rebased-builder-views-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let built = try RebasedPluginBuilder(appBundle: app, ideRoot: root.appendingPathComponent("rebased")).build(buildNumber: "fixture-views")
        let listing = try runJavaTool(URL(fileURLWithPath: "/usr/bin/unzip"), arguments: ["-Z1", built.jar.path], root: root)
        for name in ["Bridge", "RangeDiff", "OpenFile"] {
            XCTAssertTrue(listing.contains("agterm/rebased/\(name).class"), listing)
        }
    }

    func testBuildsAPluginReusesItAndRebuildsForAChangedKey() throws {
        let app = try installedApp()
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("rebased-builder-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: state) }
        let builder = RebasedPluginBuilder(appBundle: app, ideRoot: state.appendingPathComponent("rebased"))
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
        let builder = RebasedPluginBuilder(appBundle: app, ideRoot: root.appendingPathComponent("state/rebased"), sourceDirectory: source)
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

    func testTheSourceDigestCoversEveryMetaInfFile() throws {
        let app = try installedApp()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rebased-builder-meta-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try copiedSource(into: root)
        let builder = RebasedPluginBuilder(appBundle: app, ideRoot: root.appendingPathComponent("state/rebased"), sourceDirectory: source)
        let first = try builder.build(buildNumber: "fixture-meta")
        let descriptor = source.appendingPathComponent("res/META-INF/agterm-maven.xml")
        try (String(contentsOf: descriptor, encoding: .utf8) + "<!-- digest fixture -->\n").write(to: descriptor, atomically: true, encoding: .utf8)
        let changed = try builder.build(buildNumber: "fixture-meta")
        XCTAssertTrue(changed.rebuilt)
        XCTAssertNotEqual(changed.key, first.key)
    }

    func testWithoutAMavenPluginTheBridgeBuildsWithoutTheMavenHook() throws {
        let app = try installedApp()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rebased-builder-nomaven-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let builder = RebasedPluginBuilder(appBundle: app, ideRoot: root.appendingPathComponent("rebased"),
                                           pluginClassPaths: ["Git4Idea": ["plugins/vcs-git/lib/vcs-git.jar"]])
        try assertNoMavenHook(builder.build(buildNumber: "fixture-nomaven").jar, root: root)
    }

    func testAFailedMavenCompileBuildsTheBridgeWithoutTheMavenHook() throws {
        let app = try installedApp()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rebased-builder-badmaven-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let builder = RebasedPluginBuilder(appBundle: app, ideRoot: root.appendingPathComponent("rebased"),
                                           pluginClassPaths: ["org.jetbrains.idea.maven": ["plugins/missing/lib/none.jar"]])
        try assertNoMavenHook(builder.build(buildNumber: "fixture-badmaven").jar, root: root)
        XCTAssertTrue(try builder.build(buildNumber: "fixture-badmaven").rebuilt, "a failed Maven compile is retried at the next build")
    }

    func testGainingAMavenPluginRebuildsTheJarWithTheHook() throws {
        let idea = URL(fileURLWithPath: "/Applications/IntelliJ IDEA.app")
        let info = idea.appendingPathComponent("Contents/Resources/product-info.json")
        guard FileManager.default.fileExists(atPath: info.path) else { throw XCTSkip("IntelliJ IDEA is not installed") }
        let product = try RebasedProduct(bundlePath: idea.path, productInfo: .init(path: info.path, contents: String(contentsOf: info, encoding: .utf8)))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rebased-builder-gain-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let ideRoot = root.appendingPathComponent("rebased")
        try assertNoMavenHook(RebasedPluginBuilder(appBundle: idea, ideRoot: ideRoot).build(buildNumber: "fixture-gain").jar, root: root)
        let built = try RebasedPluginBuilder(appBundle: idea, ideRoot: ideRoot, pluginClassPaths: product.pluginClassPaths)
            .build(buildNumber: "fixture-gain")
        XCTAssertTrue(built.rebuilt)
        let listing = try runJavaTool(URL(fileURLWithPath: "/usr/bin/unzip"), arguments: ["-Z1", built.jar.path], root: root)
        XCTAssertTrue(listing.contains("agterm/rebased/maven/MirrorMaven.class"), listing)
    }

    func testIdeaGetsTheMavenHookThatMapsAMirrorToItsHostsM2Copy() throws {
        let idea = URL(fileURLWithPath: "/Applications/IntelliJ IDEA.app")
        let info = idea.appendingPathComponent("Contents/Resources/product-info.json")
        guard FileManager.default.fileExists(atPath: info.path) else { throw XCTSkip("IntelliJ IDEA is not installed") }
        let product = try RebasedProduct(bundlePath: idea.path, productInfo: .init(path: info.path, contents: String(contentsOf: info, encoding: .utf8)))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rebased-builder-maven-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let built = try RebasedPluginBuilder(appBundle: idea, ideRoot: root.appendingPathComponent("rebased"),
                                             pluginClassPaths: product.pluginClassPaths).build(buildNumber: "fixture-maven")
        let listing = try runJavaTool(URL(fileURLWithPath: "/usr/bin/unzip"), arguments: ["-Z1", built.jar.path], root: root)
        XCTAssertTrue(listing.contains("agterm/rebased/maven/MirrorMaven.class"), listing)
        XCTAssertTrue(listing.contains("META-INF/agterm-maven.xml"), listing)
        let descriptor = try runJavaTool(URL(fileURLWithPath: "/usr/bin/unzip"), arguments: ["-p", built.jar.path, "META-INF/plugin.xml"], root: root)
        XCTAssertTrue(descriptor.contains(#"<depends optional="true" config-file="agterm-maven.xml">org.jetbrains.idea.maven</depends>"#), descriptor)

        let mirrors = root.appendingPathComponent("state/rebased/mirrors")
        let project = mirrors.appendingPathComponent("p4linux/abc123/repo")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("state/rebased/mirrors2/p4linux/abc123/repo"),
                                                withIntermediateDirectories: true)
        let unsynced = mirrors.appendingPathComponent("p4air/def456/repo")
        try FileManager.default.createDirectory(at: unsynced, withIntermediateDirectories: true)
        let m2 = root.appendingPathComponent("state/rebased/m2")
        try FileManager.default.createDirectory(at: m2.appendingPathComponent("p4linux"), withIntermediateDirectories: true)
        let realMirrors = try XCTUnwrap(realpath(mirrors.path, nil).map { String(cString: $0) })
        let source = root.appendingPathComponent("MirrorMavenContracts.java")
        try """
        package agterm.rebased.maven;

        public final class MirrorMavenContracts {
          public static void main(String[] args) {
            String mirrors = args[0], m2 = args[3];
            assert (m2 + "/p4linux/repository").equals(MirrorMaven.repositoryFor(args[1], mirrors, m2)) : MirrorMaven.repositoryFor(args[1], mirrors, m2);
            assert MirrorMaven.repositoryFor(args[4], mirrors, m2) == null : "a host never synced keeps its own repository";
            assert MirrorMaven.repositoryFor(args[2], mirrors, m2) == null : "a sibling sharing the prefix is outside";
            assert MirrorMaven.repositoryFor(mirrors, mirrors, m2) == null : "the mirrors root itself names no host";
            assert MirrorMaven.repositoryFor("/elsewhere/repo", mirrors, m2) == null;
            assert MirrorMaven.repositoryFor(args[1], null, m2) == null;
            System.out.println("maven contracts passed");
          }
        }
        """.write(to: source, atomically: true, encoding: .utf8)
        let classes = root.appendingPathComponent("contract-classes")
        try FileManager.default.createDirectory(at: classes, withIntermediateDirectories: true)
        let contents = idea.appendingPathComponent("Contents")
        let classpath = ([built.jar.path, contents.appendingPathComponent("lib/*").path]
                         + (product.pluginClassPaths["org.jetbrains.idea.maven"] ?? []).map { contents.appendingPathComponent($0).path })
            .joined(separator: ":")
        let bin = contents.appendingPathComponent("jbr/Contents/Home/bin")
        _ = try runJavaTool(bin.appendingPathComponent("javac"), arguments: ["--release", "21", "-cp", classpath, "-d", classes.path, source.path], root: root)
        let output = try runJavaTool(bin.appendingPathComponent("java"),
                                    arguments: ["-ea", "-cp", classes.path + ":" + classpath, "agterm.rebased.maven.MirrorMavenContracts",
                                                realMirrors, project.path,
                                                root.appendingPathComponent("state/rebased/mirrors2/p4linux/abc123/repo").path,
                                                m2.path, unsynced.path], root: root)
        XCTAssertTrue(output.contains("maven contracts passed"), output)
    }

    private func copiedSource(into root: URL) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source")
        try FileManager.default.copyItem(at: XCTUnwrap(Bundle.main.url(forResource: "rebased", withExtension: nil)), to: source)
        return source
    }

    private func assertNoMavenHook(_ jar: URL, root: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let listing = try runJavaTool(URL(fileURLWithPath: "/usr/bin/unzip"), arguments: ["-Z1", jar.path], root: root)
        XCTAssertTrue(listing.contains("agterm/rebased/Bridge.class"), listing, file: file, line: line)
        XCTAssertFalse(listing.contains("agterm/rebased/maven/"), listing, file: file, line: line)
        XCTAssertFalse(listing.contains("agterm-maven.xml"), listing, file: file, line: line)
        let descriptor = try runJavaTool(URL(fileURLWithPath: "/usr/bin/unzip"), arguments: ["-p", jar.path, "META-INF/plugin.xml"], root: root)
        XCTAssertFalse(descriptor.contains("org.jetbrains.idea.maven"), descriptor, file: file, line: line)
    }
}
