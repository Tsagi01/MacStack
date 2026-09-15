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
    case connectionFailed(Int32, String)
    case databaseNotFound(String)
    case dumpFailed(Int32, String)

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials: "旧数据库端口、用户名或密码包含无法安全使用的内容。"
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
                "--hex-blob", "--default-character-set=utf8mb4", "--databases", database
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

    private func withDefaultsFile<T>(
        _ credentials: LegacyDatabaseCredentials,
        operation: (URL) throws -> T
    ) throws -> T {
        guard (1024...65535).contains(credentials.port),
              credentials.username.range(of: "^[A-Za-z0-9_.-]{1,64}$", options: .regularExpression) != nil,
              !credentials.password.contains("\0"), !credentials.password.contains("\n"), !credentials.password.contains("\r") else {
            throw LegacyDatabaseMigrationError.invalidCredentials
        }
        let escaped = credentials.password
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let contents = """
        [client]
        host=127.0.0.1
        port=\(credentials.port)
        protocol=tcp
        user=\(credentials.username)
        password="\(escaped)"
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("macstack-legacy-\(UUID().uuidString).cnf")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data((contents + "\n").utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return try operation(url)
    }
}
