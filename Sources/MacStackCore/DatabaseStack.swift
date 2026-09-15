import Foundation

public enum DatabaseStackError: Error, LocalizedError {
    case installationMissing(String)
    case incompatibleExecutable(String)
    case refusesNonemptyUninitializedDirectory(String)
    case refusesSymbolicLink(String)
    case commandFailed(String, Int32, String)
    case socketPathTooLong(String)
    case exitedEarly(Int32)
    case healthCheckFailed(String)
    case stopTimedOut

    public var errorDescription: String? {
        switch self {
        case .installationMissing(let path): "缺少 MariaDB 组件：\(path)"
        case .incompatibleExecutable(let path): "MariaDB 可执行文件不包含 ARM64：\(path)"
        case .refusesNonemptyUninitializedDirectory(let path):
            "拒绝初始化非空且未识别的数据目录：\(path)。请先人工检查，MacStack 不会覆盖或重新初始化。"
        case .refusesSymbolicLink(let path): "拒绝把符号链接当作数据库目录：\(path)"
        case .commandFailed(let command, let status, let output):
            "MariaDB 命令失败（退出码 \(status)）：\(command)\n\(output)"
        case .socketPathTooLong(let path): "MariaDB socket 路径过长：\(path)"
        case .exitedEarly(let status): "MariaDB 启动后立即退出（退出码 \(status)），请查看日志。"
        case .healthCheckFailed(let detail): "MariaDB 健康检查失败：\(detail)"
        case .stopTimedOut: "MariaDB 未在限定时间内正常停止；未执行强制终止。"
        }
    }
}

/// MacStack 数据库客户端的公共参数。
///
/// **导出、导入、查询、执行 SQL 必须使用同一个字符集。** 这里做成单一来源，
/// 是因为曾经踩过一次：导出侧（`mariadb-dump`）指定了 `utf8mb4`，而导入、查询、
/// 执行三处沿用客户端默认字符集，结果含非 ASCII 内容的库在「导出 → 恢复」往返后
/// 变成乱码（`动态内容` → `Ŋ�ƀ�ņ�Ů�`）。当时三处各写一份参数，漏了谁也看不出来。
public enum DatabaseClientArguments {
    /// 客户端字符集参数。三处必须一致，不要在任何一处省略。
    public static let characterSet = ["--default-character-set=utf8mb4"]

    public static func standard(socket: URL, user: String) -> [String] {
        [
            "--no-defaults", "--protocol=socket", "--socket=\(socket.path)",
            "--user=\(user)"
        ] + characterSet
    }
}

public struct InstalledDatabaseStack: Equatable, Sendable {
    public let server: URL
    public let initializer: URL
    public let admin: URL
    public let client: URL
    public let dump: URL
    public let version: String
    public let baseDirectory: URL?
    public let isBundled: Bool

    public init(
        server: URL,
        initializer: URL,
        admin: URL,
        client: URL,
        dump: URL? = nil,
        version: String,
        baseDirectory: URL? = nil,
        isBundled: Bool = false
    ) {
        self.server = server
        self.initializer = initializer
        self.admin = admin
        self.client = client
        self.dump = dump ?? client.deletingLastPathComponent().appendingPathComponent("mariadb-dump")
        self.version = version
        self.baseDirectory = baseDirectory
        self.isBundled = isBundled
    }
}

public struct DatabaseStackResolver: Sendable {
    public let prefix: URL
    public let portableRuntimeRoot: URL?
    private let runner = FoundationCommandRunner()

    public init(
        prefix: URL = URL(fileURLWithPath: "/opt/homebrew"),
        portableRuntimeRoot: URL? = nil
    ) {
        self.prefix = prefix
        self.portableRuntimeRoot = portableRuntimeRoot
    }

