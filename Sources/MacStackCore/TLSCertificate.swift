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

    /// 以 0600 预先创建一个**空的**私钥文件。
    ///
    /// 抽成独立方法是为了可测：真正要保证的性质（「openssl 落盘私钥时它已经是 0600」）
    /// 在事后观测不到——openssl 退出后 `prepare` 还会再设一次权限，最终权限两种情况
    /// 都是 0600。能确定性验证的是这一步本身：建出的文件必须是空且 0600。
    ///
    /// 空文件不会泄露任何东西，所以「建文件」与「chmod」之间的极短窗口是安全的。
    static func preparePrivateKeyFile(at url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw TLSCertificateError.generationFailed(-1, "无法创建私钥临时文件：\(url.path)")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

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
        // **先**把私钥文件建好并设成 0600，再让 openssl 写入。
        //
        // openssl 自己创建文件时用的是 `0666 & ~umask`（实测 0644），而权限是在它退出
        // **之后**才改的，中间那几毫秒私钥已经落盘。`open()` 只在文件不存在时才应用
        // mode 参数，所以预先建好就能让 openssl 沿用 0600。
        //
        // 关于实际暴露面（别把这条读得比它实际更严重）：macOS 上
        // `~/Library/Application Support` 是 0700，其他用户无法进入，因此这个窗口
        // **当前不可利用**。之所以仍然修，是因为「私钥文件从创建起就不可被他人读取」
        // 应当是这个文件自身的性质，而不是依赖它恰好被放在某个受保护的目录里——
        // 换一个存放位置（或那个目录的权限被改动）就会变成真问题。
        try Self.preparePrivateKeyFile(at: temporaryKey)
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
        // 文件是预先以 0600 建好的，这里再设一次只是兜底（例如 openssl 中途替换过文件）。
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
