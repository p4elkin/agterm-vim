import Foundation
import Testing
import agtermCore
@testable import AgtermHeadlessKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@MainActor
@Suite(.serialized)
struct HeadlessPagesTests {
    @Test(arguments: [false, true])
    func rebasedOpenIsRefusedOnTheHeadlessOrigin(_ withHtml: Bool) async throws {
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let request = HeadlessRequests.request(.sessionOverlayOpen, target: fixture.session.id.uuidString) {
            $0.rebased = true
            if withHtml { $0.html = "/tmp/report.html" }
        }
        let response = await fixture.actions.respond(to: request)
        #expect(!response.ok)
        #expect(response.error == "session.overlay.open is not available on a headless origin: Rebased overlays open on a Mac only")
        #expect(fixture.headless.pages.count == 0)
    }

    final class Folder {
        let root: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-pages-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root.appendingPathComponent("assets"), withIntermediateDirectories: true)
            try "<html>report</html>".write(to: root.appendingPathComponent("report.html"), atomically: true, encoding: .utf8)
            try "body{}".write(to: root.appendingPathComponent("assets/style.css"), atomically: true, encoding: .utf8)
        }
        var path: String { HeadlessPages.realPath(root.path) ?? root.path }
        deinit { try? FileManager.default.removeItem(at: root) }
    }

    private func token(_ publication: HeadlessPages.Publication) throws -> String {
        guard case .published(let token, _) = publication else { throw Failure(publication) }
        return token
    }

    struct Failure: Error { let publication: HeadlessPages.Publication; init(_ p: HeadlessPages.Publication) { publication = p } }

    // MARK: The page table

    @Test func aPageIsServedFromItsFolderByDefault() throws {
        let folder = try Folder()
        let pages = HeadlessPages()

        let publication = pages.publish(file: folder.path + "/report.html", grantRoot: nil, session: UUID())

        let token = try token(publication)
        #expect(publication == .published(token: token, path: "report.html"))
        #expect(pages.file(forPath: "/\(token)/assets/style.css") == folder.path + "/assets/style.css")
    }

    @Test func cwdWidensTheServedRootAndTheURLKeepsTheSubfolder() throws {
        let folder = try Folder()
        try "<p>" .write(toFile: folder.path + "/assets/page.html", atomically: true, encoding: .utf8)
        let pages = HeadlessPages()

        let publication = pages.publish(file: folder.path + "/assets/page.html", grantRoot: folder.path, session: UUID())

        let token = try token(publication)
        #expect(publication == .published(token: token, path: "assets/page.html"))
        #expect(pages.file(forPath: "/\(token)/report.html") == folder.path + "/report.html")
    }

    @Test func unservableFilesAreRefusedWithTheMacsText() throws {
        let folder = try Folder()
        let other = try Folder()
        let pages = HeadlessPages()

        #expect(pages.publish(file: "report.html", grantRoot: nil, session: UUID()) == .refused("html file must be an absolute path"))
        #expect(pages.publish(file: folder.path + "/missing.html", grantRoot: nil, session: UUID())
            == .refused("html file not found: \(folder.path)/missing.html"))
        #expect(pages.publish(file: folder.path + "/report.html", grantRoot: other.path, session: UUID())
            == .refused("html file is outside cwd"))
        #expect(pages.count == 0)
    }

    @Test(arguments: ["/../report.html", "/assets/../../etc/passwd", "/%2e%2e/%2e%2e/etc/passwd", "/missing.css", "/", "/assets"])
    func pathsOutsideTheFolderOrNotFilesResolveToNothing(_ suffix: String) throws {
        let folder = try Folder()
        let pages = HeadlessPages()
        let token = try token(pages.publish(file: folder.path + "/assets/style.css", grantRoot: nil, session: UUID()))

        #expect(pages.file(forPath: "/\(token)\(suffix)") == nil)
    }

    @Test func aSymlinkOutOfTheFolderAndAnUnknownTokenResolveToNothing() throws {
        let folder = try Folder()
        let outside = try Folder()
        try FileManager.default.createSymbolicLink(atPath: folder.path + "/escape.html", withDestinationPath: outside.path + "/report.html")
        let pages = HeadlessPages()
        let token = try token(pages.publish(file: folder.path + "/report.html", grantRoot: nil, session: UUID()))

        #expect(pages.file(forPath: "/\(token)/escape.html") == nil)
        #expect(pages.file(forPath: "/\(UUID().uuidString.lowercased())/report.html") == nil)
        #expect(pages.file(forPath: "/\(token)/report.html?reload=1") == folder.path + "/report.html")
    }

    @Test func closingASessionAndTheLimitDropPages() throws {
        let folder = try Folder()
        let pages = HeadlessPages()
        let session = UUID()
        let first = try token(pages.publish(file: folder.path + "/report.html", grantRoot: nil, session: session))
        _ = try token(pages.publish(file: folder.path + "/report.html", grantRoot: nil, session: UUID()))

        pages.forget(session: session)

        #expect(pages.file(forPath: "/\(first)/report.html") == nil)
        #expect(pages.count == 1)
        for _ in 0..<HeadlessPages.limit { _ = pages.publish(file: folder.path + "/report.html", grantRoot: nil, session: UUID()) }
        #expect(pages.count == HeadlessPages.limit)
    }

    // MARK: The HTTP server

    @Test func theServerAnswersGetHeadAndRefusesTheRest() throws {
        let folder = try Folder()
        let pages = HeadlessPages()
        let server = PageServer(pages: pages, host: "127.0.0.1", port: 0)
        defer { server.stop() }
        let token = try token(pages.publish(file: folder.path + "/report.html", grantRoot: nil, session: UUID()))
        #expect(server.ensureListening() == nil)

        let get = try fetch(server.port, "GET /\(token)/report.html HTTP/1.1\r\nHost: x\r\n\r\n")
        let css = try fetch(server.port, "GET /\(token)/assets/style.css HTTP/1.1\r\n\r\n")
        let head = try fetch(server.port, "HEAD /\(token)/report.html HTTP/1.1\r\n\r\n")

        #expect(get.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(get.contains("Content-Type: text/html; charset=utf-8\r\n"))
        #expect(get.contains("Cache-Control: no-store\r\n"))
        #expect(get.hasSuffix("\r\n\r\n<html>report</html>"))
        #expect(css.contains("Content-Type: text/css; charset=utf-8\r\n"))
        #expect(head.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(head.contains("Content-Length: 19\r\n"))
        #expect(head.hasSuffix("\r\n\r\n"))
        #expect(try fetch(server.port, "GET /\(token)/nope.html HTTP/1.1\r\n\r\n").hasPrefix("HTTP/1.1 404 Not Found\r\n"))
        #expect(try fetch(server.port, "POST /\(token)/report.html HTTP/1.1\r\n\r\n").hasPrefix("HTTP/1.1 405 Method Not Allowed\r\n"))
        #expect(try fetch(server.port, "nonsense\r\n\r\n").hasPrefix("HTTP/1.1 400 Bad Request\r\n"))
    }

    @Test func aHostThatDoesNotResolveIsReportedAndRetried() {
        let server = PageServer(pages: HeadlessPages(), host: "no-such-host.invalid", port: 0)

        #expect(server.ensureListening()?.hasPrefix("cannot resolve no-such-host.invalid") == true)
        #expect(server.ensureListening() != nil)
    }

    @Test func theURLEncodesThePath() {
        #expect(PageServer.url(host: "p4linux.example.ts.net", port: 19510, token: "t", path: "a b/c#d.html")
            == "http://p4linux.example.ts.net:19510/t/a%20b/c%23d.html")
    }

    // MARK: The rewrite

    @Test func anHtmlOpenReachesThePresenterAsAURLOnThisOriginsPageServer() async throws {
        let folder = try Folder()
        let fixture = try HeadlessActionFixture(pageHost: "127.0.0.1")
        defer { fixture.cleanUp() }
        let presenter = try HeadlessForwarderTests.Presenter(fixture.headless.hub, session: fixture.session.id)
        let request = HeadlessRequests.request(.sessionOverlayOpen, target: fixture.session.id.uuidString) {
            $0.html = folder.path + "/report.html"; $0.cwd = folder.path; $0.chromeless = true
            $0.javascript = true; $0.navigation = true; $0.sizePercent = 80
        }

        let answer = Task { await fixture.actions.respond(to: request) }
        for _ in 0..<200 where presenter.forwards.isEmpty { await Task.yield() }
        let sent = try #require(presenter.forwards.first?.request)
        var opened = ControlResult(id: fixture.session.id.uuidString)
        opened.pageID = "page-1"
        presenter.reply(ControlResponse(ok: true, result: opened))

        #expect(await answer.value.result?.pageID == "page-1")
        #expect(sent.args?.html == nil)
        #expect(sent.args?.cwd == nil)
        #expect(sent.args?.chromeless == nil)
        #expect(sent.args?.javascript == true)
        #expect(sent.args?.navigation == true)
        #expect(sent.args?.sizePercent == 80)
        let url = try #require(sent.args?.url)
        let port = try #require(fixture.headless.pageServer?.port)
        #expect(url.hasPrefix("http://127.0.0.1:\(port)/"))
        #expect(url.hasSuffix("/report.html"))
        let path = String(url.dropFirst("http://127.0.0.1:\(port)".count))
        #expect(try fetch(port, "GET \(path) HTTP/1.1\r\n\r\n").hasSuffix("<html>report</html>"))
    }

    @Test func aFailedForwardUnpublishesThePage() async throws {
        let folder = try Folder()
        let fixture = try HeadlessActionFixture(pageHost: "127.0.0.1")
        defer { fixture.cleanUp() }
        let request = HeadlessRequests.request(.sessionOverlayOpen, target: fixture.session.id.uuidString) {
            $0.html = folder.path + "/report.html"
        }

        let response = await fixture.actions.respond(to: request)

        #expect(response.error == "session.overlay.open cannot be forwarded: no Mac is presenting this session")
        #expect(fixture.headless.pages.count == 0)
    }

    @Test func withoutAPageHostAnHtmlOpenIsRefusedByName() async throws {
        let folder = try Folder()
        let fixture = try HeadlessActionFixture()
        defer { fixture.cleanUp() }
        let request = HeadlessRequests.request(.sessionOverlayOpen, target: fixture.session.id.uuidString) {
            $0.html = folder.path + "/report.html"
        }

        #expect(await fixture.actions.respond(to: request).error
            == "session.overlay.open is not available on a headless origin: an --html page needs AGTERM_HEADLESS_PAGE_HOST")
    }

    @Test func aBadFileAndAMissingTargetAreRefusedBeforeAnythingIsPublished() async throws {
        let fixture = try HeadlessActionFixture(pageHost: "127.0.0.1")
        defer { fixture.cleanUp() }

        let bad = await fixture.actions.respond(to: HeadlessRequests.request(.sessionOverlayOpen,
                                                                             target: fixture.session.id.uuidString) { $0.html = "/no/such/page.html" })
        let untargeted = await fixture.actions.respond(to: ControlRequest(cmd: .sessionOverlayOpen,
                                                                          args: ControlArgs(html: "/no/such/page.html")))

        #expect(bad.error == "html file not found: /no/such/page.html")
        #expect(untargeted.error == "session.overlay.open cannot be forwarded: it needs --target naming a session on this origin")
        #expect(fixture.headless.pages.count == 0)
    }

    @Test func closingTheSessionUnpublishesItsPages() throws {
        let folder = try Folder()
        let fixture = try HeadlessActionFixture(pageHost: "127.0.0.1")
        defer { fixture.cleanUp() }
        guard case .published = fixture.headless.servePage(folder.path + "/report.html", grantRoot: nil,
                                                           session: fixture.session.id) else { throw Failure(.refused("not published")) }

        fixture.headless.closeSession(fixture.session, in: fixture.store)

        #expect(fixture.headless.pages.count == 0)
    }

    /// One request on a fresh connection to 127.0.0.1, read to the end.
    private func fetch(_ port: UInt16, _ request: String) throws -> String {
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        try #require(connected == 0)
        PageServer.sendAll(fd, Data(request.utf8))
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            reply.append(contentsOf: buffer[0..<count])
        }
        return String(decoding: reply, as: UTF8.self)
    }
}