    public func resolve() throws -> InstalledDatabaseStack {
        if let runtime = try PortableRuntimeLocator(explicitRoot: portableRuntimeRoot).locate() {
            let executables = [
                runtime.layout.mariaDBServer, runtime.layout.mariaDBInitializer,
                runtime.layout.mariaDBAdmin, runtime.layout.mariaDBClient, runtime.layout.mariaDBDump
            ]
            guard executables.allSatisfy({ FileManager.default.isExecutableFile(atPath: $0.path) }) else {
                throw DatabaseStackError.installationMissing(runtime.layout.mariaDBRoot.path)
            }
            guard isNative(runtime.layout.mariaDBServer), isNative(runtime.layout.mariaDBAdmin),
                  isNative(runtime.layout.mariaDBClient), isNative(runtime.layout.mariaDBDump) else {
                throw DatabaseStackError.incompatibleExecutable(runtime.layout.mariaDBServer.path)
            }
            return InstalledDatabaseStack(
                server: runtime.layout.mariaDBServer,
                initializer: runtime.layout.mariaDBInitializer,
                admin: runtime.layout.mariaDBAdmin,
                client: runtime.layout.mariaDBClient,
                dump: runtime.layout.mariaDBDump,
                version: "MariaDB \(runtime.manifest.mariaDBVersion) (MacStack runtime)",
                baseDirectory: runtime.layout.mariaDBRoot,
                isBundled: true
            )
        }
        let names = ["mariadb@11.4", "mariadb@10.11", "mariadb@11.8", "mariadb"]
        for name in names {
            let root = prefix.appendingPathComponent("opt/\(name)/bin")
            let server = root.appendingPathComponent("mariadbd").resolvingSymlinksInPath()
            let initializer = root.appendingPathComponent("mariadb-install-db").resolvingSymlinksInPath()
            let admin = root.appendingPathComponent("mariadb-admin").resolvingSymlinksInPath()
            let client = root.appendingPathComponent("mariadb").resolvingSymlinksInPath()
            let dump = root.appendingPathComponent("mariadb-dump").resolvingSymlinksInPath()
            let executables = [server, initializer, admin, client, dump]
            guard executables.allSatisfy({ FileManager.default.isExecutableFile(atPath: $0.path) }) else { continue }
            guard isNative(server), isNative(admin), isNative(client), isNative(dump) else {
                throw DatabaseStackError.incompatibleExecutable(server.path)
            }
            let result = try runner.run(executable: server, arguments: ["--version"])
            guard result.status == 0 else {
                throw DatabaseStackError.commandFailed(server.path + " --version", result.status, result.combinedOutput)
            }
            return InstalledDatabaseStack(
                server: server,
                initializer: initializer,
                admin: admin,
                client: client,
                dump: dump,
                version: VersionText.firstLine(result.combinedOutput)
            )
        }
        throw DatabaseStackError.installationMissing(prefix.appendingPathComponent("opt/mariadb@11.4/bin/mariadbd").path)
    }

    private func isNative(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096) else { return false }
        return MachOHeader.containsARM64(data)
    }
}

public struct PreparedDatabaseStack: Sendable {
    public let installation: InstalledDatabaseStack
    public let layout: RuntimeLayout
    public let initializedNow: Bool
}

public struct DatabaseStackPreparer: Sendable {
    private let runner = FoundationCommandRunner()
    public init() {}

