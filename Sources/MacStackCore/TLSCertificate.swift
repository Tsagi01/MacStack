import Foundation

public struct TLSCertificate: Equatable, Sendable {
    public let certificate: URL
    public let privateKey: URL
    public let hostnames: [String]
}

public enum TLSCertificateError: Error, LocalizedError {
    case opensslMissing
    case certificateMissing
    case generationFailed(Int32, String)
    case trustFailed(Int32, String)

    public var errorDescription: String? {
        switch self {
        case .opensslMissing: "没有找到可用的 OpenSSL，无法生成本地 HTTPS 证书。"
        case .certificateMissing: "尚未生成 MacStack 本地 HTTPS 证书。"
        case .generationFailed(let status, let output): "本地 HTTPS 证书生成失败（退出码 \(status)）：\n\(output)"
        case .trustFailed(let status, let output): "证书未能加入当前用户钥匙串（退出码 \(status)）：\n\(output)"
        }
    }
}

public struct TLSCertificateManager: Sendable {
    public init() {}

    public func prepare(hostnames: [String], layout: RuntimeLayout = .applicationSupport()) throws -> TLSCertificate {
        let hosts = Array(Set(hostnames + ["localhost"])).sorted()
        let marker = hosts.joined(separator: "\n") + "\n"
        let files = FileManager.default
        if files.fileExists(atPath: layout.tlsCertificate.path),
           files.fileExists(atPath: layout.tlsPrivateKey.path),
           (try? String(contentsOf: layout.tlsHostsMarker, encoding: .utf8)) == marker {
            return TLSCertificate(certificate: layout.tlsCertificate, privateKey: layout.tlsPrivateKey, hostnames: hosts)
        }
        try files.createDirectory(at: layout.tlsDirectory, withIntermediateDirectories: true)
        let openssl = [
            URL(fileURLWithPath: "/opt/homebrew/opt/openssl@3/bin/openssl"),
            URL(fileURLWithPath: "/usr/bin/openssl")
        ].first { files.isExecutableFile(atPath: $0.path) }
        guard let openssl else { throw TLSCertificateError.opensslMissing }
        let temporaryKey = layout.tlsDirectory.appendingPathComponent(".localhost-\(UUID().uuidString).key")
        let temporaryCertificate = layout.tlsDirectory.appendingPathComponent(".localhost-\(UUID().uuidString).crt")
        defer {
            try? files.removeItem(at: temporaryKey)
            try? files.removeItem(at: temporaryCertificate)
        }
        let names = hosts.map { "DNS:\($0)" }.joined(separator: ",") + ",IP:127.0.0.1"
        let result = try FoundationCommandRunner().run(
            executable: openssl,
            arguments: [
                "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "825",
                "-subj", "/CN=localhost", "-addext", "subjectAltName=\(names)",
                "-keyout", temporaryKey.path, "-out", temporaryCertificate.path
            ]
        )
        guard result.status == 0 else { throw TLSCertificateError.generationFailed(result.status, result.combinedOutput) }
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryKey.path)
        if files.fileExists(atPath: layout.tlsPrivateKey.path) { try files.removeItem(at: layout.tlsPrivateKey) }
        if files.fileExists(atPath: layout.tlsCertificate.path) { try files.removeItem(at: layout.tlsCertificate) }
        try files.moveItem(at: temporaryKey, to: layout.tlsPrivateKey)
        try files.moveItem(at: temporaryCertificate, to: layout.tlsCertificate)
        try Data(marker.utf8).write(to: layout.tlsHostsMarker, options: .atomic)
        return TLSCertificate(certificate: layout.tlsCertificate, privateKey: layout.tlsPrivateKey, hostnames: hosts)
    }

    public func trustForCurrentUser(layout: RuntimeLayout = .applicationSupport()) throws {
        guard FileManager.default.fileExists(atPath: layout.tlsCertificate.path) else {
            throw TLSCertificateError.certificateMissing
        }
        let keychain = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Keychains/login.keychain-db")
        let result = try FoundationCommandRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/security"),
            arguments: ["add-trusted-cert", "-d", "-r", "trustRoot", "-k", keychain.path, layout.tlsCertificate.path]
        )
        guard result.status == 0 else { throw TLSCertificateError.trustFailed(result.status, result.combinedOutput) }
    }
}
