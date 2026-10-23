import Foundation

public struct RebasedInstall: Sendable {
    public struct FileInput: Sendable {
        public let path: String
        public let contents: String?

        public init(path: String, contents: String?) {
            self.path = path
            self.contents = contents
        }

        func requiredContents() throws -> String {
            guard let contents else { throw InstallError.missingFile(path) }
            return contents
        }
    }

    public enum InstallError: Error, Equatable, LocalizedError {
        case missingFile(String)
        case invalidFile(String, String)
        case missingLaunch(architecture: String)
        case javaVersion(required: Int, runtime: String)

        public var errorDescription: String? {
            switch self {
            case let .missingFile(path): "Rebased file is missing: \(path)"
            case let .invalidFile(path, detail): "Invalid Rebased file \(path): \(detail)"
            case let .missingLaunch(architecture): "Rebased has no macOS launch entry for \(architecture)"
            case let .javaVersion(required, runtime): "Rebased requires Java \(required), but the bundled runtime is Java \(runtime)"
            }
        }
    }

    public let buildNumber: String
    public let mainClass: String
    public let jvmOptions: [String]

    public static var nativeArchitecture: String {
        #if arch(arm64)
        "aarch64"
        #else
        "x86_64"
        #endif
    }

    public init(bundlePath: String, stateDirectory: String, productInfo: FileInput, vmOptions: FileInput,
                runtimeRelease: FileInput, architecture: String = RebasedInstall.nativeArchitecture,
                homeDirectory: String = NSHomeDirectory()) throws {
        let product = try RebasedProduct(bundlePath: bundlePath, productInfo: productInfo, architecture: architecture)
        try self.init(bundlePath: bundlePath, stateDirectory: stateDirectory, product: product, vmOptions: vmOptions,
                      runtimeRelease: runtimeRelease, homeDirectory: homeDirectory)
    }

    public init(bundlePath: String, stateDirectory: String, product: RebasedProduct, vmOptions: FileInput,
                agtermVmOptions: String? = nil, runtimeRelease: FileInput, homeDirectory: String = NSHomeDirectory()) throws {
        let optionsText = try vmOptions.requiredContents()
        let releaseText = try runtimeRelease.requiredContents()
        let launch = product.launch
        let runtimeVersion = try Self.runtimeVersion(releaseText, path: runtimeRelease.path)
        guard runtimeVersion.major >= product.minRequiredJavaVersion else {
            throw InstallError.javaVersion(required: product.minRequiredJavaVersion, runtime: runtimeVersion.text)
        }

        buildNumber = product.buildNumber
        mainClass = launch.mainClass
        let root = product.ideRoot(stateDirectory: URL(fileURLWithPath: stateDirectory)).path
        let lib = URL(fileURLWithPath: bundlePath).appendingPathComponent("Contents/lib")
        let classPath = launch.bootClassPathJarNames.map { lib.appendingPathComponent($0).path }.joined(separator: ":")
        let hostOptions = [
            "-XX:ErrorFile=\(root)/log/java_error_in_agterm_%p.log",
            "-XX:HeapDumpPath=\(root)/log/java_error_in_agterm.hprof",
            "-Djava.class.path=\(classPath)",
            "-Didea.config.path=\(root)/config", "-Didea.system.path=\(root)/system",
            "-Didea.plugins.path=\(root)/plugins", "-Didea.log.path=\(root)/log",
            "-Dide.native.launcher=true", "-Dsun.java.command=\(launch.mainClass)",
            "-DjbScreenMenuBar.enabled=false", "-Dapple.laf.useScreenMenuBar=false"
        ]
        let options = Self.options(optionsText) + launch.additionalJvmArguments + Self.options(agtermVmOptions ?? "") + hostOptions
        jvmOptions = options.map { $0.replacingOccurrences(of: "$APP_PACKAGE", with: bundlePath)
                .replacingOccurrences(of: "$USER_HOME", with: homeDirectory) }
    }

    public static func pluginCacheKey(buildNumber: String, sourceDigest: String) -> String {
        "\(buildNumber.utf8.count):\(buildNumber)\(sourceDigest.utf8.count):\(sourceDigest)"
    }

    private static func options(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    private static func runtimeVersion(_ contents: String, path: String) throws -> (text: String, major: Int) {
        for line in contents.components(separatedBy: .newlines) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0] == "JAVA_VERSION" else { continue }
            let version = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard let major = Int(version.prefix(while: { $0.isNumber })) else { break }
            return (version, major)
        }
        throw InstallError.invalidFile(path, "missing or invalid JAVA_VERSION")
    }
}
