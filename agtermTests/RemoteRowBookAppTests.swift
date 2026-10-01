import XCTest
@testable import agterm
import agtermCore

@MainActor
final class RemoteRowBookAppTests: XCTestCase {
    private var directory: URL!
    private var library: WindowLibrary!
    private var book: RemoteRowBook!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-rowbook-\(UUID().uuidString)")
        library = WindowLibrary(directory: directory)
        book = RemoteRowBook(directory: directory)
    }

    override func tearDown() async throws {
        library = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func attach(in store: AppStore, remoteSessionID: String = "s1") throws -> Session {
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: "/tmp", command: "ssh p4linux",
                                                     wait: true, remoteHost: "p4linux"))
        let endpoint = ControlZmxEndpoint(executable: "/opt/zmx", socketDirectory: "/tmp/zmx-p4linux")
        store.bindRemote(RemoteBinding(remoteSessionID: remoteSessionID, daemonsByLocalPane: [
            session.paneIdentity: ZmxSupport.daemonName(for: UUID()),
        ], presentationVersion: 1, origin: .init(host: "p4linux", endpoint: endpoint, sessionName: "build")),
                         forSession: session.id)
        return session
    }

    private func waitForBook(_ description: String, _ condition: @escaping ([RemoteRowBook.Record]) -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if condition(book.load()) { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("\(description): book is \(book.load())")
    }

    func testAttachingARemoteRowWritesOneRecord() async throws {
        let writer = RemoteRowBookWriter(library: library, book: book, delay: 0)
        let store = try XCTUnwrap(library.activeStore)
        _ = try attach(in: store)
        _ = store.addSession(toWorkspace: try XCTUnwrap(store.currentWorkspaceID), cwd: "/tmp")

        try await waitForBook("one record") { $0.map(\.remoteSessionID) == ["s1"] }
        withExtendedLifetime(writer) {}
    }

    func testClosingTheRowRemovesItsRecord() async throws {
        let writer = RemoteRowBookWriter(library: library, book: book, delay: 0)
        let store = try XCTUnwrap(library.activeStore)
        let session = try attach(in: store)
        try await waitForBook("written") { $0.count == 1 }

        store.closeSession(session.id)

        try await waitForBook("removed") { $0.isEmpty }
        withExtendedLifetime(writer) {}
    }

    func testASoftClosedRowKeepsItsRecordUntilTheCloseIsFinal() async throws {
        let writer = RemoteRowBookWriter(library: library, book: book, delay: 0)
        let store = try XCTUnwrap(library.activeStore)
        let session = try attach(in: store)
        try await waitForBook("written") { $0.count == 1 }

        XCTAssertTrue(store.softCloseSession(session.id, grace: 60))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(book.load().count, 1)

        store.finalizeAllPendingCloses()

        try await waitForBook("removed at finalization") { $0.isEmpty }
        withExtendedLifetime(writer) {}
    }

    func testClosingItsWindowKeepsTheRecord() async throws {
        let writer = RemoteRowBookWriter(library: library, book: book, delay: 0)
        let window = library.newWindow(name: "other")
        let store = try XCTUnwrap(library.loadStore(for: window.id))
        _ = try attach(in: store)
        try await waitForBook("written") { $0.map(\.windowID) == [window.id] }

        library.closeWindow(window.id)
        _ = library.activeStore?.addSession(toWorkspace: try XCTUnwrap(library.activeStore?.currentWorkspaceID), cwd: "/tmp")
        try await Task.sleep(nanoseconds: 300_000_000)
        writer.write()

        XCTAssertEqual(book.load().map(\.windowID), [window.id])
    }

    func testQuitTeardownDoesNotEmptyTheBook() async throws {
        let writer = RemoteRowBookWriter(library: library, book: book, delay: 0)
        let store = try XCTUnwrap(library.activeStore)
        let session = try attach(in: store)
        writer.write()
        library.isTerminating = true

        store.closeSession(session.id)
        writer.schedule()
        writer.write()
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(book.load().map(\.remoteSessionID), ["s1"])
    }

    func testAnOnDemandCaptureDoesNotStopLaterWrites() async throws {
        let writer = RemoteRowBookWriter(library: library, book: book, delay: 0)
        let store = try XCTUnwrap(library.activeStore)
        _ = AppDelegate.captureForegroundCommands(sessions: library.allOpenSessions())

        _ = try attach(in: store)

        try await waitForBook("written after a capture") { $0.count == 1 }
        withExtendedLifetime(writer) {}
    }
}
