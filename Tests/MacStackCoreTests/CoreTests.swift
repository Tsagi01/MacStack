import Foundation
import Testing
@testable import MacStackCore

@Test func nativeAndIntelHeaders() {
    #expect(MachOHeader.containsARM64(Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 1])))
    #expect(!MachOHeader.containsARM64(Data([0xcf, 0xfa, 0xed, 0xfe, 7, 0, 0, 1])))
    #expect(!MachOHeader.containsARM64(Data("#!/bin/sh".utf8)))
    #expect(!MachOHeader.containsARM64(Data([0xcf])))
    #expect(MachOHeader.architectures(Data([0xcf, 0xfa, 0xed, 0xfe, 7, 0, 0, 1])) == ["x86_64"])
}

@Test func portableRuntimeIsPreferredAndSuppliesPrivatePaths() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacStackPortable-\(UUID())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let layout = PortableRuntimeLayout(root: root)
    let manifest = PortableRuntimeManifest(
        runtimeVersion: "test-1", apacheVersion: "2.4.test", phpVersion: "8.2.test",
        phpFormula: "php@8.2", phpAPI: "20220829", mariaDBVersion: "11.4.test",
        phpMyAdminVersion: "5.2.test"
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try JSONEncoder().encode(manifest).write(to: layout.manifest)
    let required = [
        layout.apache, layout.php, layout.phpFPM, layout.mariaDBServer,
        layout.mariaDBInitializer, layout.mariaDBAdmin, layout.mariaDBClient, layout.mariaDBDump
    ]
    let arm64Header = Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 1])
    for url in required {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try arm64Header.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    try FileManager.default.createDirectory(at: layout.phpMyAdmin, withIntermediateDirectories: true)
    try Data("<?php".utf8).write(to: layout.phpMyAdmin.appendingPathComponent("index.php"))

    let web = try WebStackResolver(
        prefix: URL(fileURLWithPath: "/definitely-missing"),
        preferredFormula: "auto",
        portableRuntimeRoot: root
    ).resolve()
    #expect(web.isBundled)
    #expect(web.apache == layout.apache)
    #expect(web.phpExtensionDirectory == layout.phpExtensionDirectory(api: manifest.phpAPI))
    let database = try DatabaseStackResolver(
        prefix: URL(fileURLWithPath: "/definitely-missing"),
        portableRuntimeRoot: root
    ).resolve()
    #expect(database.isBundled)
    #expect(database.baseDirectory == layout.mariaDBRoot)
    let phpMyAdmin = try PHPMyAdminResolver(
        prefix: URL(fileURLWithPath: "/definitely-missing"),
        portableRuntimeRoot: root
    ).resolve()
    #expect(phpMyAdmin.source == layout.phpMyAdmin)
    #expect(ComponentDetector(prefix: URL(fileURLWithPath: "/definitely-missing"), portableRuntimeRoot: root)
        .inspect(.apache).detail.contains("不需要 Homebrew"))
}

@Test func portableRuntimeConfigurationUsesBundledPHPAndMariaDBResources() throws {
    let root = URL(fileURLWithPath: "/tmp/ms-pc-\(UUID().uuidString.prefix(8))", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = PortableRuntimeLayout(root: root.appendingPathComponent("payload"))
    let service = RuntimeLayout(root: root.appendingPathComponent("service"))
    let web = InstalledWebStack(
        apache: runtime.apache, php: runtime.php, phpFPM: runtime.phpFPM,
        apacheVersion: "test", phpVersion: "test", phpRoot: runtime.phpRoot,
        phpExtensionDirectory: runtime.phpExtensionDirectory(api: "20220829"), isBundled: true
    )
    try FileManager.default.createDirectory(at: service.documentRoot, withIntermediateDirectories: true)
    // 生成配置会检查 `.htaccess` 所需的模块是否存在并在缺失时报错，
    // 因此这个假运行时也要带上模块目录。
    let moduleDirectory = runtime.apache
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("lib/httpd/modules", isDirectory: true)
    try FileManager.default.createDirectory(at: moduleDirectory, withIntermediateDirectories: true)
    for name in ApacheModulePlan.baseModules + ApacheModulePlan.requiredForHtaccess {
        try Data().write(to: moduleDirectory.appendingPathComponent("mod_\(name).so"))
    }
    let php = try WebStackConfigurationGenerator().generate(
        installation: web, preferences: Preferences(), documentRoot: service.documentRoot, layout: service
    ).php
    #expect(php.contains("extension_dir = \"\(runtime.phpExtensionDirectory(api: "20220829").path)\""))

    try FileManager.default.createDirectory(
        at: service.databaseDirectory.appendingPathComponent("mysql"), withIntermediateDirectories: true
    )
    try Data("owned\n".utf8).write(to: service.databaseDirectory.appendingPathComponent(".macstack-datadir-v1"))
    let database = InstalledDatabaseStack(
        server: runtime.mariaDBServer, initializer: runtime.mariaDBInitializer,
        admin: runtime.mariaDBAdmin, client: runtime.mariaDBClient, dump: runtime.mariaDBDump,
        version: "test", baseDirectory: runtime.mariaDBRoot, isBundled: true
    )
    _ = try DatabaseStackPreparer().prepare(installation: database, preferences: Preferences(), layout: service)
    let config = try String(contentsOf: service.databaseConfiguration, encoding: .utf8)
    #expect(config.contains("basedir=\(runtime.mariaDBRoot.path)"))
    #expect(config.contains("plugin-dir=\(runtime.mariaDBRoot.appendingPathComponent("lib/plugin").path)"))
    #expect(config.contains("character-sets-dir=\(runtime.mariaDBRoot.appendingPathComponent("share/mysql/charsets").path)"))
}

@Test func stagedPortableMariaDBInitializesQueriesAndStops() async throws {
    guard ProcessInfo.processInfo.environment["MACSTACK_RUNTIME_ROOT"] != nil else { return }
    let installation = try DatabaseStackResolver().resolve()
    guard installation.isBundled else { return }
    let root = URL(fileURLWithPath: "/tmp/ms-db-\(UUID().uuidString.prefix(8))", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var preferences = Preferences()
    guard let port = PortAvailability().nextAvailable(startingAt: 23307, excluding: []) else { return }
    preferences.databasePort = port
    let prepared = try DatabaseStackPreparer().prepare(
        installation: installation,
        preferences: preferences,
        layout: RuntimeLayout(root: root)
    )
    #expect(prepared.initializedNow)
    let controller = LocalDatabaseController(
        installation: installation,
        layout: prepared.layout,
        databasePort: port
    )
    do {
        let version = try await controller.startAndCheck()
        #expect(version.contains("11.4"))
        try await controller.stop(.mariadb)
        #expect(await controller.state(of: .mariadb) == .stopped)
    } catch {
        try? await controller.stop(.mariadb)
        throw error
    }
}

@Test func phpExtensionModuleParserSeparatesSectionHeaders() {
    let output = """
    [PHP Modules]
    Core
    pdo_mysql

    [Zend Modules]
    Xdebug
    """
    #expect(PHPExtensionManager.parseModules(output) == ["Core", "pdo_mysql", "Xdebug"])
}

@Test func phpExtensionManagerUsesPrivateValidatedConfigurationAndRestoresBackup() throws {
    guard let installation = try? WebStackResolver().resolve() else { return }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacStackExtensions-\(UUID())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let layout = RuntimeLayout(root: root)
    try FileManager.default.createDirectory(at: layout.configurationDirectory, withIntermediateDirectories: true)
    try Data("display_errors=On\n".utf8).write(to: layout.phpConfiguration)
    let manager = PHPExtensionManager(installation: installation, layout: layout)
    try manager.ensureConfiguration()
    let initial = try manager.inspect()
    #expect(initial.builtInModules.contains("pdo_mysql"))
    guard let opcache = initial.extensions.first(where: { $0.name == "opcache" }), opcache.libraryPath != nil else { return }

    let nextEnabled = opcache.status != .enabled
    let change = try manager.setEnabled("opcache", enabled: nextEnabled)
    #expect(change.backupURL.map { FileManager.default.fileExists(atPath: $0.path) } == true)
    let changed = try manager.inspect().extensions.first { $0.name == "opcache" }
    #expect(changed?.status == (nextEnabled ? .enabled : .disabled))

    try manager.restore(change)
    let restored = try manager.inspect().extensions.first { $0.name == "opcache" }
    #expect(restored?.status == opcache.status)
}

@Test func universalHeaderValidation() {
    // 两个架构记录：Intel + ARM64。
    var bytes: [UInt8] = [0xca, 0xfe, 0xba, 0xbe, 0, 0, 0, 2]
    bytes += [1, 0, 0, 7] + Array(repeating: 0, count: 16)
    bytes += [1, 0, 0, 12] + Array(repeating: 0, count: 16)
    #expect(MachOHeader.containsARM64(Data(bytes)))
    #expect(!MachOHeader.containsARM64(Data(bytes.dropLast())))
}

@Test func portValidation() throws {
    var value = Preferences()
    try value.validate()
    value.httpPort = 80
    #expect(throws: SettingsError.self) { try value.validate() }
    value.httpPort = value.databasePort
    #expect(throws: SettingsError.self) { try value.validate() }
    value.httpPort = 65536
    #expect(throws: SettingsError.self) { try value.validate() }
}

@Test func settingsRoundTripAndInvalidFilePreservation() throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("MacStackTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: temporary) }
    let store = SettingsStore(directory: temporary)
    #expect(try store.load() == WorkspaceSettings())
    #expect(!FileManager.default.fileExists(atPath: temporary.path))
    var value = WorkspaceSettings()
    try value.addWebsite(at: URL(fileURLWithPath: "/tmp/my-site"))
    try store.save(value)
    #expect(try store.load() == value)
    let invalid = Data("invalid configuration".utf8)
    try invalid.write(to: store.fileURL)
    #expect(throws: (any Error).self) { try store.load() }
    #expect(try Data(contentsOf: store.fileURL) == invalid)
}

@Test func olderPreferencesGainSafeServiceDefaults() throws {
    let data = Data("{\"httpPort\":8088,\"databasePort\":3310}".utf8)
    let value = try JSONDecoder().decode(Preferences.self, from: data)
    #expect(value.httpPort == 8088)
    #expect(value.databasePort == 3310)
    #expect(value.restoreLastSession)
    #expect(!value.autoStartWeb)
    #expect(!value.autoStartDatabase)
    #expect(!value.automaticBackupEnabled)
    #expect(value.backupIntervalHours == 24)
    #expect(value.preferredPHPFormula == "auto")
    #expect(!value.httpsEnabled)
    #expect(value.httpsPort == 8443)
}

@Test func serviceIntentRoundTripAndCorruptFallback() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacStackTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ServiceIntentStore(directory: directory)
    #expect(store.load() == ServiceIntent())
    let expected = ServiceIntent(webRunning: true, databaseRunning: false)
    try store.save(expected)
    #expect(store.load() == expected)
    try Data("broken".utf8).write(to: store.fileURL)
    #expect(store.load() == ServiceIntent())
}

@Test func projectCreatorBuildsSafeStarterWithoutPassword() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacStackTests-\(UUID())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let creator = PHPProjectCreator()
    let result = try creator.create(named: "动态课程", in: directory, databaseName: "course_site", databasePort: 3307)
    #expect(FileManager.default.fileExists(atPath: result.publicRoot.appendingPathComponent("index.php").path))
    #expect(result.files.count == 5)
    let database = try String(contentsOf: result.root.appendingPathComponent("config/database.example.php"), encoding: .utf8)
    #expect(database.contains("dbname=course_site"))
    #expect(database.contains("port=3307"))
    #expect(database.contains("YOUR_PASSWORD_HERE"))
    #expect(throws: ProjectCreationError.self) {
        try creator.create(named: "动态课程", in: directory, databaseName: nil, databasePort: 3307)
    }
    #expect(throws: ProjectCreationError.self) { try creator.validateDatabaseName("bad-name") }
}

