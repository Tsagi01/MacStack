import Foundation

public enum DatabaseBackupError: Error, LocalizedError {
    case databaseNotFound(String)
    case systemDatabase(String)
    case invalidDestination(String)
    case destinationExists(String)
    case invalidBackup(String)
    case commandFailed(String, Int32, String)
    case invalidDatabaseName
    case insufficientSpace(required: Int64, available: Int64)
    case restoreCancelled

    public var errorDescription: String? {
        switch self {
        case .databaseNotFound(let name): "没有找到数据库“\(name)”，请刷新数据库列表。"
        case .systemDatabase(let name): "“\(name)”是系统数据库，MacStack 不提供单库导出。"
        case .invalidDestination(let path): "备份目标无效或不可写：\(path)"
        case .destinationExists(let path): "目标文件已存在，未覆盖：\(path)"
        case .invalidBackup(let path): "SQL 备份不存在、为空、不是普通文件或是符号链接：\(path)"
        case .commandFailed(let command, let status, let output):
            "数据库备份命令失败（退出码 \(status)）：\(command)\n\(output)"
        case .invalidDatabaseName: "数据库名称必须以英文字母开头，只能包含英文字母、数字和下划线，最长 64 个字符。"
        case .insufficientSpace(let required, let available):
            "可用空间不足。建议至少保留 \(ByteCountFormatter.string(fromByteCount: required, countStyle: .file))，当前约 \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file))。"
        case .restoreCancelled: "SQL 恢复已取消。"
        }
    }
}

public struct DatabaseBackupManager: Sendable {
    public static let systemDatabases: Set<String> = [
        "information_schema", "mysql", "performance_schema", "sys"
    ]

    public let installation: InstalledDatabaseStack
    public let layout: RuntimeLayout
    private let operatingSystemUser: String
    private let runner = FoundationCommandRunner()

    public init(
        installation: InstalledDatabaseStack,
        layout: RuntimeLayout = .applicationSupport(),
        operatingSystemUser: String = NSUserName()
    ) {
        self.installation = installation
        self.layout = layout
        self.operatingSystemUser = operatingSystemUser
    }

    public func listDatabases() throws -> [String] {
        let result = try runner.run(
            executable: installation.client,
            arguments: clientArguments + ["--batch", "--skip-column-names", "--execute=SHOW DATABASES;"]
        )
        guard result.status == 0 else {
            throw DatabaseBackupError.commandFailed("mariadb SHOW DATABASES", result.status, result.combinedOutput)
        }
        return result.combinedOutput
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !Self.systemDatabases.contains($0.lowercased()) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public func createDatabase(named name: String) throws {
        let safeName = try validatedDatabaseName(name)
        try executeSQL("CREATE DATABASE IF NOT EXISTS `\(safeName)` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;")
    }

    public func dropDatabase(named name: String) throws {
        let safeName = try validatedDatabaseName(name)
        try executeSQL("DROP DATABASE IF EXISTS `\(safeName)`;")
    }

    public func exportDatabase(named database: String, to destination: URL) throws {
        guard !Self.systemDatabases.contains(database.lowercased()) else {
            throw DatabaseBackupError.systemDatabase(database)
        }
        let databases = try listDatabases()
        guard databases.contains(database) else { throw DatabaseBackupError.databaseNotFound(database) }
        guard FileManager.default.isExecutableFile(atPath: installation.dump.path) else {
            throw DatabaseStackError.installationMissing(installation.dump.path)
        }
        let target = destination.standardizedFileURL
        let parent = target.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard target.pathExtension.lowercased() == "sql",
              FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.isWritableFile(atPath: parent.path) else {
            throw DatabaseBackupError.invalidDestination(target.path)
        }
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw DatabaseBackupError.destinationExists(target.path)
        }

        let temporary = parent.appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString).partial")
        let errorFile = parent.appendingPathComponent(".macstack-dump-\(UUID().uuidString).stderr")
        defer {
            try? FileManager.default.removeItem(at: temporary)
            try? FileManager.default.removeItem(at: errorFile)
        }
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        FileManager.default.createFile(atPath: errorFile.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: temporary)
        let errorHandle = try FileHandle(forWritingTo: errorFile)
        defer {
            try? outputHandle.close()
            try? errorHandle.close()
        }
        let process = Process()
        process.executableURL = installation.dump
        process.arguments = clientArguments + [
            "--single-transaction", "--routines", "--events", "--triggers", "--hex-blob",
            "--databases", database
        ]
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        try process.run()
        process.waitUntilExit()
        try outputHandle.synchronize()
        try errorHandle.synchronize()
        let errorText = (try? String(contentsOf: errorFile, encoding: .utf8)) ?? ""
        guard process.terminationStatus == 0 else {
            throw DatabaseBackupError.commandFailed("mariadb-dump \(database)", process.terminationStatus, errorText)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
        guard (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0 else {
            throw DatabaseBackupError.invalidBackup(temporary.path)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        try FileManager.default.moveItem(at: temporary, to: target)
    }

    public func restoreBackup(from source: URL) throws {
        let input = source.standardizedFileURL
        guard input.pathExtension.lowercased() == "sql",
              let attributes = try? FileManager.default.attributesOfItem(atPath: input.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0 else {
            throw DatabaseBackupError.invalidBackup(input.path)
        }
        let errorFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("macstack-restore-\(UUID().uuidString).stderr")
        defer { try? FileManager.default.removeItem(at: errorFile) }
        FileManager.default.createFile(atPath: errorFile.path, contents: nil)
        let inputHandle = try FileHandle(forReadingFrom: input)
        let errorHandle = try FileHandle(forWritingTo: errorFile)
        defer {
            try? inputHandle.close()
            try? errorHandle.close()
        }
        let process = Process()
        process.executableURL = installation.client
        process.arguments = clientArguments
        process.standardInput = inputHandle
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorHandle
        try process.run()
        process.waitUntilExit()
        try errorHandle.synchronize()
        let errorText = (try? String(contentsOf: errorFile, encoding: .utf8)) ?? ""
        guard process.terminationStatus == 0 else {
            throw DatabaseBackupError.commandFailed("mariadb restore", process.terminationStatus, errorText)
        }
    }

    public func executeSQL(_ sql: String) throws {
        let result = try runner.run(
            executable: installation.client,
            arguments: clientArguments,
            standardInput: Data(sql.utf8)
        )
        guard result.status == 0 else {
            throw DatabaseBackupError.commandFailed("mariadb SQL", result.status, result.combinedOutput)
        }
    }

    public func query(_ sql: String) throws -> String {
        let result = try runner.run(
            executable: installation.client,
            arguments: clientArguments + ["--batch", "--skip-column-names", "--execute=\(sql)"]
        )
        guard result.status == 0 else {
            throw DatabaseBackupError.commandFailed("mariadb query", result.status, result.combinedOutput)
        }
        return result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 客户端公共参数，见 `DatabaseClientArguments`。
    ///
    /// 导出、导入、查询必须使用同一个字符集，缺一不可 —— 详见该类型的说明。
    private var clientArguments: [String] {
        DatabaseClientArguments.standard(socket: layout.databaseSocket, user: operatingSystemUser)
    }

    private func validatedDatabaseName(_ name: String) throws -> String {
        let expression = try! NSRegularExpression(pattern: "^[A-Za-z][A-Za-z0-9_]{0,63}$")
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        guard expression.firstMatch(in: name, range: range) != nil else {
            throw DatabaseBackupError.invalidDatabaseName
        }
        return name
    }
}
