import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A minimal HTTP/1.1 file server for `HeadlessPages`: GET and HEAD, one connection per request. It binds the page
/// host's own address, so on a Tailscale name it listens on the tailnet only. Threads are dedicated, never the
/// global pool, as everywhere in this kit.
public final class PageServer: @unchecked Sendable {
    static let headLimit = 16 * 1024
    static let fileLimit = 64 * 1024 * 1024

    private let pages: HeadlessPages
    private let host: String
    private let requestedPort: UInt16
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var boundPort: UInt16 = 0

    public init(pages: HeadlessPages, host: String, port: UInt16) {
        self.pages = pages
        self.host = host
        requestedPort = port
    }

    /// The port it listens on; the requested one unless that was 0.
    public var port: UInt16 {
        lock.lock()
        defer { lock.unlock() }
        return boundPort
    }

    /// Nil once listening, else why not. Retried on every call, so a host whose address appears late still works.
    public func ensureListening() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard listener < 0 else { return nil }
        switch Self.listen(host: host, port: requestedPort) {
        case .failure(let reason): return reason.message
        case .success(let (fd, port)):
            listener = fd
            boundPort = port
            let body: @Sendable () -> Void = { [self] in acceptLoop(fd) }
            Thread(block: body).start()
            return nil
        }
    }

    public func stop() {
        lock.lock()
        let fd = listener
        listener = -1
        lock.unlock()
        if fd >= 0 {
            shutdown(fd, Int32(SHUT_RDWR))
            close(fd)
        }
    }

    public static func url(host: String, port: UInt16, token: String, path: String) -> String {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return "http://\(host):\(port)/\(token)/\(encoded)"
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let connection = accept(fd, nil, nil)
            if connection < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return
            }
            let body: @Sendable () -> Void = { [self] in serve(connection) }
            Thread(block: body).start()
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        #if canImport(Darwin)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        let response = Self.response(to: Self.readHead(fd), pages: pages)
        Self.sendAll(fd, response)
    }

    struct Failure: Error { let message: String }

    static func response(to head: Data?, pages: HeadlessPages) -> Data {
        guard let head, let text = String(data: head, encoding: .utf8),
              let line = text.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first else {
            return status(400, "Bad Request")
        }
        let words = line.split(separator: " ")
        guard words.count == 3, words[1].hasPrefix("/"), words[2].hasPrefix("HTTP/1.") else {
            return status(400, "Bad Request")
        }
        let method = String(words[0])
        guard method == "GET" || method == "HEAD" else { return status(405, "Method Not Allowed", extra: "Allow: GET, HEAD\r\n") }
        guard let file = pages.file(forPath: String(words[1])),
              let size = (try? FileManager.default.attributesOfItem(atPath: file))?[.size] as? Int, size <= fileLimit,
              let body = try? Data(contentsOf: URL(fileURLWithPath: file)) else {
            return status(404, "Not Found")
        }
        var out = Data(("HTTP/1.1 200 OK\r\nContent-Type: \(contentType(file))\r\nContent-Length: \(body.count)\r\n"
            + commonHeaders + "\r\n").utf8)
        if method == "GET" { out.append(body) }
        return out
    }

    private static let commonHeaders = "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n"
        + "Referrer-Policy: no-referrer\r\nConnection: close\r\n"

    private static func status(_ code: Int, _ reason: String, extra: String = "") -> Data {
        let body = "\(code) \(reason)\n"
        return Data(("HTTP/1.1 \(code) \(reason)\r\nContent-Type: text/plain; charset=utf-8\r\n"
            + "Content-Length: \(body.utf8.count)\r\n\(extra)" + commonHeaders + "\r\n" + body).utf8)
    }

    static func contentType(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm": "text/html; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "js", "mjs": "text/javascript; charset=utf-8"
        case "json", "map": "application/json"
        case "txt", "md", "log": "text/plain; charset=utf-8"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "ico": "image/x-icon"
        case "woff": "font/woff"
        case "woff2": "font/woff2"
        case "pdf": "application/pdf"
        default: "application/octet-stream"
        }
    }

    /// The request head up to the blank line, nil past `headLimit`, on a timeout, or when the peer closes first.
    static func readHead(_ fd: Int32) -> Data? {
        var head = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let end = Data("\r\n\r\n".utf8)
        while head.count <= headLimit {
            let count = read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }
            head.append(contentsOf: buffer[0..<count])
            if let range = head.range(of: end) { return head.subdata(in: head.startIndex..<range.lowerBound) }
        }
        return nil
    }

    static func sendAll(_ fd: Int32, _ data: Data) {
        #if canImport(Darwin)
        let flags: Int32 = 0
        #else
        let flags = Int32(MSG_NOSIGNAL)
        #endif
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let sent = send(fd, base + offset, raw.count - offset, flags)
                if sent < 0, errno == EINTR { continue }
                guard sent > 0 else { return }
                offset += sent
            }
        }
    }

    static func listen(host: String, port: UInt16) -> Result<(Int32, UInt16), Failure> {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        #if canImport(Darwin)
        hints.ai_socktype = SOCK_STREAM
        #else
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #endif
        var found: UnsafeMutablePointer<addrinfo>?
        let lookup = getaddrinfo(host, String(port), &hints, &found)
        guard lookup == 0, let info = found else {
            return .failure(Failure(message: "cannot resolve \(host): \(String(cString: gai_strerror(lookup)))"))
        }
        defer { freeaddrinfo(found) }
        let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard fd >= 0 else { return .failure(Failure(message: "socket: \(String(cString: strerror(errno)))")) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        guard bind(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0, socketListen(fd, 16) == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            return .failure(Failure(message: "cannot listen on \(host):\(port): \(reason)"))
        }
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return .success((fd, UInt16(bigEndian: address.sin_port)))
    }
}

private func socketListen(_ fd: Int32, _ backlog: Int32) -> Int32 {
    #if canImport(Darwin)
    Darwin.listen(fd, backlog)
    #else
    Glibc.listen(fd, backlog)
    #endif
}