@Test func logRotationKeepsThreeCopies() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacStackTests-\(UUID())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let log = directory.appendingPathComponent("apache-error.log")
    try Data("new".utf8).write(to: log)
    try Data("one".utf8).write(to: URL(fileURLWithPath: log.path + ".1"))
    try Data("two".utf8).write(to: URL(fileURLWithPath: log.path + ".2"))
    try Data("three".utf8).write(to: URL(fileURLWithPath: log.path + ".3"))
    let result = try LogMaintainer().rotate(directory: directory, maximumBytes: 1, retainedCopies: 3)
    #expect(result == LogMaintenanceResult(rotated: 1, removed: 1))
    #expect((try String(contentsOf: URL(fileURLWithPath: log.path + ".1"), encoding: .utf8)) == "new")
    #expect((try String(contentsOf: URL(fileURLWithPath: log.path + ".2"), encoding: .utf8)) == "one")
    #expect((try String(contentsOf: URL(fileURLWithPath: log.path + ".3"), encoding: .utf8)) == "two")
    #expect((try Data(contentsOf: log)).isEmpty)
}

@Test func backupCatalogRoundTripUsesRealFileMetadata() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacStackTests-\(UUID())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = BackupCatalogStore(directory: directory)
    let file = try store.destination(database: "course")
    try Data("SQL".utf8).write(to: file)
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let records = try store.register(database: "course", file: file, automatic: true, createdAt: date)
    #expect(records.first?.database == "course")
    #expect(records.first?.byteCount == 3)
    #expect(store.load().first?.createdAt == date)
    #expect(store.lastAutomaticBackupDate(database: "course") == date)
}

/// 自动备份的间隔判断必须**按库**进行。
///
/// 之前用的是「全局最新一次自动备份时间」，后果是新登记的业务库要等满一整个间隔
/// （最长 168 小时）才会被首次备份。
@Test func backupCatalogTracksLastAutomaticBackupPerDatabase() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacStackTests-\(UUID())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = BackupCatalogStore(directory: directory)

    let early = Date(timeIntervalSince1970: 1_700_000_000)
    let late = early.addingTimeInterval(3_600)

    let first = try store.destination(database: "alpha", date: early)
    try Data("a".utf8).write(to: first)
    _ = try store.register(database: "alpha", file: first, automatic: true, createdAt: early)

    let second = try store.destination(database: "beta", date: late)
    try Data("b".utf8).write(to: second)
    _ = try store.register(database: "beta", file: second, automatic: true, createdAt: late)

    // 全局最新是 beta 的时间，但 alpha 仍应返回自己的时间。
    #expect(store.lastAutomaticBackupDate(database: "alpha") == early)
    #expect(store.lastAutomaticBackupDate(database: "beta") == late)
    // 没备份过的库没有任何时间，会被立即备份。
    #expect(store.lastAutomaticBackupDate(database: "gamma") == nil)

    // 手工备份不参与自动备份的时间判断。
    let manual = try store.destination(database: "alpha", date: late)
    try Data("m".utf8).write(to: manual)
    _ = try store.register(database: "alpha", file: manual, automatic: false, createdAt: late)
    #expect(store.lastAutomaticBackupDate(database: "alpha") == early)
}

/// 清理只针对超期的自动备份，且只删备份目录内的文件。
@Test func backupPruningOnlyRemovesExpiredAutomaticBackupsInsideDirectory() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacStackTests-\(UUID())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = BackupCatalogStore(directory: directory)

    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let old = now.addingTimeInterval(-40 * 86_400)
    let recent = now.addingTimeInterval(-1 * 86_400)

    let expiredAutomatic = try store.destination(database: "alpha", date: old)
    try Data("old".utf8).write(to: expiredAutomatic)
    _ = try store.register(database: "alpha", file: expiredAutomatic, automatic: true, createdAt: old)

    let freshAutomatic = try store.destination(database: "alpha", date: recent)
    try Data("new".utf8).write(to: freshAutomatic)
    _ = try store.register(database: "alpha", file: freshAutomatic, automatic: true, createdAt: recent)

    // 手工备份即使超期也不该被删。
    let expiredManual = try store.destination(database: "alpha", date: old)
    try Data("manual".utf8).write(to: expiredManual)
    _ = try store.register(database: "alpha", file: expiredManual, automatic: false, createdAt: old)

    // catalog 被改成指向目录外的路径时也不能波及外部文件。
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent("MacStackOutside-\(UUID()).sql")
    try Data("outside".utf8).write(to: outside)
    defer { try? FileManager.default.removeItem(at: outside) }
    _ = try store.register(database: "alpha", file: outside, automatic: true, createdAt: old)

    let removed = store.pruneAutomaticBackups(olderThanDays: 30, now: now)
    #expect(removed == 1)

    #expect(!FileManager.default.fileExists(atPath: expiredAutomatic.path))
    #expect(FileManager.default.fileExists(atPath: freshAutomatic.path))
    #expect(FileManager.default.fileExists(atPath: expiredManual.path))
    #expect(FileManager.default.fileExists(atPath: outside.path))

    let remaining = Set(store.load().map(\.filePath))
    #expect(!remaining.contains(expiredAutomatic.path))
    #expect(remaining.contains(freshAutomatic.path))
    #expect(remaining.contains(expiredManual.path))

    // 保留天数为 0 表示不清理。
    #expect(store.pruneAutomaticBackups(olderThanDays: 0, now: now) == 0)
}

/// 登记数量超过旧上限时，catalog 不能静默丢记录并把对应 SQL 变成孤儿文件。
@Test func backupCatalogDoesNotDiscardRecordsAtLegacyTwoHundredLimit() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MacStackTests-\(UUID())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = BackupCatalogStore(directory: directory)
    let backup = try store.destination(database: "alpha")
    try Data("backup".utf8).write(to: backup)

    for offset in 0..<205 {
        _ = try store.register(
            database: "alpha",
            file: backup,
            automatic: true,
            createdAt: Date(timeIntervalSince1970: TimeInterval(offset))
        )
    }

    #expect(store.load().count == 205)
}

/// 轮转可以按前缀限定范围。
@Test func logRotationHonoursPrefixFilter() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacStackTests-\(UUID())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let launcher = directory.appendingPathComponent("apache-launcher.log")
    let other = directory.appendingPathComponent("apache-error.log")
    try Data("launcher".utf8).write(to: launcher)
    try Data("error".utf8).write(to: other)

    let result = try LogMaintainer().rotate(
        directory: directory,
        maximumBytes: 1,
        retainedCopies: 3,
        prefixes: ["apache-launcher"]
    )
    #expect(result.rotated == 1)
    #expect((try String(contentsOf: URL(fileURLWithPath: launcher.path + ".1"), encoding: .utf8)) == "launcher")
    #expect((try Data(contentsOf: launcher)).isEmpty)
    // 未落在前缀内的日志保持原样，内容还在原文件里。
    #expect((try String(contentsOf: other, encoding: .utf8)) == "error")
    #expect(!FileManager.default.fileExists(atPath: other.path + ".1"))
}

/// 轮转**不得**越过组件边界。
///
/// Web 与数据库共用一个日志目录，而「准备 A 的配置」时 B 可能正在运行。轮转做的是
/// 「改名 + 建同名空文件」，如果动到 B 仍持有写入句柄的日志，后续写入会进入被改名的
/// `.1` 文件、新建的空文件永远是空的。因此每个组件只能轮转自己的前缀。
@Test func logRotationNeverCrossesComponentBoundary() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacStackTests-\(UUID())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let webLogs = ["apache-error.log", "apache-access.log", "php-fpm-error.log", "site-abc-error.log"]
    let databaseLogs = ["mariadb-launcher.log", "mariadb-error.log"]
    for name in webLogs + databaseLogs {
        try Data("payload".utf8).write(to: directory.appendingPathComponent(name))
    }

    // 准备 Web 配置：只能动 Web 的日志，数据库的必须原封不动。
    _ = try LogMaintainer().rotate(directory: directory, maximumBytes: 1, prefixes: LogOwnership.web)
    for name in databaseLogs {
        let url = directory.appendingPathComponent(name)
        #expect((try String(contentsOf: url, encoding: .utf8)) == "payload", "\(name) 不应被 Web 的轮转动到")
        #expect(!FileManager.default.fileExists(atPath: url.path + ".1"))
    }
    for name in webLogs {
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path + ".1"))
    }

    // 准备数据库配置：只能动数据库的日志。
    _ = try LogMaintainer().rotate(directory: directory, maximumBytes: 1, prefixes: LogOwnership.database)
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("mariadb-launcher.log").path + ".1"))
    // Web 的 `.1` 仍只有刚才那一次，说明数据库的轮转没有再加一层。
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("apache-error.log").path + ".2"))

}

