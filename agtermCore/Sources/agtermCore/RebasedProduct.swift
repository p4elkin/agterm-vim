import Foundation

public struct RebasedProduct: Sendable {
    public struct Launch: Decodable, Sendable {
        public let os: String
        public let arch: String
        public let mainClass: String
        public let vmOptionsFilePath: String
        public let bootClassPathJarNames: [String]
        public let additionalJvmArguments: [String]
    }

    public let name: String
    public let dataDirectoryName: String
    public let buildNumber: String
    public let minRequiredJavaVersion: Int
    public let launch: Launch
    public let vmOptionsPath: String
    /// `layout` entries of kind `plugin`: plugin id to class path, relative to `Contents`.
    public let pluginClassPaths: [String: [String]]

    public init(bundlePath: String, productInfo: RebasedInstall.FileInput,
                architecture: String = RebasedInstall.nativeArchitecture) throws {
        let text = try productInfo.requiredContents()
        let info: ProductInfo
        do {
            info = try JSONDecoder().decode(ProductInfo.self, from: Data(text.utf8))
        } catch {
            throw RebasedInstall.InstallError.invalidFile(productInfo.path, error.localizedDescription)
        }
        guard !info.dataDirectoryName.isEmpty, info.dataDirectoryName != ".", info.dataDirectoryName != "..",
              !info.dataDirectoryName.contains("/"), !info.dataDirectoryName.contains("\0") else {
            throw RebasedInstall.InstallError.invalidFile(productInfo.path, "dataDirectoryName must be a single path component")
        }
        guard let launch = info.launch.first(where: { $0.os == "macOS" && $0.arch == architecture }) else {
            throw RebasedInstall.InstallError.missingLaunch(architecture: architecture)
        }
        name = info.name
        dataDirectoryName = info.dataDirectoryName
        buildNumber = info.buildNumber
        minRequiredJavaVersion = info.minRequiredJavaVersion
        self.launch = launch
        let launcherDirectory = URL(fileURLWithPath: bundlePath).appendingPathComponent("Contents/MacOS", isDirectory: true)
        vmOptionsPath = URL(fileURLWithPath: launch.vmOptionsFilePath, relativeTo: launcherDirectory).standardizedFileURL.path
        pluginClassPaths = Dictionary((info.layout ?? []).filter { $0.kind == "plugin" }.map { ($0.name, $0.classPath ?? []) }) { first, _ in first }
    }

    public func ideRoot(stateDirectory: URL) -> URL {
        let root = stateDirectory.appendingPathComponent("rebased", isDirectory: true)
        return name == "Rebased" ? root : root.appendingPathComponent("ide", isDirectory: true).appendingPathComponent(dataDirectoryName, isDirectory: true)
    }

    private struct ProductInfo: Decodable {
        let name: String
        let dataDirectoryName: String
        let buildNumber: String
        let minRequiredJavaVersion: Int
        let launch: [Launch]
        let layout: [LayoutEntry]?
    }

    private struct LayoutEntry: Decodable {
        let name: String
        let kind: String
        let classPath: [String]?
    }
}
