import Foundation
import Security

public enum PHPMyAdminError: Error, LocalizedError {
    case installationMissing(String)
    case unrecognizedDestination(String)
    case versionMismatch(installed: String, copied: String)
    case invalidSecret
    case randomGeneration(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .installationMissing(let path): "缺少 phpMyAdmin：\(path)"
        case .unrecognizedDestination(let path): "phpMyAdmin 目标目录非空且没有 MacStack 标记，拒绝覆盖：\(path)"
        case .versionMismatch(let installed, let copied):
            "Homebrew phpMyAdmin 为 \(installed)，MacStack 副本为 \(copied)；请使用显式更新流程，未自动覆盖。"
        case .invalidSecret: "phpMyAdmin cookie 密钥文件格式无效，未覆盖原文件。"
        case .randomGeneration(let status): "无法生成 phpMyAdmin cookie 密钥（状态码 \(status)）。"
        }
    }
}

public struct InstalledPHPMyAdmin: Equatable, Sendable {
    public let source: URL
    public let version: String
}

public struct PHPMyAdminResolver: Sendable {
    public let prefix: URL
    public let portableRuntimeRoot: URL?
    public init(
        prefix: URL = URL(fileURLWithPath: "/opt/homebrew"),
        portableRuntimeRoot: URL? = nil
    ) {
        self.prefix = prefix
        self.portableRuntimeRoot = portableRuntimeRoot
    }

    public func resolve() throws -> InstalledPHPMyAdmin {
        if let runtime = try PortableRuntimeLocator(explicitRoot: portableRuntimeRoot).locate() {
            return InstalledPHPMyAdmin(
                source: runtime.layout.phpMyAdmin,
                version: runtime.manifest.phpMyAdminVersion
            )
        }
        let source = prefix.appendingPathComponent("share/phpmyadmin").resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: source.appendingPathComponent("index.php").path) else {
            throw PHPMyAdminError.installationMissing(source.path)
        }
        let share = source.deletingLastPathComponent()
        let cellarVersion = share.deletingLastPathComponent().lastPathComponent
        return InstalledPHPMyAdmin(source: source, version: cellarVersion)
    }
}

public struct PreparedPHPMyAdmin: Sendable {
    public let version: String
    public let directory: URL
    public let copiedNow: Bool
}

public struct PHPMyAdminPreparer: Sendable {
    public init() {}

    public func prepare(
        installation: InstalledPHPMyAdmin,
        databasePort: Int,
        layout: RuntimeLayout = .applicationSupport()
    ) throws -> PreparedPHPMyAdmin {
        let files = FileManager.default
        try files.createDirectory(at: layout.root, withIntermediateDirectories: true)
        try files.createDirectory(at: layout.configurationDirectory, withIntermediateDirectories: true)
        try files.createDirectory(at: layout.phpMyAdminTempDirectory, withIntermediateDirectories: true)

        let marker = layout.phpMyAdminDirectory.appendingPathComponent(".macstack-phpmyadmin-version")
        var copiedNow = false
        if files.fileExists(atPath: layout.phpMyAdminDirectory.path) {
            guard let copiedVersion = try? String(contentsOf: marker, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw PHPMyAdminError.unrecognizedDestination(layout.phpMyAdminDirectory.path)
            }
            guard copiedVersion == installation.version else {
                throw PHPMyAdminError.versionMismatch(installed: installation.version, copied: copiedVersion)
            }
        } else {
            let staging = layout.root.appendingPathComponent(".phpmyadmin-staging-\(UUID())", isDirectory: true)
            do {
                try files.copyItem(at: installation.source, to: staging)
                let stagedConfig = staging.appendingPathComponent("config.inc.php")
                if files.fileExists(atPath: stagedConfig.path) || (try? files.destinationOfSymbolicLink(atPath: stagedConfig.path)) != nil {
                    try files.removeItem(at: stagedConfig)
                }
                try Data((installation.version + "\n").utf8)
                    .write(to: staging.appendingPathComponent(".macstack-phpmyadmin-version"), options: .atomic)
                try files.moveItem(at: staging, to: layout.phpMyAdminDirectory)
                copiedNow = true
            } catch {
                try? files.removeItem(at: staging)
                throw error
            }
        }

        let secret = try loadOrCreateSecret(layout: layout)
        let temporary = phpQuote(layout.phpMyAdminTempDirectory.path)
        let config = """
        <?php
        declare(strict_types=1);
        $cfg['blowfish_secret'] = sodium_hex2bin('\(secret)');
        $i = 0;
        $i++;
        $cfg['Servers'][$i]['auth_type'] = 'cookie';
        $cfg['Servers'][$i]['host'] = '127.0.0.1';
        $cfg['Servers'][$i]['port'] = '\(databasePort)';
        $cfg['Servers'][$i]['compress'] = false;
        $cfg['Servers'][$i]['AllowNoPassword'] = false;
        $cfg['Servers'][$i]['ssl'] = false;
        $cfg['TempDir'] = '\(temporary)';
        $cfg['LoginCookieValidity'] = 28800;
        """
        let configURL = layout.phpMyAdminDirectory.appendingPathComponent("config.inc.php")
        try Data((config + "\n").utf8).write(to: configURL, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        return PreparedPHPMyAdmin(version: installation.version, directory: layout.phpMyAdminDirectory, copiedNow: copiedNow)
    }

    private func loadOrCreateSecret(layout: RuntimeLayout) throws -> String {
        let files = FileManager.default
        if files.fileExists(atPath: layout.phpMyAdminSecret.path) {
            guard let secret = try? String(contentsOf: layout.phpMyAdminSecret, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  secret.count == 64, secret.allSatisfy({ $0.isHexDigit }) else {
                throw PHPMyAdminError.invalidSecret
            }
            return secret
        }
        var random = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, random.count, &random)
        guard status == errSecSuccess else { throw PHPMyAdminError.randomGeneration(status) }
        let secret = random.map { String(format: "%02x", $0) }.joined()
        try Data((secret + "\n").utf8).write(to: layout.phpMyAdminSecret, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: layout.phpMyAdminSecret.path)
        return secret
    }

    private func phpQuote(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\0", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
    }
}