/// 失效 PID 文件应被清理，且不再因为「无法确认身份」而中断整个流程。
@Test func residualRecoveryRemovesStalePIDFileWithoutThrowing() throws {
    let root = URL(fileURLWithPath: "/tmp/macstack-recovery-\(UUID().uuidString.prefix(8))", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let layout = RuntimeLayout(root: root)
    try FileManager.default.createDirectory(at: layout.runDirectory, withIntermediateDirectories: true)

    // 一个几乎不可能存在的 PID。
    try Data("999999\n".utf8).write(to: layout.apachePID)
    // 另外两个候选不存在，应当被安静跳过。
    let result = try ResidualServiceRecovery().recover(layout: layout)

    #expect(result.removedStalePIDCount == 1)
    #expect(result.stoppedProcessCount == 0)
    #expect(result.unresolved.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: layout.apachePID.path))
}

/// 无法确认身份的进程要记录到 unresolved，并且**保留** PID 文件，不再抛错中断。
///
/// 旧实现遇到第一个无法确认的进程就 throw，后面的候选（PHP-FPM、MariaDB）
/// 根本不会被检查。
@Test func residualRecoveryRecordsUnresolvedInsteadOfAborting() throws {
    let root = URL(fileURLWithPath: "/tmp/macstack-recovery-\(UUID().uuidString.prefix(8))", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let layout = RuntimeLayout(root: root)
    try FileManager.default.createDirectory(at: layout.runDirectory, withIntermediateDirectories: true)

    // 用测试进程自己的 PID：它一定存在，且命令行里不可能含 MacStack 的配置路径。
    // 无论能否读到它的命令行，都应归入 unresolved 而不是抛错。
    //
    // 注意不能用 PID 1 —— 恢复逻辑里 `pid > 1` 的守卫会直接跳过它。
    try Data("\(getpid())\n".utf8).write(to: layout.apachePID)
    // 后续候选也要被检查到：给 MariaDB 放一个失效 PID。
    try Data("999999\n".utf8).write(to: layout.databasePID)

    let result = try ResidualServiceRecovery().recover(layout: layout)

    #expect(result.unresolved.count == 1)
    #expect(result.unresolved.first?.pid == getpid())
    // 关键：无法确认身份时不能删 PID 文件。
    #expect(FileManager.default.fileExists(atPath: layout.apachePID.path))
    // 关键：后续候选仍然被处理了。
    #expect(result.removedStalePIDCount == 1)
    #expect(!FileManager.default.fileExists(atPath: layout.databasePID.path))
}

@Test func databaseRestorePreflightReportsSizeWithoutConnecting() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacStackTests-\(UUID())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let sql = directory.appendingPathComponent("backup.sql")
    try Data("SELECT 1;".utf8).write(to: sql)
    let installation = InstalledDatabaseStack(
        server: URL(fileURLWithPath: "/missing/server"), initializer: URL(fileURLWithPath: "/missing/init"),
        admin: URL(fileURLWithPath: "/missing/admin"), client: URL(fileURLWithPath: "/missing/client"), version: "test"
    )
    let plan = try DatabaseRestoreJob(installation: installation).prepare(source: sql)
    #expect(plan.sourceBytes == 9)
    #expect(plan.recommendedFreeBytes >= 64 * 1_024 * 1_024)
}

@Test func localHostnameAndHTTPSConfigurationAreValidated() throws {
    #expect(LocalHostname.suggested(from: "My Course") == "my-course.localhost")
    #expect(LocalHostname.suggested(from: "动态课程").isEmpty)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacStackTests-\(UUID())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let site = Website(name: "Course", rootPath: directory.path, port: 8081, isEnabled: true, hostname: "course.localhost")
    try WebsiteHostingValidator().validate(site)
    #expect(throws: WebsiteHostingError.self) {
        try WebsiteHostingValidator().validate(Website(name: "Bad", rootPath: directory.path, port: 8082, hostname: "bad.example.com"))
    }
    var preferences = Preferences()
    preferences.httpsEnabled = true
    let layout = RuntimeLayout(root: URL(fileURLWithPath: "/tmp/macstack-tls-\(UUID().uuidString.prefix(8))"))
    let installation = InstalledWebStack(
        apache: URL(fileURLWithPath: "/opt/homebrew/opt/httpd/bin/httpd"),
        php: URL(fileURLWithPath: "/opt/homebrew/opt/php@8.2/bin/php"),
        phpFPM: URL(fileURLWithPath: "/opt/homebrew/opt/php@8.2/sbin/php-fpm"),
        apacheVersion: "test", phpVersion: "test"
    )
    let tls = TLSCertificate(certificate: layout.tlsCertificate, privateKey: layout.tlsPrivateKey, hostnames: ["course.localhost"])
    let config = try WebStackConfigurationGenerator().generate(
        installation: installation, preferences: preferences, documentRoot: directory,
        layout: layout, websites: [site], tlsCertificate: tls
    ).apache
    #expect(config.contains("LoadModule ssl_module"))
    #expect(config.contains("Listen 127.0.0.1:8443"))
    #expect(config.contains("ServerName course.localhost"))
    #expect(config.contains("SSLCertificateFile"))
}

@Test func realNativeApacheServesHTTPSAndPerlCGIWhenInstalled() async throws {
    guard let installation = try? WebStackResolver().resolve() else { return }
    let files = FileManager.default
    let root = URL(fileURLWithPath: "/tmp/macstack-https-\(UUID().uuidString.prefix(8))", isDirectory: true)
    defer { try? files.removeItem(at: root) }
    let site = root.appendingPathComponent("site", isDirectory: true)
    try files.createDirectory(at: site.appendingPathComponent("cgi-bin", isDirectory: true), withIntermediateDirectories: true)
    try Data("<?php echo 'ok';".utf8).write(to: site.appendingPathComponent("index.php"))
    let cgi = site.appendingPathComponent("cgi-bin/hello.pl")
    try Data("#!/usr/bin/perl\nprint \"Content-Type: text/plain\\r\\n\\r\\nPERL-OK\";\n".utf8).write(to: cgi)
    try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cgi.path)
    var preferences = Preferences()
    let availability = PortAvailability()
    var used = Set<Int>()
    guard let http = availability.nextAvailable(startingAt: 18880, excluding: used) else { return }
    used.insert(http)
    guard let database = availability.nextAvailable(startingAt: http + 1, excluding: used) else { return }
    used.insert(database)
    guard let https = availability.nextAvailable(startingAt: database + 1, excluding: used) else { return }
    used.insert(https)
    guard let sitePort = availability.nextAvailable(startingAt: https + 1, excluding: used) else { return }
    preferences.httpPort = http
    preferences.databasePort = database
    preferences.httpsPort = https
    preferences.httpsEnabled = true
    preferences.perlCGIEnabled = true
    let website = Website(name: "Site", rootPath: site.path, port: sitePort, isEnabled: true, hostname: "site.localhost")
    let prepared = try WebStackPreparer().prepare(
        installation: installation,
        preferences: preferences,
        layout: RuntimeLayout(root: root.appendingPathComponent("runtime")),
        websites: [website]
    )
    #expect(files.fileExists(atPath: prepared.layout.tlsCertificate.path))
    #expect(files.fileExists(atPath: prepared.layout.tlsPrivateKey.path))
    let config = try String(contentsOf: prepared.layout.apacheConfiguration, encoding: .utf8)
    #expect(config.contains("ScriptAlias \"/cgi-bin/\""))
    #expect(config.contains("SSLEngine on"))
    let controller = LocalWebStackController(installation: installation, layout: prepared.layout)
    do {
        try await controller.startWebStack(httpPort: http)
        let secure = try FoundationCommandRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/curl"),
            arguments: ["--silent", "--show-error", "--insecure", "--resolve", "site.localhost:\(https):127.0.0.1", "https://site.localhost:\(https)/"]
        )
        let perl = try FoundationCommandRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/curl"),
            arguments: ["--silent", "--show-error", "http://127.0.0.1:\(sitePort)/cgi-bin/hello.pl"]
        )
        #expect(secure.status == 0)
        #expect(secure.combinedOutput == "ok")
        #expect(perl.status == 0)
        #expect(perl.combinedOutput == "PERL-OK")
        try await controller.stopWebStack()
    } catch {
        try? await controller.stopWebStack()
        throw error
    }
}

@Test func legacySettingsMigrationAllocatesPortsAndPreservesBackupOnSave() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacStackTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = SettingsStore(directory: directory)
    let id = UUID()
    let legacy = """
    {"schemaVersion":1,"preferences":{"httpPort":8080,"databasePort":3307},"websites":[{"id":"\(id.uuidString)","name":"旧网站","rootPath":"/tmp/旧网站"}]}
    """
    let original = Data(legacy.utf8)
    try original.write(to: store.fileURL)
    let migrated = try store.load()
    #expect(migrated.schemaVersion == 2)
    #expect(migrated.websites.first?.publicRootPath == "/tmp/旧网站")
    #expect(migrated.websites.first?.port == 8081)
    #expect(migrated.websites.first?.isEnabled == false)
    #expect(!FileManager.default.fileExists(atPath: store.version1BackupURL.path))
    try store.save(migrated)
    #expect(try Data(contentsOf: store.version1BackupURL) == original)
    #expect(try store.load() == migrated)
}

