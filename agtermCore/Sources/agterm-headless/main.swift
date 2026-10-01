import agtermCore
import AgtermHeadlessKit
import Foundation
import Glibc

// Usage: agterm-headless serve. Clients are the real agtermctl, with `--socket` or AGTERM_STATE_DIR.

let config = HeadlessConfig.fromEnvironment(ProcessInfo.processInfo.environment)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard CommandLine.arguments.dropFirst().first == "serve" else { fail("usage: agterm-headless serve") }
signal(SIGPIPE, SIG_IGN)
do {
    try FileManager.default.createDirectory(atPath: config.stateDirectory, withIntermediateDirectories: true)
} catch {
    fail("could not create \(config.stateDirectory): \(error.localizedDescription)")
}
let lock: Int32
switch UnixSocket.claim(path: config.socketPath) {
case .held(let fd): lock = fd
case .taken: fail("another agterm-headless already serves \(config.socketPath)")
case .failed(let reason): fail(reason)
}
let headless = Headless(config: config) { library, hub in
    PresentationStreams(library: library, hub: hub)
}
// BUILD sits next to the installed binary
let executable = (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe")) ?? CommandLine.arguments[0]
let actions = HeadlessActions(headless: headless, installDirectory: URL(fileURLWithPath: executable).deletingLastPathComponent())
guard let server = ControlSocketServer(path: config.socketPath, handler: { request, fd in
    await actions.serve(request, connection: fd)
}) else { fail("could not bind \(config.socketPath)") }
server.start()
let watcher = DaemonWatcher(headless: headless)
watcher.start()
print("agterm-headless serving \(config.socketPath), zmx \(config.zmxExecutable) in \(config.zmxDirectory)")
withExtendedLifetime(lock) { dispatchMain() }
