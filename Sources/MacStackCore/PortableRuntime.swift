import Foundation

public enum PortableRuntimeError: Error, LocalizedError {
    case invalidManifest(String)
    case unsupportedSchema(Int)
    case unsupportedArchitecture(String)
    case missingFile(String)

    public var errorDescription: String? {
        switch self {
        case .invalidManifest(let detail): "MacStack 便携运行时清单无效：\(detail)"
        case .unsupportedSchema(let version): "MacStack 便携运行时清单版本 \(version) 不受支持。"
        case .unsupportedArchitecture(let architecture): "便携运行时架构为 \(architecture)，当前版本只支持 arm64。"
        case .missingFile(let path): "便携运行时不完整，缺少：\(path)"
        }
    }
}

/// Describes the server payload shipped inside MacStack.app. Versions live in
/// the manifest so detection does not need to launch an incomplete payload.
public struct PortableRuntimeManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let runtimeVersion: String
    public let architecture: String
    public let apacheVersion: String
    public let phpVersion: String
    public let phpFormula: String
    public let phpAPI: String
    public let mariaDBVersion: String
    public let phpMyAdminVersion: String

    public init(
        schemaVersion: Int = 1,
        runtimeVersion: String,
        architecture: String = "arm64",
        apacheVersion: String,
        phpVersion: String,
        phpFormula: String,
        phpAPI: String,
        mariaDBVersion: String,
        phpMyAdminVersion: String
    ) {
        self.schemaVersion = schemaVersion
        self.runtimeVersion = runtimeVersion
        self.architecture = architecture
        self.apacheVersion = apacheVersion
        self.phpVersion = phpVersion
        self.phpFormula = phpFormula
        self.phpAPI = phpAPI
        self.mariaDBVersion = mariaDBVersion
        self.phpMyAdminVersion = phpMyAdminVersion
    }
}

public struct PortableRuntimeLayout: Equatable, Sendable {
    public let root: URL
    public var manifest: URL { root.appendingPathComponent("manifest.json") }
    public var libraryDirectory: URL { root.appendingPathComponent("lib", isDirectory: true) }
    public var apacheRoot: URL { root.appendingPathComponent("apache", isDirectory: true) }
    public var apache: URL { apacheRoot.appendingPathComponent("bin/httpd") }
    public var phpRoot: URL { root.appendingPathComponent("php", isDirectory: true) }
    public var php: URL { phpRoot.appendingPathComponent("bin/php") }
    public var phpFPM: URL { phpRoot.appendingPathComponent("sbin/php-fpm") }
    public func phpExtensionDirectory(api: String) -> URL {
        phpRoot.appendingPathComponent("lib/php/\(api)", isDirectory: true)
    }
    public var mariaDBRoot: URL { root.appendingPathComponent("mariadb", isDirectory: true) }
    public var mariaDBServer: URL { mariaDBRoot.appendingPathComponent("bin/mariadbd") }
    public var mariaDBInitializer: URL { mariaDBRoot.appendingPathComponent("bin/mariadb-install-db") }
    public var mariaDBAdmin: URL { mariaDBRoot.appendingPathComponent("bin/mariadb-admin") }
    public var mariaDBClient: URL { mariaDBRoot.appendingPathComponent("bin/mariadb") }
    public var mariaDBDump: URL { mariaDBRoot.appendingPathComponent("bin/mariadb-dump") }
    public var phpMyAdmin: URL { root.appendingPathComponent("phpmyadmin", isDirectory: true) }

    public init(root: URL) { self.root = root.standardizedFileURL }
}

public struct PortableRuntime: Equatable, Sendable {
    public let manifest: PortableRuntimeManifest
    public let layout: PortableRuntimeLayout
}

public struct PortableRuntimeLocator: Sendable {
    public let explicitRoot: URL?
    public let environment: [String: String]

    public init(
        explicitRoot: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.explicitRoot = explicitRoot
        self.environment = environment
    }

    /// Returns nil only when no portable payload is present. A present but
    /// damaged payload throws instead of silently falling back to Homebrew.
    public func locate() throws -> PortableRuntime? {
        let root: URL
        if let explicitRoot {
            root = explicitRoot
        } else if let override = environment["MACSTACK_RUNTIME_ROOT"], !override.isEmpty {
            root = URL(fileURLWithPath: override, isDirectory: true)
        } else if let resources = Bundle.main.resourceURL {
            root = resources.appendingPathComponent("runtime", isDirectory: true)
        } else {
            return nil
        }
        let layout = PortableRuntimeLayout(root: root)
        guard FileManager.default.fileExists(atPath: layout.manifest.path) else { return nil }
        let manifest: PortableRuntimeManifest
        do {
            manifest = try JSONDecoder().decode(PortableRuntimeManifest.self, from: Data(contentsOf: layout.manifest))
        } catch {
            throw PortableRuntimeError.invalidManifest(error.localizedDescription)
        }
        guard manifest.schemaVersion == 1 else { throw PortableRuntimeError.unsupportedSchema(manifest.schemaVersion) }
        guard manifest.architecture == "arm64" else {
            throw PortableRuntimeError.unsupportedArchitecture(manifest.architecture)
        }
        let required = [
            layout.apache, layout.php, layout.phpFPM,
            layout.mariaDBServer, layout.mariaDBInitializer, layout.mariaDBAdmin,
            layout.mariaDBClient, layout.mariaDBDump,
            layout.phpMyAdmin.appendingPathComponent("index.php")
        ]
        for url in required where !FileManager.default.fileExists(atPath: url.path) {
            throw PortableRuntimeError.missingFile(url.path)
        }
        return PortableRuntime(manifest: manifest, layout: layout)
    }
}