@Test func duplicateWebsiteAndUnknownSchema() throws {
    var settings = WorkspaceSettings()
    try settings.addWebsite(at: URL(fileURLWithPath: "/tmp/site"))
    #expect(throws: SettingsError.self) {
        try settings.addWebsite(at: URL(fileURLWithPath: "/tmp/site/../site"))
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacStackTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SettingsStore(directory: directory)
    settings.schemaVersion = 99
    #expect(throws: SettingsError.self) { try store.save(settings) }
    #expect(!FileManager.default.fileExists(atPath: directory.path))
}

@Test func detectorReadsHeaderWithoutExecutingFile() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacStackTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let detector = ComponentDetector(
        prefix: directory,
        portableRuntimeRoot: directory.appendingPathComponent("no-portable-runtime")
    )
    #expect(detector.inspect(.apache).status == .missing)
    let executable = directory.appendingPathComponent("opt/httpd/bin/httpd")
    try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 1]).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    #expect(detector.inspect(.apache).status == .appleSilicon)
    // 这个 fixture 不可实际执行，检测仍然成功，证明没有调用候选程序。
    #expect(detector.inspect(.php).status == .missing)
}

@Test func pendingControllerNeverPretendsToStart() async {
    let controller = PendingServiceController()
    #expect(await controller.state(of: .apache) == .notConnected)
    await #expect(throws: ServiceControlError.self) { try await controller.start(.apache) }
    await #expect(throws: ServiceControlError.self) { try await controller.stop(.mariadb) }
}

@Test func webStackConfigurationUsesLoopbackAndHandlesSpacesAndChinese() throws {
    let installation = InstalledWebStack(
        apache: URL(fileURLWithPath: "/opt/homebrew/opt/httpd/bin/httpd"),
        php: URL(fileURLWithPath: "/opt/homebrew/opt/php@8.2/bin/php"),
        phpFPM: URL(fileURLWithPath: "/opt/homebrew/opt/php@8.2/sbin/php-fpm"),
        apacheVersion: "Apache/2.4-test",
        phpVersion: "PHP 8.2-test"
    )
    let layout = RuntimeLayout(root: URL(fileURLWithPath: "/tmp/MacStack 测试"))
    let root = URL(fileURLWithPath: "/tmp/我的 Web 项目")
    let generated = try WebStackConfigurationGenerator().generate(
        installation: installation,
        preferences: Preferences(),
        documentRoot: root,
        layout: layout,
        phpMyAdminRoot: URL(fileURLWithPath: "/tmp/MacStack 测试/phpmyadmin")
    )
    #expect(generated.apache.contains("Listen 127.0.0.1:8080"))
    #expect(generated.apache.contains("LoadModule unixd_module"))
    #expect(generated.apache.contains("DocumentRoot \"/tmp/我的 Web 项目\""))
    #expect(generated.apache.contains("proxy:unix:/tmp/MacStack 测试/run/php-fpm.sock|fcgi://localhost/"))
    #expect(generated.phpFPM.contains("listen = /tmp/MacStack 测试/run/php-fpm.sock"))
    #expect(generated.apache.contains("Alias \"/phpmyadmin\" \"/tmp/MacStack 测试/phpmyadmin\""))
    #expect(generated.apache.contains("Require local"))
    #expect(generated.apache.contains("LoadModule authz_host_module"))
}

@Test func multiSiteConfigurationUsesStablePortsAndProtectsDotFiles() throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("MacStackTests-\(UUID())")
    let shortRuntime = URL(fileURLWithPath: "/tmp/macstack-\(UUID().uuidString.prefix(8))", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: temporary)
        try? FileManager.default.removeItem(at: shortRuntime)
    }
    let first = temporary.appendingPathComponent("项目 一/public", isDirectory: true)
    let second = temporary.appendingPathComponent("项目二", isDirectory: true)
    try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    let installation = InstalledWebStack(
        apache: URL(fileURLWithPath: "/opt/homebrew/opt/httpd/bin/httpd"),
        php: URL(fileURLWithPath: "/opt/homebrew/opt/php@8.2/bin/php"),
        phpFPM: URL(fileURLWithPath: "/opt/homebrew/opt/php@8.2/sbin/php-fpm"),
        apacheVersion: "test", phpVersion: "test"
    )
    let websites = [
        Website(name: "一", rootPath: first.deletingLastPathComponent().path, publicRootPath: first.path, port: 8081, isEnabled: true),
        Website(name: "二", rootPath: second.path, port: 8082, isEnabled: true)
    ]
    let generated = try WebStackConfigurationGenerator().generate(
        installation: installation,
        preferences: Preferences(),
        documentRoot: temporary.appendingPathComponent("internal"),
        layout: RuntimeLayout(root: shortRuntime),
        websites: websites
    ).apache
    #expect(generated.contains("Listen 127.0.0.1:8081"))
    #expect(generated.contains("Listen 127.0.0.1:8082"))
    #expect(generated.contains("DocumentRoot \"\(first.path)\""))
    #expect(generated.contains("Options -Indexes -FollowSymLinks"))
    #expect(generated.contains("<FilesMatch \"^\\.\">"))
    #expect(generated.contains("<DirectoryMatch \"(^|/)\\.\">"))
    #expect(!generated.contains("Options Indexes"))
}

@Test func websiteValidationRejectsPublicRootOutsideProjectAndDuplicatePort() throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("MacStackTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: temporary) }
    let project = temporary.appendingPathComponent("project", isDirectory: true)
    let outside = temporary.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    #expect(throws: WebsiteHostingError.self) {
        try WebsiteHostingValidator().validate(Website(name: "bad", rootPath: project.path, publicRootPath: outside.path, port: 8081))
    }
    var settings = WorkspaceSettings()
    settings.websites = [
        Website(name: "a", rootPath: project.path, port: 8081),
        Website(name: "b", rootPath: outside.path, port: 8081)
    ]
    #expect(throws: SettingsError.self) { try settings.validate() }
}

@Test func failedCandidateValidationPreservesAppliedWebConfiguration() throws {
    let temporary = URL(fileURLWithPath: "/tmp/macstack-\(UUID().uuidString.prefix(8))", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let bin = temporary.appendingPathComponent("bin", isDirectory: true)
    let layout = RuntimeLayout(root: temporary.appendingPathComponent("runtime", isDirectory: true))
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: layout.configurationDirectory, withIntermediateDirectories: true)
    let failing = bin.appendingPathComponent("failing-check")
    try Data("#!/bin/sh\nexit 1\n".utf8).write(to: failing)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: failing.path)
    let oldApache = Data("APPLIED-APACHE".utf8)
    let oldFPM = Data("APPLIED-FPM".utf8)
    let oldPHP = Data("APPLIED-PHP".utf8)
    try oldApache.write(to: layout.apacheConfiguration)
    try oldFPM.write(to: layout.phpFPMConfiguration)
    try oldPHP.write(to: layout.phpConfiguration)
    let installation = InstalledWebStack(
        apache: failing,
        php: failing,
        phpFPM: failing,
        apacheVersion: "test",
        phpVersion: "test"
    )
    #expect(throws: WebStackError.self) {
        try WebStackPreparer().prepare(
            installation: installation,
            preferences: Preferences(),
            layout: layout
        )
    }
    #expect(try Data(contentsOf: layout.apacheConfiguration) == oldApache)
    #expect(try Data(contentsOf: layout.phpFPMConfiguration) == oldFPM)
    #expect(try Data(contentsOf: layout.phpConfiguration) == oldPHP)
    let remaining = try FileManager.default.contentsOfDirectory(atPath: layout.configurationDirectory.path)
    #expect(Set(remaining) == Set(["httpd.conf", "php-fpm.conf", "php.ini"]))
}

@Test func webStackConfigurationRejectsUnsafeAndLongPaths() {
    let installation = InstalledWebStack(
        apache: URL(fileURLWithPath: "/opt/homebrew/opt/httpd/bin/httpd"),
        php: URL(fileURLWithPath: "/opt/homebrew/opt/php@8.2/bin/php"),
        phpFPM: URL(fileURLWithPath: "/opt/homebrew/opt/php@8.2/sbin/php-fpm"),
        apacheVersion: "test",
        phpVersion: "test"
    )
    let newline = URL(fileURLWithPath: "/tmp/unsafe\npath")
    #expect(throws: WebStackError.self) {
        try WebStackConfigurationGenerator().generate(
            installation: installation,
            preferences: Preferences(),
            documentRoot: newline,
            layout: RuntimeLayout(root: URL(fileURLWithPath: "/tmp/macstack"))
        )
    }
    let long = "/tmp/" + String(repeating: "a", count: 110)
    #expect(throws: WebStackError.self) {
        try WebStackConfigurationGenerator().generate(
            installation: installation,
            preferences: Preferences(),
            documentRoot: URL(fileURLWithPath: "/tmp/site"),
            layout: RuntimeLayout(root: URL(fileURLWithPath: long))
        )
    }
}

@Test func versionTextUsesFirstNonemptyLine() {
    #expect(VersionText.firstLine("\nPHP 8.2.33\nCopyright") == "PHP 8.2.33")
    #expect(VersionText.firstLine("") == "版本未知")
}

@Test func databasePreparerRefusesUnknownNonemptyDataDirectory() throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("MacStackTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: temporary) }
    let layout = RuntimeLayout(root: temporary)
    try FileManager.default.createDirectory(at: layout.databaseDirectory, withIntermediateDirectories: true)
    try Data("do not overwrite".utf8).write(to: layout.databaseDirectory.appendingPathComponent("unknown.data"))
    let dummy = InstalledDatabaseStack(
        server: URL(fileURLWithPath: "/missing/mariadbd"),
        initializer: URL(fileURLWithPath: "/missing/mariadb-install-db"),
        admin: URL(fileURLWithPath: "/missing/mariadb-admin"),
        client: URL(fileURLWithPath: "/missing/mariadb"),
        version: "test"
    )
    #expect(throws: DatabaseStackError.self) {
        try DatabaseStackPreparer().prepare(installation: dummy, preferences: Preferences(), layout: layout)
    }
    #expect(try String(contentsOf: layout.databaseDirectory.appendingPathComponent("unknown.data"), encoding: .utf8) == "do not overwrite")
}