    public func prepare(
        installation: InstalledDatabaseStack,
        preferences: Preferences,
        layout: RuntimeLayout = .applicationSupport(),
        operatingSystemUser: String = NSUserName()
    ) throws -> PreparedDatabaseStack {
        try preferences.validate()
        guard layout.databaseSocket.path.utf8.count < 100 else {
            throw DatabaseStackError.socketPathTooLong(layout.databaseSocket.path)
        }
        let files = FileManager.default
        for directory in [layout.configurationDirectory, layout.logDirectory, layout.runDirectory] {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        // 只轮转数据库自己的日志。日志目录是与 Web 共享的，准备数据库配置时
        // Web 可能正在运行；轮转整个目录会动到它仍持有写入句柄的 launcher 日志。
        _ = try LogMaintainer().rotate(directory: layout.logDirectory, prefixes: LogOwnership.database)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: layout.runDirectory.path)

        if let attributes = try? files.attributesOfItem(atPath: layout.databaseDirectory.path),
           attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            throw DatabaseStackError.refusesSymbolicLink(layout.databaseDirectory.path)
        }
        let initializedMarker = layout.databaseDirectory.appendingPathComponent("mysql", isDirectory: true)
        let ownershipMarker = layout.databaseDirectory.appendingPathComponent(".macstack-datadir-v1")
        var initializedNow = false
        if files.fileExists(atPath: initializedMarker.path) {
            if !files.fileExists(atPath: ownershipMarker.path) {
                // 0.3 初版在写入所有 MacStack 专属路径后才完成初始化；补写所有权标记，绝不重跑初始化。
                guard let existingConfig = try? String(contentsOf: layout.databaseConfiguration, encoding: .utf8),
                      existingConfig.contains("datadir=\(layout.databaseDirectory.path)") else {
                    throw DatabaseStackError.refusesNonemptyUninitializedDirectory(layout.databaseDirectory.path)
                }
                try Data("MacStack MariaDB data directory v1\n".utf8).write(to: ownershipMarker, options: .atomic)
            }
        } else {
            if files.fileExists(atPath: layout.databaseDirectory.path) {
                let contents = try files.contentsOfDirectory(atPath: layout.databaseDirectory.path)
                guard contents.isEmpty else {
                    throw DatabaseStackError.refusesNonemptyUninitializedDirectory(layout.databaseDirectory.path)
                }
            } else {
                try files.createDirectory(at: layout.databaseDirectory, withIntermediateDirectories: true)
            }
            let args = [
                "--no-defaults",
                installation.baseDirectory.map { "--basedir=\($0.path)" },
                "--datadir=\(layout.databaseDirectory.path)",
                "--auth-root-authentication-method=socket",
                "--auth-root-socket-user=\(operatingSystemUser)",
                "--skip-test-db"
            ].compactMap { $0 }
            let result = try runner.run(executable: installation.initializer, arguments: args)
            guard result.status == 0 else {
                throw DatabaseStackError.commandFailed(
                    ([installation.initializer.path] + args).joined(separator: " "),
                    result.status,
                    result.combinedOutput
                )
            }
            try Data("MacStack MariaDB data directory v1\n".utf8).write(to: ownershipMarker, options: .atomic)
            initializedNow = true
        }

        let portablePaths: String
        if let base = installation.baseDirectory {
            portablePaths = """
            basedir=\(base.path)
            plugin-dir=\(base.appendingPathComponent("lib/plugin").path)
            character-sets-dir=\(base.appendingPathComponent("share/mysql/charsets").path)
            lc-messages-dir=\(base.appendingPathComponent("share/mysql").path)
            """
        } else {
            portablePaths = ""
        }
        let config = """
        [mariadbd]
        \(portablePaths)
        datadir=\(layout.databaseDirectory.path)
        socket=\(layout.databaseSocket.path)
        pid-file=\(layout.databasePID.path)
        log-error=\(layout.logDirectory.appendingPathComponent("mariadb-error.log").path)
        bind-address=127.0.0.1
        port=\(preferences.databasePort)
        skip-name-resolve
        symbolic-links=0
        local-infile=0
        character-set-server=utf8mb4
        collation-server=utf8mb4_unicode_ci
        """
        try Data((config + "\n").utf8).write(to: layout.databaseConfiguration, options: .atomic)
        return PreparedDatabaseStack(installation: installation, layout: layout, initializedNow: initializedNow)
    }
}

