import AppKit
import Foundation
import RebasedJNI
import agtermCore

/// What `RebasedHost` needs from the JVM, so its lifecycle can be tested without one.
protocol RebasedRuntime: Sendable {
    /// Reads the install and builds the plugin. Blocking; called off the main actor.
    func prepare(appPath: String, stateDirectory: URL) throws -> RebasedLaunch
    /// Creates the JVM and resolves its main class; it can block without bound. Called off the main actor.
    func launch(_ launch: RebasedLaunch) throws
    /// Binds `hostEvent` and calls `hello`. `nil` once bound; `RebasedRuntimeError.notReady` until the
    /// plugin has published its bridge.
    func bindEvents() -> RebasedRuntimeError?
    func call(_ command: String, _ argument: String) -> String
    var jvmCreated: Bool { get }
}

struct RebasedLaunch: Sendable {
    let libjvm: String
    let options: [String]
    let mainClass: String
}

enum RebasedRuntimeError: Error, Equatable, LocalizedError {
    case notReady
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notReady: "Rebased bridge is not ready"
        case .failed(let message): message
        }
    }
}

struct JNIRebasedRuntime: RebasedRuntime {
    private static let notReady = "Rebased bridge is not ready"

    func prepare(appPath: String, stateDirectory: URL) throws -> RebasedLaunch {
        let app = URL(fileURLWithPath: appPath)
        func input(_ relative: String) -> RebasedInstall.FileInput {
            let url = app.appendingPathComponent(relative)
            return .init(path: url.path, contents: try? String(contentsOf: url, encoding: .utf8))
        }
        let install = try RebasedInstall(bundlePath: appPath, stateDirectory: stateDirectory.path,
                                         productInfo: input("Contents/Resources/product-info.json"),
                                         vmOptions: input("Contents/bin/rebased.vmoptions"),
                                         runtimeRelease: input("Contents/jbr/Contents/Home/release"))
        _ = try RebasedPluginBuilder(appBundle: app, stateDirectory: stateDirectory).build(buildNumber: install.buildNumber)
        // IntelliJ's own screen menu would fight SwiftUI over NSApp.mainMenu; MacMenuSettings reads the jb flag first.
        let options = install.jvmOptions + ["-DjbScreenMenuBar.enabled=false", "-Dapple.laf.useScreenMenuBar=false"]
        return RebasedLaunch(libjvm: app.appendingPathComponent("Contents/jbr/Contents/Home/lib/server/libjvm.dylib").path,
                             options: options, mainClass: install.mainClass)
    }

    func launch(_ launch: RebasedLaunch) throws {
        let cOptions = launch.options.map { strdup($0) }
        defer { cOptions.forEach { free($0) } }
        let error = cOptions.map { UnsafePointer($0) }.withUnsafeBufferPointer {
            rb_start(launch.libjvm, $0.baseAddress, Int32(cOptions.count), launch.mainClass)
        }
        if let error { throw RebasedRuntimeError.failed(String(cString: error)) }
    }

    func bindEvents() -> RebasedRuntimeError? {
        guard let error = rb_register_events(rebasedEventCallback) else { return nil }
        let message = String(cString: error)
        return message == Self.notReady ? .notReady : .failed(message)
    }

    func call(_ command: String, _ argument: String) -> String {
        String(cString: rb_bridge_call(command, argument))
    }

    var jvmCreated: Bool { rb_jvm_created() }
}

// The shim frees both strings when this returns, so they are copied before the hop.
private func rebasedEventCallback(_ kind: UnsafePointer<CChar>?, _ payload: UnsafePointer<CChar>?) {
    guard let kind, let payload else { return }
    let name = String(cString: kind), body = String(cString: payload)
    DispatchQueue.main.async { RebasedHost.shared.handle(event: name, payload: body) }
}