@Test func databaseCredentialKeychainRoundTrip() throws {
    let store = DatabaseCredentialStore(testService: "local.macstack.tests.\(UUID())")
    defer { try? store.deleteTestItem() }
    let first = try store.loadOrCreate()
    let second = try store.loadOrCreate()
    #expect(first == second)
    #expect(first.username == "macstack")
    #expect(first.password.count == 48)
    #expect(first.password.allSatisfy { $0.isHexDigit })
}

@Test func phpMyAdminPreparationIsIsolatedAndKeepsDatabasePasswordOut() throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("MacStackTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: temporary) }
    let source = temporary.appendingPathComponent("source", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("<?php".utf8).write(to: source.appendingPathComponent("index.php"))
    try Data("vendor config".utf8).write(to: source.appendingPathComponent("config.inc.php"))
    let layout = RuntimeLayout(root: temporary.appendingPathComponent("runtime", isDirectory: true))
    let prepared = try PHPMyAdminPreparer().prepare(
        installation: InstalledPHPMyAdmin(source: source, version: "5.2.3"),
        databasePort: 3307,
        layout: layout
    )
    #expect(prepared.copiedNow)
    #expect(prepared.version == "5.2.3")
    let config = try String(contentsOf: prepared.directory.appendingPathComponent("config.inc.php"), encoding: .utf8)
    #expect(config.contains("auth_type'] = 'cookie'"))
    #expect(config.contains("port'] = '3307'"))
    #expect(!config.contains("password']"))
    #expect(try String(contentsOf: layout.phpMyAdminSecret, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines).count == 64)

    let again = try PHPMyAdminPreparer().prepare(
        installation: InstalledPHPMyAdmin(source: source, version: "5.2.3"),
        databasePort: 3307,
        layout: layout
    )
    #expect(!again.copiedNow)
}

@Test func xamppAuditIsReadOnlyAndRedactsConfigurationValues() throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("MacStackTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: temporary) }
    let root = temporary.appendingPathComponent("XAMPP", isDirectory: true)
    let xamppfiles = root.appendingPathComponent("xamppfiles", isDirectory: true)
    let site = xamppfiles.appendingPathComponent("htdocs/my-site", isDirectory: true)
    let systemDatabase = xamppfiles.appendingPathComponent("var/mysql/mysql", isDirectory: true)
    let businessDatabase = xamppfiles.appendingPathComponent("var/mysql/shop", isDirectory: true)
    let config = xamppfiles.appendingPathComponent("etc", isDirectory: true)
    let binaries = xamppfiles.appendingPathComponent("bin", isDirectory: true)
    for directory in [site, systemDatabase, businessDatabase, config, binaries] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let php = "<?php $db_password = 'never-print-this'; new PDO('mysql:host=localhost', 'shop', $db_password);"
    try Data(php.utf8).write(to: site.appendingPathComponent("index.php"))
    try Data("table".utf8).write(to: businessDatabase.appendingPathComponent("orders.ibd"))
    try Data("system".utf8).write(to: systemDatabase.appendingPathComponent("user.ibd"))
    try Data("Listen 80\nDocumentRoot \"/Applications/XAMPP/xamppfiles/htdocs\"\n".utf8)
        .write(to: config.appendingPathComponent("httpd.conf"))
    try Data("port=3306\nsocket=/tmp/mysql.sock\npassword=never-print-this\n".utf8)
        .write(to: config.appendingPathComponent("my.cnf"))
    try Data("extension=redis.so\n;extension=disabled.so\n".utf8)
        .write(to: config.appendingPathComponent("php.ini"))
    let intelHeader = Data([0xcf, 0xfa, 0xed, 0xfe, 7, 0, 0, 1])
    for name in ["httpd", "php", "mysqld"] { try intelHeader.write(to: binaries.appendingPathComponent(name)) }

    let before = try Data(contentsOf: site.appendingPathComponent("index.php"))
    let auditor = XAMPPAuditor(root: root)
    let report = try auditor.audit()
    let destination = temporary.appendingPathComponent("reports", isDirectory: true)
    let reportURL = try auditor.writeReport(report, directory: destination)
    let markdown = try String(contentsOf: reportURL, encoding: .utf8)

    #expect(report.sites.map(\.name) == ["my-site"])
    #expect(report.businessDatabases.map(\.name) == ["shop"])
    #expect(report.binaries.allSatisfy { $0.architectures == ["x86_64"] })
    #expect(report.phpExtensions == ["redis.so"])
    #expect(report.sites.first?.databaseReferenceFileCount == 1)
    #expect(markdown.contains("没有启动旧组件"))
    #expect(!markdown.contains("never-print-this"))
    #expect(try Data(contentsOf: site.appendingPathComponent("index.php")) == before)
}

@Test func websiteMigrationCopiesAndVerifiesWithoutChangingSource() throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("MacStackTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: temporary) }
    let source = temporary.appendingPathComponent("source/我的站点", isDirectory: true)
    let destinationParent = temporary.appendingPathComponent("destination", isDirectory: true)
    try FileManager.default.createDirectory(at: source.appendingPathComponent("assets"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destinationParent, withIntermediateDirectories: true)
    let index = Data("<?php echo 'ok';".utf8)
    let asset = Data([0, 1, 2, 3, 4])
    try index.write(to: source.appendingPathComponent("index.php"))
    try asset.write(to: source.appendingPathComponent("assets/data.bin"))

    let migrator = WebsiteMigrator()
    let plan = try migrator.prepare(source: source, destinationParent: destinationParent)
    #expect(plan.fileCount == 2)
    #expect(plan.totalByteCount == Int64(index.count + asset.count))
    let result = try migrator.migrate(plan)

    #expect(result.destination == destinationParent.appendingPathComponent("我的站点", isDirectory: true))
    #expect(try Data(contentsOf: source.appendingPathComponent("index.php")) == index)
    #expect(try Data(contentsOf: result.destination.appendingPathComponent("index.php")) == index)
    #expect(try Data(contentsOf: result.destination.appendingPathComponent("assets/data.bin")) == asset)
    #expect(throws: WebsiteMigrationError.self) {
        try migrator.prepare(source: source, destinationParent: destinationParent)
    }
}

@Test func websiteMigrationRejectsChangedSourceAndSymlinks() throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("MacStackTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: temporary) }
    let source = temporary.appendingPathComponent("site", isDirectory: true)
    let destination = temporary.appendingPathComponent("destination", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let file = source.appendingPathComponent("index.php")
    try Data("first".utf8).write(to: file)
    let migrator = WebsiteMigrator()
    let plan = try migrator.prepare(source: source, destinationParent: destination)
    try Data("changed".utf8).write(to: file)
    #expect(throws: WebsiteMigrationError.self) { try migrator.migrate(plan) }
    #expect(!FileManager.default.fileExists(atPath: plan.destination.path))

    try FileManager.default.createSymbolicLink(
        at: source.appendingPathComponent("outside-link"),
        withDestinationURL: temporary
    )
    #expect(throws: WebsiteMigrationError.self) {
        try migrator.prepare(source: source, destinationParent: destination)
    }
}

// MARK: - 设置重新配置

/// 记录调用顺序的假实现，用于驱动 `ServiceReconfiguration` 而不启动任何真实进程。
@MainActor
private final class RecordingReconfigurationEffects: ServiceReconfigurationEffects {
    enum Step: Equatable {
        case validate, stopWeb, stopDatabase, regenerate, persist, invalidate, restore
    }

    var steps: [Step] = []
    var validateError: Error?
    var stopWebSucceeds = true
    var stopDatabaseSucceeds = true
    var regenerateError: Error?
    var persistError: Error?
    var restoreError: Error?
    var controllersInvalidated = false
    var persisted: WorkspaceSettings?
    var regeneratedPreferences: Preferences?
    var restoredPreferences: Preferences?

    func validateSettings(_ settings: WorkspaceSettings) throws {
        steps.append(.validate)
        if let validateError { throw validateError }
    }

    func stopWebForReconfiguration() async -> Bool {
        steps.append(.stopWeb)
        return stopWebSucceeds
    }

    func stopDatabaseForReconfiguration() async -> Bool {
        steps.append(.stopDatabase)
        return stopDatabaseSucceeds
    }

    func regenerateWebConfiguration(
        preferences: Preferences,
        websites: [Website],
        wasRunning: Bool
    ) async throws {
        steps.append(.regenerate)
        regeneratedPreferences = preferences
        if let regenerateError { throw regenerateError }
    }

    func persistSettings(_ settings: WorkspaceSettings) throws {
        steps.append(.persist)
        if let persistError { throw persistError }
        persisted = settings
    }

    func invalidateServiceControllers() {
        steps.append(.invalidate)
        controllersInvalidated = true
    }

    func restoreWebConfiguration(
        preferences: Preferences,
        websites: [Website],
        wasRunning: Bool
    ) async throws {
        steps.append(.restore)
        restoredPreferences = preferences
        if let restoreError { throw restoreError }
    }
}

private struct TestFailure: Error, LocalizedError {
    let text: String
    var errorDescription: String? { text }
}

/// 偏好项分类必须覆盖 `Preferences` 的每一个字段。
///
/// 新增偏好项时如果忘记登记到某一类，这里会失败——避免出现「改了设置却没生效」
/// 这种最难排查的问题（配置根本没重新生成，或者该停的服务没停）。
@Test func preferenceChangeClassificationCoversEveryField() {
    let fields = Set(Mirror(reflecting: Preferences()).children.compactMap(\.label))
    let unclassified = fields.subtracting(PreferenceChanges.classifiedKeys)
    #expect(
        unclassified.isEmpty,
        "新增的 Preferences 字段必须登记到 PreferenceChanges 的某一类：\(unclassified.sorted())"
    )
}

