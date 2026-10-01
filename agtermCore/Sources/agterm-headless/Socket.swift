import agtermCore
import Foundation
import Glibc

/// Minimal newline-JSON unix socket, the same framing `agtermctl`'s `SocketClient` speaks.
enum UnixSocket {
    enum Claim {
        case held(Int32)
        case taken
        case failed(String)
    }

    /// Holds `<path>.lock` for the life of the process, as the app's `ControlServer` does, so a second
    /// server refuses rather than unlinking a live socket and splitting the persisted state.
    static func claim(path: String) -> Claim {
        let fd = open(path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return .failed("open \(path).lock: \(String(cString: strerror(errno)))") }
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code == EINTR { continue }
            close(fd)
            return code == EWOULDBLOCK ? .taken : .failed("flock \(path).lock: \(String(cString: strerror(code)))")
        }
        return .held(fd)
    }

    static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (index, byte) in bytes.enumerated() { raw[index] = byte }
            raw[bytes.count] = 0
        }
        return addr
    }

    static func listen(path: String) -> Int32? {
        guard var addr = address(path) else { return nil }
        unlink(path)
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { return nil }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, Glibc.listen(fd, 16) == 0 else { close(fd); return nil }
        chmod(path, 0o600)
        return fd
    }

    /// One newline-terminated line; nil at end of stream, on an error, or past `limit` without a newline.
    static func readLine(_ fd: Int32, limit: Int = ControlWire.maxRequestLineBytes) -> Data? {
        var line = Data()
        var byte: UInt8 = 0
        while true {
            let count = read(fd, &byte, 1)
            if count < 0, errno == EINTR { continue }
            guard count == 1 else { return nil }
            if byte == UInt8(ascii: "\n") { return line }
            line.append(byte)
            guard line.count <= limit else { return nil }
        }
    }

    @discardableResult
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written < 0, errno == EINTR { continue }
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
    }
}

/// Accepts on a background thread, answers every request on the main actor. Each connection's thread
/// waits for its answer, so the main actor is never blocked on a client.
final class ControlSocketServer: Sendable {
    let listener: Int32
    let handler: @MainActor @Sendable (ControlRequest, Int32) async -> ControlResponse?

    init?(path: String, handler: @escaping @MainActor @Sendable (ControlRequest, Int32) async -> ControlResponse?) {
        guard let fd = UnixSocket.listen(path: path) else { return nil }
        listener = fd
        self.handler = handler
    }

    func start() {
        let thread = Thread { [self] in
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else {
                    // EMFILE and friends persist; retrying at once would spin a core
                    if errno != EINTR {
                        FileHandle.standardError.write(Data("accept failed: errno \(errno)\n".utf8))
                        usleep(100_000)
                    }
                    continue
                }
                Thread { [self] in serve(client) }.start()
            }
        }
        thread.start()
    }

    /// A nil answer means the handler took the connection over (a stream) and closes it itself.
    private func serve(_ client: Int32) {
        guard let line = UnixSocket.readLine(client) else { close(client); return }
        let response: ControlResponse?
        if let request = try? JSONDecoder().decode(ControlRequest.self, from: line) {
            let answer = Answer()
            Task { @MainActor [handler] in
                answer.response = await handler(request, client)
                answer.ready.signal()
            }
            answer.ready.wait()
            response = answer.response
        } else {
            response = ControlResponse(ok: false, error: "malformed request")
        }
        guard let response else { return } // the handler owns `client` now
        if var data = try? JSONEncoder().encode(response) {
            data.append(UInt8(ascii: "\n"))
            UnixSocket.writeAll(client, data)
        }
        close(client)
    }
}

/// One request's answer, handed from the main actor to the connection's thread.
private final class Answer: @unchecked Sendable {
    let ready = DispatchSemaphore(value: 0)
    // written once on the main actor before `ready` is signalled, read only after the wait
    var response: ControlResponse?
}