public actor LocalDatabaseController: ServiceControlling {
    private let installation: InstalledDatabaseStack
    private let layout: RuntimeLayout
    private let databasePort: Int
    private let operatingSystemUser: String
    private var process: Process?
    private var logHandle: FileHandle?
    private let runner = FoundationCommandRunner()

    public init(
        installation: InstalledDatabaseStack,
        layout: RuntimeLayout,
        databasePort: Int,
        operatingSystemUser: String = NSUserName()
    ) {
        self.installation = installation
        self.layout = layout
        self.databasePort = databasePort
        self.operatingSystemUser = operatingSystemUser
    }

    public func start(_ component: Component) async throws {
        guard component == .mariadb else { throw ServiceControlError.unsupportedComponent }
        if let process, process.isRunning { return }
        cleanup()
        let launchLog = layout.logDirectory.appendingPathComponent("mariadb-launcher.log")
        // 与 LocalWebStackController 同理：此刻上一个写入句柄已关闭、新句柄未打开，
        // 是这个文件唯一安全的轮转时点。只轮转自己这一个文件。
        _ = try? LogMaintainer().rotate(
            directory: layout.logDirectory,
            prefixes: LogOwnership.database
        )
        if !FileManager.default.fileExists(atPath: launchLog.path) {
            FileManager.default.createFile(atPath: launchLog.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: launchLog)
        try handle.seekToEnd()
        let next = Process()
        next.executableURL = installation.server
        next.arguments = ["--defaults-file=\(layout.databaseConfiguration.path)"]
        next.standardOutput = handle
        next.standardError = handle
        do {
            try next.run()
            process = next
            logHandle = handle
        } catch {
            try? handle.close()
            throw error
        }
        try await Task.sleep(for: .milliseconds(300))
        guard next.isRunning else {
            let status = next.terminationStatus
            cleanup()
            throw DatabaseStackError.exitedEarly(status)
        }
    }

    public func stop(_ component: Component) async throws {
        guard component == .mariadb else { throw ServiceControlError.unsupportedComponent }
        guard let process else { return }
        guard process.isRunning else { cleanup(); return }
        let result = try runner.run(executable: installation.admin, arguments: clientArguments + ["shutdown"])
        guard result.status == 0 else {
            throw DatabaseStackError.commandFailed(
                ([installation.admin.path] + clientArguments + ["shutdown"]).joined(separator: " "),
                result.status,
                result.combinedOutput
            )
        }
        for _ in 0..<80 {
            if !process.isRunning { cleanup(); return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw DatabaseStackError.stopTimedOut
    }

    public func state(of component: Component) async -> ServiceState {
        guard component == .mariadb else { return .notConnected }
        guard let process else { return .stopped }
        if process.isRunning { return .running }
        let status = process.terminationStatus
        cleanup()
        return status == 0 ? .stopped : .failed("退出码 \(status)")
    }

    public func startAndCheck(credentials: DatabaseCredentials? = nil) async throws -> String {
        do {
            try await start(.mariadb)
            var lastDetail = "数据库尚未就绪。"
            for _ in 0..<50 {
                let result = try runner.run(
                    executable: installation.client,
                    arguments: clientArguments + ["--batch", "--skip-column-names", "--execute=SELECT VERSION();"]
                )
                if result.status == 0 {
                    if let credentials {
                        try provision(credentials)
                        try verify(credentials)
                    }
                    return VersionText.firstLine(result.combinedOutput)
                }
                lastDetail = result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                try await Task.sleep(for: .milliseconds(100))
            }
            throw DatabaseStackError.healthCheckFailed(lastDetail)
        } catch {
            try? await stop(.mariadb)
            throw error
        }
    }

    /// 客户端公共参数，见 `DatabaseClientArguments`。
    private var clientArguments: [String] {
        DatabaseClientArguments.standard(socket: layout.databaseSocket, user: operatingSystemUser)
    }

    private func provision(_ credentials: DatabaseCredentials) throws {
        guard credentials.username == "macstack",
              credentials.password.allSatisfy({ $0.isHexDigit }) else {
            throw DatabaseCredentialError.invalidStoredValue
        }
        let sql = """
        CREATE USER IF NOT EXISTS 'macstack'@'127.0.0.1' IDENTIFIED BY '\(credentials.password)';
        ALTER USER 'macstack'@'127.0.0.1' IDENTIFIED BY '\(credentials.password)';
        GRANT ALL PRIVILEGES ON *.* TO 'macstack'@'127.0.0.1';
        FLUSH PRIVILEGES;
        """
        let result = try runner.run(
            executable: installation.client,
            arguments: clientArguments,
            standardInput: Data(sql.utf8)
        )
        guard result.status == 0 else {
            throw DatabaseStackError.commandFailed(
                installation.client.path + " [SQL from standard input]",
                result.status,
                result.combinedOutput
            )
        }
    }

    private func verify(_ credentials: DatabaseCredentials) throws {
        let defaults = """
        [client]
        user=\(credentials.username)
        password=\(credentials.password)
        host=127.0.0.1
        port=\(databasePort)
        protocol=tcp
        """
        let result = try runner.run(
            executable: installation.client,
            arguments: [
                "--defaults-extra-file=/dev/stdin",
                "--batch", "--skip-column-names",
                "--execute=SELECT CURRENT_USER();"
            ],
            standardInput: Data((defaults + "\n").utf8)
        )
        guard result.status == 0,
              result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "macstack@127.0.0.1" else {
            throw DatabaseStackError.commandFailed(
                installation.client.path + " [credentials from pipe]",
                result.status,
                result.combinedOutput
            )
        }
    }

    private func cleanup() {
        process = nil
        try? logHandle?.synchronize()
        try? logHandle?.close()
        logHandle = nil
    }
}