@Test func preferenceChangesClassifyControllerInvalidatingFields() {
    var next = Preferences()
    next.httpPort = 9090
    let changes = PreferenceChanges(from: Preferences(), to: next)
    #expect(changes.scope == .requiresControllerReset)
    #expect(changes.invalidatingKeys == ["httpPort"])
}

@Test func preferenceChangesIgnoreNonReconfiguringFields() {
    var next = Preferences()
    next.restoreLastSession = false
    next.autoStartWeb = true
    next.backupIntervalHours = 48
    let changes = PreferenceChanges(from: Preferences(), to: next)
    #expect(changes.scope == .none)
    #expect(changes.invalidatingKeys.isEmpty)
    #expect(changes.regeneratingKeys.isEmpty)
}

@Test func operationGateRejectsDuplicateSaveAndConcurrentOperations() {
    #expect(OperationGate().saveRejection == nil)
    #expect(OperationGate().serviceRejection == nil)

    #expect(OperationGate(savingSettings: true).saveRejection != nil)
    #expect(OperationGate(savingSettings: true).serviceRejection != nil)

    #expect(OperationGate(changingWebServices: true).saveRejection != nil)
    #expect(OperationGate(changingDatabase: true).saveRejection != nil)
    #expect(OperationGate(changingAllServices: true).saveRejection != nil)
    #expect(OperationGate(changingWebsite: true).saveRejection != nil)
    #expect(OperationGate(backingUpDatabase: true).saveRejection != nil)
    #expect(OperationGate(restoringDatabase: true).saveRejection != nil)

    // 服务切换中不应阻止服务操作本身，否则停止按钮会把自己挡住。
    #expect(OperationGate(changingWebServices: true).serviceRejection == nil)
}

@MainActor
@Test func reconfigurationValidatesBeforeStoppingAnything() async {
    let effects = RecordingReconfigurationEffects()
    effects.validateError = TestFailure(text: "端口重复")

    var next = WorkspaceSettings()
    next.preferences.httpPort = 9090

    let outcome = await ServiceReconfiguration.apply(
        previous: WorkspaceSettings(),
        next: next,
        webWasRunning: true,
        databaseWasRunning: true,
        effects: effects
    )

    #expect(outcome.isFailure)
    // 关键：校验失败时不能停掉正在运行的服务。
    #expect(effects.steps == [.validate])
    #expect(effects.persisted == nil)
}

@MainActor
@Test func reconfigurationStopsThenPersistsThenInvalidatesControllers() async {
    let effects = RecordingReconfigurationEffects()

    var next = WorkspaceSettings()
    next.preferences.httpPort = 9090

    let outcome = await ServiceReconfiguration.apply(
        previous: WorkspaceSettings(),
        next: next,
        webWasRunning: true,
        databaseWasRunning: true,
        effects: effects
    )

    #expect(outcome == .reconfigured(webRestarted: false))
    // 顺序固定：停服 → 持久化 → 才丢弃控制器。
    // 旧实现是先丢弃控制器再停服，正是「进程仍在跑但应用失去控制权」的根因。
    #expect(effects.steps == [.validate, .stopWeb, .stopDatabase, .persist, .invalidate])
    #expect(effects.controllersInvalidated)
    #expect(effects.persisted?.preferences.httpPort == 9090)
}

@MainActor
@Test func reconfigurationKeepsControllersWhenWebStopFails() async {
    let effects = RecordingReconfigurationEffects()
    effects.stopWebSucceeds = false

    var next = WorkspaceSettings()
    next.preferences.httpPort = 9090

    let outcome = await ServiceReconfiguration.apply(
        previous: WorkspaceSettings(),
        next: next,
        webWasRunning: true,
        databaseWasRunning: false,
        effects: effects
    )

    #expect(outcome.isFailure)
    #expect(!effects.controllersInvalidated)
    #expect(effects.persisted == nil)
    #expect(effects.steps == [.validate, .stopWeb])
}

@MainActor
@Test func reconfigurationKeepsControllersWhenDatabaseStopFails() async {
    let effects = RecordingReconfigurationEffects()
    effects.stopDatabaseSucceeds = false

    var next = WorkspaceSettings()
    next.preferences.databasePort = 4406

    let outcome = await ServiceReconfiguration.apply(
        previous: WorkspaceSettings(),
        next: next,
        webWasRunning: true,
        databaseWasRunning: true,
        effects: effects
    )

    #expect(outcome.isFailure)
    #expect(!effects.controllersInvalidated)
    #expect(effects.steps == [.validate, .stopWeb, .stopDatabase])
}

@MainActor
@Test func reconfigurationRegeneratesWithNewPreferencesAndRestoresOnFailure() async {
    let effects = RecordingReconfigurationEffects()
    effects.regenerateError = TestFailure(text: "httpd -t 失败")

    var next = WorkspaceSettings()
    next.preferences.httpPort = 9090

    // 把 httpPort 当作「只需重新生成配置」的项，以驱动 B 类路径。
    // 现实中 B 类项由阶段二引入；这里直接构造变更集验证回滚逻辑本身。
    let outcome = await ServiceReconfiguration.apply(
        previous: WorkspaceSettings(),
        next: next,
        changes: PreferenceChanges(regeneratingKeys: ["httpPort"]),
        webWasRunning: true,
        databaseWasRunning: false,
        effects: effects
    )

    #expect(outcome.isFailure)
    #expect(effects.steps == [.validate, .stopWeb, .regenerate, .restore])
    // 回滚必须使用**旧**设置，而不是新设置。
    #expect(effects.restoredPreferences?.httpPort == WorkspaceSettings().preferences.httpPort)
    #expect(effects.persisted == nil)
}

@MainActor
@Test func reconfigurationRegeneratesWithNewSettingsOnSuccess() async {
    let effects = RecordingReconfigurationEffects()

    var next = WorkspaceSettings()
    next.preferences.httpPort = 9090

    let outcome = await ServiceReconfiguration.apply(
        previous: WorkspaceSettings(),
        next: next,
        changes: PreferenceChanges(regeneratingKeys: ["httpPort"]),
        webWasRunning: true,
        databaseWasRunning: false,
        effects: effects
    )

    #expect(outcome == .reconfigured(webRestarted: true))
    #expect(effects.steps == [.validate, .stopWeb, .regenerate, .persist])
    // 必须用**新**设置重新生成——旧实现读的是 settings.preferences，那正是 bug 之一。
    #expect(effects.regeneratedPreferences?.httpPort == 9090)
    // B 类不丢弃控制器。
    #expect(!effects.controllersInvalidated)
}

@MainActor
@Test func reconfigurationRegeneratesConfigurationWhileWebIsStopped() async {
    let effects = RecordingReconfigurationEffects()
    var next = WorkspaceSettings()
    next.preferences.uploadMaxFilesizeMB = 128
    next.preferences.postMaxSizeMB = 160

    let outcome = await ServiceReconfiguration.apply(
        previous: WorkspaceSettings(),
        next: next,
        webWasRunning: false,
        databaseWasRunning: false,
        effects: effects
    )

    #expect(outcome == .reconfigured(webRestarted: false))
    #expect(effects.steps == [.validate, .regenerate, .persist])
    #expect(effects.regeneratedPreferences?.uploadMaxFilesizeMB == 128)
}

@MainActor
@Test func stoppedWebConfigurationIsRestoredWhenPersistenceFails() async {
    let effects = RecordingReconfigurationEffects()
    effects.persistError = TestFailure(text: "无法写入设置")
    var next = WorkspaceSettings()
    next.preferences.uploadMaxFilesizeMB = 128
    next.preferences.postMaxSizeMB = 160

    let outcome = await ServiceReconfiguration.apply(
        previous: WorkspaceSettings(),
        next: next,
        webWasRunning: false,
        databaseWasRunning: false,
        effects: effects
    )

    #expect(outcome.isFailure)
    #expect(effects.steps == [.validate, .regenerate, .persist, .restore])
    #expect(effects.restoredPreferences?.uploadMaxFilesizeMB == Preferences().uploadMaxFilesizeMB)
}

@MainActor
@Test func reconfigurationOnlyPersistsWhenNoRelevantChange() async {
    let effects = RecordingReconfigurationEffects()

    let outcome = await ServiceReconfiguration.apply(
        previous: WorkspaceSettings(),
        next: WorkspaceSettings(),
        webWasRunning: true,
        databaseWasRunning: true,
        effects: effects
    )

    #expect(outcome == .persistedOnly)
    #expect(effects.steps == [.validate, .persist])
    #expect(!effects.controllersInvalidated)
}

// MARK: - .htaccess 预检与 Apache 配置兼容性

/// 与既有测试一致，使用本机 Homebrew httpd 作为 ServerRoot。
private let testApache = URL(fileURLWithPath: "/opt/homebrew/opt/httpd/bin/httpd")
private let testPHPRoot = URL(fileURLWithPath: "/opt/homebrew/opt/php@8.2")

private func generateTestConfiguration(
    preferences: Preferences,
    websites: [Website] = [],
    documentRoot: URL,
    layout: RuntimeLayout,
    apache: URL = testApache
) throws -> WebStackConfiguration {
    try WebStackConfigurationGenerator().generate(
        installation: InstalledWebStack(
            apache: apache,
            php: testPHPRoot.appendingPathComponent("bin/php"),
            phpFPM: testPHPRoot.appendingPathComponent("sbin/php-fpm"),
            apacheVersion: "test",
            phpVersion: "test"
        ),
        preferences: preferences,
        documentRoot: documentRoot,
        layout: layout,
        websites: websites
    )
}

private func makeHtaccessFixture(_ body: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MacStackHtaccess-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data(body.utf8).write(to: root.appendingPathComponent(".htaccess"))
    return root
}

