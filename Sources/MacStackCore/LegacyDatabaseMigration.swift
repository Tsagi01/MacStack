import Foundation

public struct LegacyDatabaseCredentials: Sendable {
    public let port: Int
    public let username: String
    public let password: String

    public init(port: Int = 3306, username: String = "root", password: String = "") {
        self.port = port
        self.username = username
        self.password = password
    }
}

public enum LegacyDatabaseMigrationError: Error, LocalizedError {
    case invalidCredentials
    case temporaryFileUnavailable(String)
    case connectionFailed(Int32, String)
    case databaseNotFound(String)
    case dumpFailed(Int32, String)

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials: "旧数据库端口、用户名或密码包含无法安全使用的内容。"
        case .temporaryFileUnavailable(let path):
            "无法创建存放旧数据库连接信息的临时文件：\(path)"
        case .connectionFailed(let status, let output): "无法连接旧 XAMPP 数据库（退出码 \(status)）：\n\(output)"
        case .databaseNotFound(let name): "旧数据库中没有找到 \(name)。"
        case .dumpFailed(let status, let output): "旧数据库逻辑导出失败（退出码 \(status)）：\n\(output)"
        }
    }
}

public struct LegacyDatabaseConnector: Sendable {
    public let installation: InstalledDatabaseStack

    public init(installation: InstalledDatabaseStack) {
        self.installation = installation
    }

    public func listDatabases(credentials: LegacyDatabaseCredentials) throws -> [String] {
        try withDefaultsFile(credentials) { defaults in
            let result = try FoundationCommandRunner().run(
                executable: installation.client,
                arguments: ["--defaults-file=\(defaults.path)", "--batch", "--skip-column-names", "--execute=SHOW DATABASES;"]
            )
            guard result.status == 0 else {
                throw LegacyDatabaseMigrationError.connectionFailed(result.status, result.combinedOutput)
            }
            return result.combinedOutput.split(whereSeparator: \.isNewline).map(String.init)
                .filter { !DatabaseBackupManager.systemDatabases.contains($0.lowercased()) }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
    }

    public func exportDatabase(
        named database: String,
        credentials: LegacyDatabaseCredentials,
        to destination: URL
    ) throws {
        guard try listDatabases(credentials: credentials).contains(database) else {
            throw LegacyDatabaseMigrationError.databaseNotFound(database)
        }
        try withDefaultsFile(credentials) { defaults in
            let errorFile = FileManager.default.temporaryDirectory.appendingPathComponent("macstack-legacy-dump-\(UUID().uuidString).stderr")
            defer { try? FileManager.default.removeItem(at: errorFile) }
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            FileManager.default.createFile(atPath: errorFile.path, contents: nil)
            let output = try FileHandle(forWritingTo: destination)
            let errors = try FileHandle(forWritingTo: errorFile)
            defer { try? output.close(); try? errors.close() }
            let process = Process()
            process.executableURL = installation.dump
            process.arguments = [
                "--defaults-file=\(defaults.path)", "--single-transaction", "--routines", "--events", "--triggers",
                "--hex-blob", "--default-character-set=utf8mb4",
                // `--` 终止选项解析：库名来自旧服务器，而 MariaDB 接受以 `-` 开头的库名，
                // 不加的话会被 mariadb-dump 当成选项（见 DatabaseBackup 里的同类修复）。
                "--databases", "--", database
            ]
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            process.waitUntilExit()
            try output.synchronize()
            try errors.synchronize()
            let errorText = (try? String(contentsOf: errorFile, encoding: .utf8)) ?? ""
            guard process.terminationStatus == 0 else {
                try? FileManager.default.removeItem(at: destination)
                throw LegacyDatabaseMigrationError.dumpFailed(process.terminationStatus, errorText)
            }
        }
    }

    /// 校验凭据并生成 `--defaults-file` 的内容。
    ///
    /// 抽成独立方法是为了可测：`withDefaultsFile` 之后会真的去连旧数据库，
    /// 测试里走不完整条路径，但转义与校验可以单独验证。
    static func defaultsFileContents(_ credentials: LegacyDatabaseCredentials) throws -> String {
        guard (1024...65535).contains(credentials.port),
              credentials.username.range(of: "^[A-Za-z0-9_.-]{1,64}$", options: .regularExpression) != nil,
              !credentials.password.contains("\0"), !credentials.password.contains("\n"), !credentials.password.contains("\r") else {
            throw LegacyDatabaseMigrationError.invalidCredentials
        }
        // 反斜杠必须先转，否则会把后面为引号加的转义再转一遍。
        let escaped = credentials.password
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        [client]
        host=127.0.0.1
        port=\(credentials.port)
        protocol=tcp
        user=\(credentials.username)
        password="\(escaped)"
        """
    }

    /// 以 0600 **创建**文件再写入，而不是写完再 chmod。
    ///
    /// `Data.write(options: .atomic)` 是先写临时文件再改名，改名到 chmod 之间文件带着
    /// 默认权限（0644），而里面已经是明文密码。一创建就带 0600 更稳。
    ///
    /// 实际暴露面：macOS 的 `$TMPDIR` 是 0700，其他用户进不去，所以那个窗口**当前不可
    /// 利用**。仍然这样写，是为了让「这个文件只有属主可读」成为文件自身的性质，而不是
    /// 依赖它恰好落在受保护的目录里。
    static func writeOwnerOnlyFile(contents: String, to url: URL) throws {
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw LegacyDatabaseMigrationError.temporaryFileUnavailable(url.path)
        }
        try Data((contents + "\n").utf8).write(to: url)
    }

    private func withDefaultsFile<T>(
        _ credentials: LegacyDatabaseCredentials,
        operation: (URL) throws -> T
    ) throws -> T {
        let contents = try Self.defaultsFileContents(credentials)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("macstack-legacy-\(UUID().uuidString).cnf")
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.writeOwnerOnlyFile(contents: contents, to: url)
        return try operation(url)
    }
}