/// 预检必须求值 `<IfModule>` 条件，而不是一见到 `php_value` 就阻止站点。
///
/// 被 `<IfModule mod_php.c>` 包起来的指令会被 Apache 整体跳过，站点照常运行；
/// 只有**实际会被处理**的指令才会导致 HTTP 500。
@Test func htaccessPreflightEvaluatesIfModuleConditions() throws {
    let root = try makeHtaccessFixture("""
    # 顶层，会被处理
    php_value upload_max_filesize 128M
    <IfModule mod_php.c>
    php_value post_max_size 128M
    </IfModule>
    <IfModule !mod_php.c>
    php_flag display_errors On
    </IfModule>
    <IfModule rewrite_module>
    php_value memory_limit 256M
    </IfModule>
    """)
    defer { try? FileManager.default.removeItem(at: root) }

    let report = HtaccessPreflight().scan(publicRoot: root, loadedModules: ["rewrite"])
    let blockingLines = report.blockingFindings.map(\.line).sorted()

    // 顶层（2）、!mod_php.c 条件成立（7）、rewrite_module 已加载（10）→ 都会被执行。
    #expect(blockingLines == [2, 7, 10])
    #expect(report.hasBlockingFinding)

    // mod_php.c 未加载 → 整块被跳过 → 站点能跑，只是设置静默失效。
    let inactiveLines = report.findings.compactMap { finding -> Int? in
        if case .inactivePhpDirective(_, let line, _) = finding { return line }
        return nil
    }
    #expect(inactiveLines == [4])
}

@Test func htaccessPreflightReportsDirectivesNeedingUnloadedModules() throws {
    let root = try makeHtaccessFixture("""
    IndexOptions FancyIndexing
    ExpiresActive On
    """)
    defer { try? FileManager.default.removeItem(at: root) }

    // autoindex 与 expires 默认都不加载。
    let defaults = HtaccessPreflight().scan(
        publicRoot: root,
        loadedModules: ApacheModulePlan.loadedModules(for: Preferences())
    )
    let missing = defaults.findings.compactMap { finding -> String? in
        if case .missingModule(_, _, _, let module) = finding { return module }
        return nil
    }
    #expect(Set(missing) == ["autoindex", "expires"])
    // 模块缺失不是阻塞项——提示用户开启即可。
    #expect(!defaults.hasBlockingFinding)

    // 在设置里开启后应当不再有发现。
    var enabled = Preferences()
    enabled.optionalApacheModules = ["autoindex", "expires"]
    let resolved = HtaccessPreflight().scan(
        publicRoot: root,
        loadedModules: ApacheModulePlan.loadedModules(for: enabled)
    )
    #expect(resolved.findings.isEmpty)
}

@Test func htaccessPreflightNormalizesModuleTokens() {
    #expect(HtaccessPreflight.normalizeModuleToken("mod_php.c") == "php")
    #expect(HtaccessPreflight.normalizeModuleToken("mod_rewrite.c") == "rewrite")
    #expect(HtaccessPreflight.normalizeModuleToken("php_module") == "php")
    #expect(HtaccessPreflight.normalizeModuleToken("rewrite_module") == "rewrite")
    // 版本后缀不是「模块名后缀」，应保留。
    #expect(HtaccessPreflight.normalizeModuleToken("php7_module") == "php7")
}

@Test func htaccessPreflightSkipsDependencyDirectoriesAndSymlinks() throws {
    let root = try makeHtaccessFixture("php_value upload_max_filesize 1M")
    defer { try? FileManager.default.removeItem(at: root) }
    let vendor = root.appendingPathComponent("vendor", isDirectory: true)
    try FileManager.default.createDirectory(at: vendor, withIntermediateDirectories: true)
    try Data("php_value memory_limit 1M".utf8).write(to: vendor.appendingPathComponent(".htaccess"))

    let report = HtaccessPreflight().scan(publicRoot: root, loadedModules: [])
    #expect(report.scannedFileCount == 1)
    #expect(report.blockingFindings.count == 1)
}

@Test func siteOptionsExplicitlyDisableFollowSymLinks() throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("MacStackTests-\(UUID())")
    let shortRuntime = URL(fileURLWithPath: "/tmp/macstack-\(UUID().uuidString.prefix(8))", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: temporary)
        try? FileManager.default.removeItem(at: shortRuntime)
    }
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)

    let generated = try generateTestConfiguration(
        preferences: Preferences(),
        documentRoot: temporary.appendingPathComponent("www"),
        layout: RuntimeLayout(root: shortRuntime)
    ).apache

    // FollowSymLinks 是 Apache 的默认值，而带 +/- 前缀的 Options 是「合并到当前生效集合」。
    // 只写 +SymLinksIfOwnerMatch 会让继承来的默认 FollowSymLinks 继续生效，比预期宽松。
    #expect(generated.contains("Options -Indexes -FollowSymLinks +SymLinksIfOwnerMatch"))
    // 目录列表仍然禁止。
    #expect(!generated.contains("Options Indexes"))
}

@Test func htaccessPolicyAppliesToDefaultRootAndRegisteredSitesEqually() throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("MacStackTests-\(UUID())")
    let shortRuntime = URL(fileURLWithPath: "/tmp/macstack-\(UUID().uuidString.prefix(8))", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: temporary)
        try? FileManager.default.removeItem(at: shortRuntime)
    }
    let siteRoot = temporary.appendingPathComponent("site", isDirectory: true)
    try FileManager.default.createDirectory(at: siteRoot, withIntermediateDirectories: true)

    let generated = try generateTestConfiguration(
        preferences: Preferences(),
        websites: [Website(name: "site", rootPath: siteRoot.path, port: 8081, isEnabled: true)],
        documentRoot: temporary.appendingPathComponent("www"),
        layout: RuntimeLayout(root: shortRuntime)
    ).apache

    // 默认站点 www 就是 htdocs 的对应目录，必须与登记网站同等对待：
    // 两处都放开覆盖，只有内部健康检查目录保持 None。
    let sitePolicyCount = generated.components(separatedBy: "AllowOverride FileInfo Indexes AuthConfig Limit").count - 1
    #expect(sitePolicyCount == 2)
    let managedCount = generated.components(separatedBy: "AllowOverride None").count - 1
    #expect(managedCount == 1)
    #expect(generated.contains("Options -Indexes -FollowSymLinks\n"))
}

@Test func allowOverrideReflectsPreferences() throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("MacStackTests-\(UUID())")
    let shortRuntime = URL(fileURLWithPath: "/tmp/macstack-\(UUID().uuidString.prefix(8))", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: temporary)
        try? FileManager.default.removeItem(at: shortRuntime)
    }
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    let layout = RuntimeLayout(root: shortRuntime)
    let documentRoot = temporary.appendingPathComponent("www")

    var disabled = Preferences()
    disabled.allowHtaccess = false
    let closed = try generateTestConfiguration(
        preferences: disabled, documentRoot: documentRoot, layout: layout
    ).apache
    #expect(!closed.contains("AllowOverride FileInfo"))
    #expect(closed.components(separatedBy: "AllowOverride None").count - 1 == 2)

    var optionsOpen = Preferences()
    optionsOpen.allowHtaccessOptions = true
    let opened = try generateTestConfiguration(
        preferences: optionsOpen, documentRoot: documentRoot, layout: layout
    ).apache
    #expect(opened.contains("AllowOverride All"))
}

@Test func requiredApacheModulesLoadOnlyWhenHtaccessEnabled() throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("MacStackTests-\(UUID())")
    let shortRuntime = URL(fileURLWithPath: "/tmp/macstack-\(UUID().uuidString.prefix(8))", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: temporary)
        try? FileManager.default.removeItem(at: shortRuntime)
    }
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    let layout = RuntimeLayout(root: shortRuntime)
    let documentRoot = temporary.appendingPathComponent("www")

    let enabled = try generateTestConfiguration(
        preferences: Preferences(), documentRoot: documentRoot, layout: layout
    ).apache
    for name in ApacheModulePlan.requiredForHtaccess {
        #expect(enabled.contains("LoadModule \(name)_module"), "缺少必需模块 \(name)")
    }
    // 这两个都不提供任何 .htaccess 覆盖类，默认不加载。
    #expect(!enabled.contains("mod_status.so"))
    #expect(!enabled.contains("mod_autoindex.so"))

    var closed = Preferences()
    closed.allowHtaccess = false
    let disabled = try generateTestConfiguration(
        preferences: closed, documentRoot: documentRoot, layout: layout
    ).apache
    #expect(!disabled.contains("LoadModule rewrite_module"))
}

@Test func optionalModuleDependenciesLoadFilterBeforeDeflate() {
    var preferences = Preferences()
    preferences.optionalApacheModules = ["deflate"]
    let modules = ApacheModulePlan.modulesToLoad(for: preferences)
    let filterIndex = modules.firstIndex(of: "filter")
    let deflateIndex = modules.firstIndex(of: "deflate")
    #expect(filterIndex != nil)
    #expect(deflateIndex != nil)
    if let filterIndex, let deflateIndex { #expect(filterIndex < deflateIndex) }

    var noHtaccess = Preferences()
    noHtaccess.allowHtaccess = false
    #expect(ApacheModulePlan.modulesToLoad(for: noHtaccess).isEmpty)
}

@Test func missingRequiredApacheModuleFailsLoudlyInsteadOfSilentlySkipping() throws {
    let serverRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("MacStackServerRoot-\(UUID())", isDirectory: true)
    let shortRuntime = URL(fileURLWithPath: "/tmp/macstack-\(UUID().uuidString.prefix(8))", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: serverRoot)
        try? FileManager.default.removeItem(at: shortRuntime)
    }
    let moduleDirectory = serverRoot.appendingPathComponent("lib/httpd/modules", isDirectory: true)
    try FileManager.default.createDirectory(at: moduleDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: serverRoot.appendingPathComponent("etc/httpd"), withIntermediateDirectories: true)
    try Data().write(to: serverRoot.appendingPathComponent("etc/httpd/mime.types"))
    // 只放基础模块，故意不放 rewrite 等 .htaccess 必需模块。
    for name in ApacheModulePlan.baseModules {
        try Data().write(to: moduleDirectory.appendingPathComponent("mod_\(name).so"))
    }

    let installation = InstalledWebStack(
        apache: serverRoot.appendingPathComponent("bin/httpd"),
        php: testPHPRoot.appendingPathComponent("bin/php"),
        phpFPM: testPHPRoot.appendingPathComponent("sbin/php-fpm"),
        apacheVersion: "test",
        phpVersion: "test"
    )
    #expect(throws: WebStackError.self) {
        try WebStackConfigurationGenerator().generate(
            installation: installation,
            preferences: Preferences(),
            documentRoot: serverRoot.appendingPathComponent("www"),
            layout: RuntimeLayout(root: shortRuntime)
        )
    }
}

@Test func typesConfigPrefersBundledMimeTypesOverSystemPath() throws {
    let serverRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("MacStackServerRoot-\(UUID())", isDirectory: true)
    let shortRuntime = URL(fileURLWithPath: "/tmp/macstack-\(UUID().uuidString.prefix(8))", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: serverRoot)
        try? FileManager.default.removeItem(at: shortRuntime)
    }
    let moduleDirectory = serverRoot.appendingPathComponent("lib/httpd/modules", isDirectory: true)
    try FileManager.default.createDirectory(at: moduleDirectory, withIntermediateDirectories: true)
    for name in ApacheModulePlan.baseModules + ApacheModulePlan.requiredForHtaccess {
        try Data().write(to: moduleDirectory.appendingPathComponent("mod_\(name).so"))
    }
    let bundledTypes = serverRoot.appendingPathComponent("etc/httpd/mime.types")
    try FileManager.default.createDirectory(at: serverRoot.appendingPathComponent("etc/httpd"), withIntermediateDirectories: true)
    try Data().write(to: bundledTypes)

    let generated = try generateTestConfiguration(
        preferences: Preferences(),
        documentRoot: serverRoot.appendingPathComponent("www"),
        layout: RuntimeLayout(root: shortRuntime),
        apache: serverRoot.appendingPathComponent("bin/httpd")
    ).apache

    // 引用运行时自带的副本，而不是写死系统的 /etc/apache2/mime.types。
    let typesLine = generated.split(separator: "\n").first { $0.hasPrefix("TypesConfig") }.map(String.init) ?? "<缺失>"
    #expect(typesLine == "TypesConfig \"\(bundledTypes.path)\"", "实际生成：\(typesLine)")
    #expect(!generated.contains("/etc/apache2/mime.types"))
}

@Test func phpIniReflectsUploadLimitsAndTimezone() throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("MacStackTests-\(UUID())")
    let shortRuntime = URL(fileURLWithPath: "/tmp/macstack-\(UUID().uuidString.prefix(8))", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: temporary)
        try? FileManager.default.removeItem(at: shortRuntime)
    }
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)

    var preferences = Preferences()
    preferences.memoryLimitMB = 256
    preferences.uploadMaxFilesizeMB = 32
    preferences.postMaxSizeMB = 48
    preferences.phpTimezone = "Asia/Shanghai"

    let php = try generateTestConfiguration(
        preferences: preferences,
        documentRoot: temporary.appendingPathComponent("www"),
        layout: RuntimeLayout(root: shortRuntime)
    ).php

    #expect(php.contains("memory_limit = 256M"))
    #expect(php.contains("upload_max_filesize = 32M"))
    #expect(php.contains("post_max_size = 48M"))
    #expect(php.contains("date.timezone = Asia/Shanghai"))
}

@Test func phpTimezoneFallsBackToSystemWhenEmpty() {
    var preferences = Preferences()
    #expect(preferences.resolvedTimezone == TimeZone.current.identifier || !preferences.resolvedTimezone.isEmpty)

    preferences.phpTimezone = "Asia/Shanghai"
    #expect(preferences.resolvedTimezone == "Asia/Shanghai")

    // 非法值在 validate 里会被拒绝；解析本身也要能安全回退。
    preferences.phpTimezone = "Not/AZone"
    #expect(preferences.resolvedTimezone != "Not/AZone")
}

@Test func preferenceValidationRejectsInconsistentPhpLimits() {
    var preferences = Preferences()

    // post_max_size 必须严格大于 upload_max_filesize：multipart 还有额外开销。
    preferences.uploadMaxFilesizeMB = 64
    preferences.postMaxSizeMB = 64
    #expect(throws: SettingsError.self) { try preferences.validate() }

    // memory_limit 必须容纳得下一整个 post_max_size。
    preferences.postMaxSizeMB = 80
    preferences.memoryLimitMB = 64
    #expect(throws: SettingsError.self) { try preferences.validate() }

    preferences.memoryLimitMB = 512
    #expect((try? preferences.validate()) != nil)

    preferences.phpTimezone = "Not/AZone"
    #expect(throws: SettingsError.self) { try preferences.validate() }

    preferences.phpTimezone = ""
    preferences.optionalApacheModules = ["status"]
    #expect(throws: SettingsError.self) { try preferences.validate() }
}

@Test func preferenceChangesClassifyConfigurationOnlyFields() {
    var next = Preferences()
    next.uploadMaxFilesizeMB = 128
    next.postMaxSizeMB = 160
    let changes = PreferenceChanges(from: Preferences(), to: next)
    #expect(changes.scope == .configurationOnly)
    #expect(Set(changes.regeneratingKeys) == ["uploadMaxFilesizeMB", "postMaxSizeMB"])
}

@Test func optionalModuleOrderDoesNotCountAsChange() {
    var old = Preferences()
    old.optionalApacheModules = ["expires", "deflate"]
    var updated = Preferences()
    updated.optionalApacheModules = ["deflate", "expires"]
    #expect(PreferenceChanges(from: old, to: updated).scope == .none)
}



/// 导出、导入、查询必须使用同一个字符集。
///
/// 曾经只有导出侧（`mariadb-dump`）指定了 `utf8mb4`，而导入、查询、执行 SQL 三处
/// 沿用客户端默认字符集，结果含非 ASCII 内容的库在「导出 → 恢复」往返后变成乱码：
/// `动态内容` → `Ŋ�ƀ�ņ�Ů�`。当时三处各写一份参数，漏了谁也看不出来。
/// 这个测试锁住「公共参数里必须带字符集」这条不变量。
@Test func databaseClientArgumentsAlwaysSpecifyCharacterSet() {
    let arguments = DatabaseClientArguments.standard(
        socket: URL(fileURLWithPath: "/tmp/macstack.sock"),
        user: "tester"
    )
    #expect(arguments.contains("--default-character-set=utf8mb4"))
    #expect(arguments.contains("--socket=/tmp/macstack.sock"))
    #expect(arguments.contains("--user=tester"))
    // --no-defaults 仍然必要：避免读取 /etc/my.cnf 之类的全局配置。
    #expect(arguments.contains("--no-defaults"))
}

/// 需要未授予覆盖类的指令必须被拦下。
///
/// MacStack 默认的 `AllowOverride FileInfo Indexes AuthConfig Limit` **刻意不含
/// `Options`**（否则站点能用 `.htaccess` 推翻 `-FollowSymLinks` 加固）。代价是裸
/// `Options` 会让 Apache 报 "not allowed here" 并返回 500 —— 这一点已用真实 Apache 实测确认。
/// 之前预检只查 `php_value` 和模块依赖，完全漏掉了这一类。
@Test func htaccessPreflightRejectsDirectivesNeedingUngrantedOverrideClass() throws {
    let root = try makeHtaccessFixture("Options -MultiViews -Indexes")
    defer { try? FileManager.default.removeItem(at: root) }

    let report = HtaccessPreflight().scan(publicRoot: root, loadedModules: [])
    #expect(report.hasBlockingFinding)
    guard case .overrideNotPermitted(_, let line, let directive, let required) = report.blockingFindings.first else {
        Issue.record("应为 overrideNotPermitted，实际：\(report.findings)")
        return
    }
    #expect(line == 1)
    #expect(directive == "Options")
    #expect(required == "Options")
    // 提示里要给出可执行的出路。
    #expect(report.summary?.contains("允许 .htaccess 覆盖 Options") == true)

    // 显式开启后应当放行。
    let allowed = HtaccessPreflight().scan(
        publicRoot: root, loadedModules: [], allowsOptionsOverride: true
    )
    #expect(allowed.findings.isEmpty)
}

/// Laravel / Symfony 官方 `.htaccess` 的写法必须**不**被拦下。
///
/// 它的 `Options -MultiViews -Indexes` 被包在 `<IfModule mod_negotiation.c>` 里，
/// 而 MacStack 不加载 mod_negotiation —— Apache 会整块跳过，因此不会报错。
/// 如果不求值 `IfModule` 就一刀切，会把标准框架项目误判成不能启用。
@Test func htaccessPreflightAcceptsFrameworkStyleOptionsInsideSkippedIfModule() throws {
    let root = try makeHtaccessFixture("""
    <IfModule mod_rewrite.c>
        <IfModule mod_negotiation.c>
            Options -MultiViews -Indexes
        </IfModule>
        RewriteEngine On
        RewriteCond %{REQUEST_FILENAME} !-f
        RewriteRule ^ index.php [L]
    </IfModule>
    """)
    defer { try? FileManager.default.removeItem(at: root) }

    // mod_negotiation 未加载 → 内层整块被跳过 → Options 不会被执行，不阻塞。
    let skipped = HtaccessPreflight().scan(
        publicRoot: root, loadedModules: ApacheModulePlan.loadedModules(for: Preferences())
    )
    #expect(!skipped.hasBlockingFinding)
    #expect(skipped.findings.isEmpty)

    // 一旦加载了 mod_negotiation，该块会生效，就必须拦下。
    let active = HtaccessPreflight().scan(
        publicRoot: root,
        loadedModules: ApacheModulePlan.loadedModules(for: Preferences()).union(["negotiation"])
    )
    #expect(active.hasBlockingFinding)
}
