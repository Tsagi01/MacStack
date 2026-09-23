import Foundation
import Darwin
import MacStackCore

@main
struct MacStackCLI {
    static func main() async {
        // 与 GUI 同一套信号基线：验收套件里也会走数据库恢复，同样会遇到断管道。
        ProcessSignalBaseline.ignoreSIGPIPE()
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard let command = arguments.first,
                  ["prepare", "smoke-test", "prepare-database", "database-smoke-test", "database-backup-smoke-test", "prepare-phpmyadmin", "full-smoke-test", "audit-xampp", "sites-smoke-test", "htaccess-smoke-test", "health-probe"].contains(command) else {
                print("用法：macstackctl prepare [网站目录]\n      macstackctl smoke-test\n      macstackctl sites-smoke-test\n      macstackctl htaccess-smoke-test\n      macstackctl health-probe [--port N] [--host 域名] [--path /]\n      macstackctl prepare-database\n      macstackctl database-smoke-test\n      macstackctl database-backup-smoke-test\n      macstackctl prepare-phpmyadmin\n      macstackctl full-smoke-test\n      macstackctl audit-xampp [XAMPP目录]")
                exit(arguments.isEmpty ? 0 : 64)
            }
            if command == "health-probe" {
                try await runHealthProbe(Array(arguments.dropFirst()))
                return
            }
            if command == "audit-xampp" {
                let root = arguments.count > 1
                    ? URL(fileURLWithPath: arguments[1], isDirectory: true)
                    : URL(fileURLWithPath: "/Applications/XAMPP", isDirectory: true)
                let auditor = XAMPPAuditor(root: root)
                let report = try auditor.audit()
                let url = try auditor.writeReport(report)
                print("旧 XAMPP 只读盘点完成：\(url.path)")
                print("网站候选 \(report.sites.count) 个；可能的业务数据库 \(report.businessDatabases.count) 个。未执行迁移或修改。")
                return
            }
            let settings = try SettingsStore().load()
            if command == "sites-smoke-test" {
                try await runSitesSmokeTest()
                return
            }
            if command == "htaccess-smoke-test" {
                try await runHtaccessSmokeTest()
                return
            }
            if command == "prepare-phpmyadmin" || command == "full-smoke-test" {
                let phpMyAdmin = try PHPMyAdminPreparer().prepare(
                    installation: PHPMyAdminResolver().resolve(),
                    databasePort: settings.preferences.databasePort
                )
                print("phpMyAdmin \(phpMyAdmin.version)：\(phpMyAdmin.directory.path)")
                if command == "prepare-phpmyadmin" { return }

                let databaseInstallation = try DatabaseStackResolver().resolve()
                let database = try DatabaseStackPreparer().prepare(
                    installation: databaseInstallation,
                    preferences: settings.preferences
                )
                let webInstallation = try WebStackResolver(preferredFormula: settings.preferences.preferredPHPFormula).resolve()
                let web = try WebStackPreparer().prepare(
                    installation: webInstallation,
                    preferences: settings.preferences,
                    websites: settings.websites
                )
                let databaseController = LocalDatabaseController(
                    installation: databaseInstallation,
                    layout: database.layout,
                    databasePort: settings.preferences.databasePort
                )
                let webController = LocalWebStackController(installation: webInstallation, layout: web.layout)
                do {
                    let databaseVersion = try await databaseController.startAndCheck()
                    try await webController.startWebStack(httpPort: settings.preferences.httpPort)
                    let url = URL(string: "http://127.0.0.1:\(settings.preferences.httpPort)/phpmyadmin/")!
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 5
                    let (data, response) = try await URLSession.shared.data(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    let body = String(decoding: data, as: UTF8.self)
                    guard status == 200, body.localizedCaseInsensitiveContains("phpmyadmin") else {
                        throw ServiceControlError.healthCheckFailed("phpMyAdmin 页面返回 HTTP \(status)。")
                    }
                    print("全栈检查通过：PHP 8.2、MariaDB \(databaseVersion)、phpMyAdmin 登录页 HTTP 200。")
                    try await webController.stopWebStack()
                    try await databaseController.stop(.mariadb)
                    print("全部服务已正常停止。")
                } catch {
                    try? await webController.stopWebStack()
                    try? await databaseController.stop(.mariadb)
                    throw error
                }
                return
            }
            if command == "prepare-database" || command == "database-smoke-test" || command == "database-backup-smoke-test" {
                let installation = try DatabaseStackResolver().resolve()
                let prepared = try DatabaseStackPreparer().prepare(
                    installation: installation,
                    preferences: settings.preferences
                )
                print("MariaDB: \(installation.version)")
                print(prepared.initializedNow ? "已初始化新的 MacStack 数据目录。" : "已识别现有 MacStack 数据目录，未重新初始化。")
                print("数据目录：\(prepared.layout.databaseDirectory.path)")
                if command == "database-smoke-test" || command == "database-backup-smoke-test" {
                    let controller = LocalDatabaseController(
                        installation: installation,
                        layout: prepared.layout,
                        databasePort: settings.preferences.databasePort
                    )
                    do {
                        let version = try await controller.startAndCheck()
                        print("真实数据库查询通过：SELECT VERSION() = \(version)")
                        if command == "database-backup-smoke-test" {
                            try runDatabaseBackupSmokeTest(installation: installation, layout: prepared.layout)
                        }
                        try await controller.stop(.mariadb)
                        print("MariaDB 已正常关闭。")
                    } catch {
                        try? await controller.stop(.mariadb)
                        throw error
                    }
                }
                return
            }
            let installation = try WebStackResolver(preferredFormula: settings.preferences.preferredPHPFormula).resolve()
            let root = command == "prepare" && arguments.count > 1
                ? URL(fileURLWithPath: arguments[1], isDirectory: true)
                : nil
            let prepared = try WebStackPreparer().prepare(
                installation: installation,
                preferences: settings.preferences,
                documentRoot: root,
                websites: settings.websites
            )
            print("Apache: \(installation.apacheVersion)")
            print("PHP: \(installation.phpVersion)")
            print("配置校验通过：\(prepared.layout.configurationDirectory.path)")
            print("网站目录：\(prepared.documentRoot.path)")
            if command == "smoke-test" {
                let controller = LocalWebStackController(installation: installation, layout: prepared.layout)
                do {
                    try await controller.startWebStack(httpPort: settings.preferences.httpPort)
                    print("独立的 PHP 健康检查通过；用户 index.php 内容不参与启动判断。")
                    try await controller.startWebStack(httpPort: settings.preferences.httpPort)
                    print("重复启动保护通过：没有创建第二套进程。")
                    try await controller.stopWebStack()
                    print("Apache 与 PHP-FPM 已正常停止。")
                } catch {
                    try? await controller.stopWebStack()
                    throw error
                }
            }
        } catch {
            // 用抛错版写入。非抛错的 `write(_:)` 在断管道上抛 NSException，
            // Swift 接不住 —— 那会在**报错的时候**再崩一次。
            // 典型触发：`macstackctl ... | head`，head 退出后我们的 stderr 就是断管道。
            // 这里本就是在报错，写不出去就安静退出，不能再把错误变成崩溃。
            try? FileHandle.standardError.write(contentsOf: Data("MacStack：\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func runDatabaseBackupSmokeTest(
        installation: InstalledDatabaseStack,
        layout: RuntimeLayout
    ) throws {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
        let database = "macstack_backup_\(suffix)"
        let backup = FileManager.default.temporaryDirectory.appendingPathComponent("\(database).sql")
        let manager = DatabaseBackupManager(installation: installation, layout: layout)
        defer {
            try? manager.executeSQL("DROP DATABASE IF EXISTS `\(database)`;")
            try? FileManager.default.removeItem(at: backup)
        }
        try manager.executeSQL("""
        CREATE DATABASE `\(database)` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
        CREATE TABLE `\(database)`.`items` (id INT PRIMARY KEY, value VARCHAR(100));
        CREATE TRIGGER `\(database)`.`items_upper` BEFORE INSERT ON `\(database)`.`items`
          FOR EACH ROW SET NEW.value = UPPER(NEW.value);
        INSERT INTO `\(database)`.`items` VALUES (1, '动态内容');
        CREATE VIEW `\(database)`.`item_view` AS SELECT id, value FROM `\(database)`.`items`;
        """)
        try manager.exportDatabase(named: database, to: backup)
        // 导出文件里是整份数据库内容，必须只有属主可读。这条断言**端到端**锁定最终权限。
        //
        // 它抓的是「创建时的 0600 与事后的 chmod **都**被去掉」——两者对最终权限互为冗余，
        // 只去掉任何一个都不会失败（实测过）。所以它挡不住「去掉 chmod」，那种情况下
        // 最终权限仍由创建时的 attributes 保证。
        //
        // 窗口问题（文件在导出过程中是否已经是 0600）不在断言范围内：事后观测不到。
        // 那部分由 createOwnerOnlyFile 的调用位置保证，单元测试覆盖其本身。
        let backupMode = (try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber)?.int16Value ?? 0
        guard backupMode == 0o600 else {
            throw DatabaseBackupError.invalidDestination(
                "导出文件权限是 \(String(backupMode, radix: 8))，应为 600：\(backup.path)"
            )
        }
        try manager.executeSQL("DROP DATABASE `\(database)`;")
        guard try !manager.listDatabases().contains(database) else {
            throw DatabaseBackupError.commandFailed("backup smoke drop", 1, "临时数据库未删除。")
        }
        try manager.restoreBackup(from: backup)
        let value = try manager.query("SELECT value FROM `\(database)`.`item_view` WHERE id=1;")
        let triggerCount = try manager.query("SELECT COUNT(*) FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA='\(database)';")
        guard value == "动态内容", triggerCount == "1" else {
            throw DatabaseBackupError.commandFailed(
                "backup smoke verify", 1, "恢复结果不完整：value=\(value), triggers=\(triggerCount)"
            )
        }

        // 再走一遍 GUI 实际使用的流式恢复路径（DatabaseRestoreJob）。
        //
        // 这条路径有自己一份命令行参数，曾经与导出侧字符集不一致（导出 utf8mb4、
        // 导入用客户端默认），导致中文数据往返后损坏。上面那条走的是
        // DatabaseBackupManager.restoreBackup，覆盖不到这里，所以必须单独验证。
        try manager.executeSQL("DROP DATABASE `\(database)`;")
        let job = DatabaseRestoreJob(installation: installation, layout: layout)
        let plan = try job.prepare(source: backup)
        try job.restore(plan: plan) { _, _ in }
        let streamedValue = try manager.query("SELECT value FROM `\(database)`.`item_view` WHERE id=1;")
        guard streamedValue == "动态内容" else {
            throw DatabaseBackupError.commandFailed(
                "streaming restore verify", 1,
                "流式恢复后中文数据损坏：value=\(streamedValue)（应为 动态内容）。"
            )
        }
        print("数据库备份恢复检查通过：数据、视图和触发器均已恢复；临时库随后删除。")
        print("流式恢复检查通过：DatabaseRestoreJob 路径的中文数据往返正常。")

        // 坏 SQL 的恢复必须报出 mariadb 自己的错误，而不是「Broken pipe」。
        //
        // mariadb 客户端在批处理模式下**遇错即停**：SQL 有语法错误就立刻退出，
        // 管道读端关闭，我们后续的写入抛出 EPIPE。如果直接把这个 EPIPE 报给用户，
        // 真正的原因（ERROR 1064 at line N）就被丢掉了。
        //
        // 文件要足够大：mariadb 必须先退出、而我们还在写，才会触发 EPIPE。
        // 所以第一句就写错，后面跟几 MB 的正常语句。
        let brokenDump = FileManager.default.temporaryDirectory
            .appendingPathComponent("macstack_broken_\(UUID().uuidString.prefix(8)).sql")
        defer { try? FileManager.default.removeItem(at: brokenDump) }
        var broken = "THIS IS NOT VALID SQL;\n"
        while broken.utf8.count < 6 * 1_024 * 1_024 {
            broken += "SELECT 1;\n"
        }
        try Data(broken.utf8).write(to: brokenDump)

        let brokenJob = DatabaseRestoreJob(installation: installation, layout: layout)
        let brokenPlan = try brokenJob.prepare(source: brokenDump)
        var brokenMessage: String?
        do {
            try brokenJob.restore(plan: brokenPlan) { _, _ in }
        } catch {
            brokenMessage = error.localizedDescription
        }
        guard let brokenMessage else {
            throw DatabaseBackupError.invalidBackup("坏 SQL 的恢复竟然成功了。")
        }
        guard !brokenMessage.lowercased().contains("broken pipe"),
              brokenMessage.lowercased().contains("error") else {
            throw DatabaseBackupError.commandFailed(
                "broken restore diagnostic", 1,
                "坏 SQL 的报错没有体现真正原因，实际消息：\(brokenMessage)"
            )
        }
        print("坏 SQL 的报错检查通过：报出的是 mariadb 的错误而非「Broken pipe」。")

        // 取消恢复：必须在写入过程中终止子进程，然后报出「已取消」而不是别的错误。
        //
        // 这条路径此前完全没有端到端覆盖，而它恰好落在最容易出问题的地方——
        // 子进程被终止后管道断开，我们还在写（正是 SIGPIPE 崩溃所在的那条路）。
        // 用户点「取消」是常见操作，不能只靠单元测试里那个假实现来保证。
        let bigDump = FileManager.default.temporaryDirectory
            .appendingPathComponent("macstack_cancel_\(UUID().uuidString.prefix(8)).sql")
        defer { try? FileManager.default.removeItem(at: bigDump) }
        // 4 MB 足够：取消发生在写完**第一块（1 MB）**之后，那时还剩 3 MB 没写，
        // 恢复必然仍在进行中。文件不必更大——回归时若取消失效，整份都会被执行。
        var bulk = "CREATE TABLE IF NOT EXISTS `\(database)`.`cancel_probe` (v INT);\n"
        while bulk.utf8.count < 4 * 1_024 * 1_024 {
            bulk += "INSERT INTO `\(database)`.`cancel_probe` VALUES (1);\n"
        }
        try Data(bulk.utf8).write(to: bigDump)

        let cancelJob = DatabaseRestoreJob(installation: installation, layout: layout)
        let cancelPlan = try cancelJob.prepare(source: bigDump)
        // 进度回调是 @Sendable，不能直接改捕获的局部变量，用带锁的一次性标志。
        let cancelFlag = OneShotFlag()
        do {
            try cancelJob.restore(plan: cancelPlan) { completed, _ in
                // 写完第一块就取消，此时剩余内容还没写、恢复必然还在进行中。
                if completed >= 1_024 * 1_024, cancelFlag.fire() {
                    cancelJob.cancel()
                }
            }
            throw DatabaseBackupError.commandFailed(
                "cancel restore", 1, "取消后恢复竟然正常返回了。"
            )
        } catch DatabaseBackupError.restoreCancelled {
            // 期望：报「已取消」，而不是 EPIPE 或退出码错误。
        }
        guard cancelFlag.hasFired else {
            throw DatabaseBackupError.commandFailed("cancel restore", 1, "没能在写入过程中触发取消。")
        }
        print("取消恢复检查通过：写入过程中取消 → 报出「已取消」，未崩溃、未卡住。")

        // 库名以 `--` 开头时，导出必须仍然把它当库名而不是命令行选项。
        //
        // MariaDB 接受这种库名（实测 `--evil` 可以创建），而库名是从服务器读回来的外部
        // 数据。不加 `--` 终止符的话，一个叫 `--result-file=/some/path` 的库会让
        // mariadb-dump 把导出写到任意路径——已实测确认。这里用 `--evil` 验证修复生效：
        // 没有 `--` 时 mariadb-dump 会直接报 `unknown option '--evil'`。
        //
        // 刻意不用 `createDatabase`（它按 MacStack 自己的严格命名规则校验），
        // 否则造不出这个库名。
        let dashedDatabase = "--evil"
        try manager.executeSQL("CREATE DATABASE `\(dashedDatabase)`;")
        defer { try? manager.executeSQL("DROP DATABASE IF EXISTS `\(dashedDatabase)`;") }
        try manager.executeSQL("CREATE TABLE `\(dashedDatabase)`.`t` (v INT);")
        let dashedBackup = FileManager.default.temporaryDirectory
            .appendingPathComponent("macstack_backup_dashed_\(UUID().uuidString.prefix(8)).sql")
        defer { try? FileManager.default.removeItem(at: dashedBackup) }
        try manager.exportDatabase(named: dashedDatabase, to: dashedBackup)
        guard let dashedText = try? String(contentsOf: dashedBackup, encoding: .utf8),
              dashedText.contains("CREATE DATABASE") else {
            throw DatabaseBackupError.invalidBackup("以 -- 开头的库名导出结果异常：\(dashedBackup.path)")
        }
        print("库名以 -- 开头时的导出检查通过：被当作库名而非命令行选项。")
    }

    private static func runSitesSmokeTest() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("MacStackSiteSmoke-\(UUID())", isDirectory: true)
        let phpRoot = root.appendingPathComponent("PHP 站点", isDirectory: true)
        let staticRoot = root.appendingPathComponent("静态站点", isDirectory: true)
        let shortRuntime = URL(fileURLWithPath: "/tmp/macstack-sites-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let layout = RuntimeLayout(root: shortRuntime)
        try files.createDirectory(at: phpRoot, withIntermediateDirectories: true)
        try files.createDirectory(at: staticRoot.appendingPathComponent("assets", isDirectory: true), withIntermediateDirectories: true)
        defer {
            try? files.removeItem(at: root)
            try? files.removeItem(at: shortRuntime)
        }
        try Data("<?php header('Content-Type: text/plain'); echo 'DYNAMIC-' . PHP_VERSION;".utf8)
            .write(to: phpRoot.appendingPathComponent("index.php"))
        try Data("<link rel=\"stylesheet\" href=\"/assets/site.css\"><h1>STATIC-SITE</h1>".utf8)
            .write(to: staticRoot.appendingPathComponent("index.html"))
        try Data("body{color:rgb(1,2,3)}".utf8).write(to: staticRoot.appendingPathComponent("assets/site.css"))
        try Data("SECRET".utf8).write(to: staticRoot.appendingPathComponent(".env"))
        try files.createDirectory(
            at: staticRoot.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("SECRET-GIT".utf8).write(to: staticRoot.appendingPathComponent(".git/config"))

        let availability = PortAvailability()
        var excluded = Set<Int>()
        guard let managementPort = availability.nextAvailable(startingAt: 18080, excluding: excluded) else {
            throw ServiceControlError.healthCheckFailed("找不到测试管理端口。")
        }
        excluded.insert(managementPort)
        guard let phpPort = availability.nextAvailable(startingAt: managementPort + 1, excluding: excluded) else {
            throw ServiceControlError.healthCheckFailed("找不到 PHP 站点测试端口。")
        }
        excluded.insert(phpPort)
        guard let staticPort = availability.nextAvailable(startingAt: phpPort + 1, excluding: excluded) else {
            throw ServiceControlError.healthCheckFailed("找不到静态站点测试端口。")
        }
        var preferences = Preferences()
        preferences.httpPort = managementPort
        preferences.databasePort = 19999 == managementPort || 19999 == phpPort || 19999 == staticPort ? 20000 : 19999
        let phpSite = Website(name: "PHP 站点", rootPath: phpRoot.path, port: phpPort, isEnabled: true)
        let staticSite = Website(name: "静态站点", rootPath: staticRoot.path, port: staticPort, isEnabled: true)
        let installation = try WebStackResolver().resolve()
        _ = try WebStackPreparer().prepare(
            installation: installation,
            preferences: preferences,
            layout: layout,
            websites: [phpSite, staticSite]
        )
        var controller: LocalWebStackController? = LocalWebStackController(installation: installation, layout: layout)
        do {
            try await controller!.startWebStack(httpPort: managementPort)
            let php = try await fetch(port: phpPort, path: "/")
            let html = try await fetch(port: staticPort, path: "/")
            let css = try await fetch(port: staticPort, path: "/assets/site.css")
            let env = try await fetch(port: staticPort, path: "/.env")
            let git = try await fetch(port: staticPort, path: "/.git/config")
            guard php.status == 200, php.body.hasPrefix("DYNAMIC-"),
                  html.status == 200, html.body.contains("STATIC-SITE"),
                  css.status == 200, css.body.contains("rgb(1,2,3)"),
                  env.status == 403, git.status == 403 else {
                throw ServiceControlError.healthCheckFailed(
                    "多站点结果：PHP \(php.status)，HTML \(html.status)，CSS \(css.status)，.env \(env.status)，.git/config \(git.status)。"
                )
            }

            // 用与界面**完全相同**的探测逻辑再验一遍分类。必须在这里做——服务正在运行。
            // （第一次我把这段放到了函数末尾，那时服务已停止，探测如实返回
            // connectionFailed，反倒验证了「服务停止 → 连接失败」这条分类是对的。）
            //
            // 针对真实 Apache 检查，而不是只测分类函数：本次改造的核心 bug 就是
            // 「404 被当成运行中」。
            let probe = WebsiteHealthProbe()
            let phpProbe = await probe.probe(phpSite.healthCheckURL)
            let staticProbe = await probe.probe(staticSite.healthCheckURL)
            guard phpProbe.outcome == .ok, staticProbe.outcome == .ok else {
                throw ServiceControlError.healthCheckFailed(
                    "运行中的站点应分类为 ok：PHP 站点 \(phpProbe.outcome)"
                        + "（HTTP \(phpProbe.status.map(String.init) ?? "无响应")，"
                        + "\(phpProbe.errorDomain ?? "-") \(phpProbe.errorCode.map(String.init) ?? "-")），"
                        + "静态站点 \(staticProbe.outcome)"
                        + "（HTTP \(staticProbe.status.map(String.init) ?? "无响应")，"
                        + "\(staticProbe.errorDomain ?? "-") \(staticProbe.errorCode.map(String.init) ?? "-")）。"
                )
            }
            // 不存在的路径必须分类为 notFound。若又变回「运行中」，说明分类退化了。
            guard let missingURL = URL(string: "http://127.0.0.1:\(staticPort)/definitely-not-here") else {
                throw ServiceControlError.healthCheckFailed("无法构造 404 测试地址。")
            }
            let missingProbe = await probe.probe(missingURL)
            guard missingProbe.outcome == .notFound, missingProbe.status == 404 else {
                throw ServiceControlError.healthCheckFailed(
                    "不存在的路径应分类为 notFound(404)，实际 \(missingProbe.outcome)"
                        + "（HTTP \(missingProbe.status.map(String.init) ?? "无响应")）。"
                )
            }
            // 连不上的端口必须分类为 connectionFailed，而不是笼统的「无法访问」。
            //
            // 显式取一个**没有任何监听者**的空闲端口。不能拿后面那个「占用但不 accept」
            // 的端口来测：TCP 握手会成功，结果是超时而不是拒绝连接。
            var probeExcluded = excluded
            guard let freePort = availability.nextAvailable(startingAt: staticPort + 20, excluding: probeExcluded) else {
                throw ServiceControlError.healthCheckFailed("找不到用于连接失败测试的空闲端口。")
            }
            probeExcluded.insert(freePort)
            guard let closedURL = URL(string: "http://127.0.0.1:\(freePort)/") else {
                throw ServiceControlError.healthCheckFailed("无法构造连接失败测试地址。")
            }
            let closedProbe = await probe.probe(closedURL)
            guard closedProbe.outcome == .connectionFailed else {
                throw ServiceControlError.healthCheckFailed(
                    "无监听者的端口应分类为 connectionFailed，实际 \(closedProbe.outcome)"
                        + "（HTTP \(closedProbe.status.map(String.init) ?? "无响应")）。"
                )
            }
            print("健康探测分类通过：运行中的站点 ok、不存在路径 notFound(404)、无监听端口 connectionFailed。")
            try await controller!.stopWebStack()

            _ = try WebStackPreparer().prepare(
                installation: installation,
                preferences: preferences,
                layout: layout,
                websites: [Website(id: phpSite.id, name: phpSite.name, rootPath: phpSite.rootPath, port: phpPort), staticSite]
            )
            controller = LocalWebStackController(installation: installation, layout: layout)
            try await controller!.startWebStack(httpPort: managementPort)
            let stillStatic = try await fetch(port: staticPort, path: "/")
            guard stillStatic.status == 200, stillStatic.body.contains("STATIC-SITE") else {
                throw ServiceControlError.healthCheckFailed("停用 PHP 站点后静态站点不可用。")
            }
            try await controller!.stopWebStack()

            excluded.insert(staticPort)
            guard let conflictPort = availability.nextAvailable(startingAt: staticPort + 1, excluding: excluded) else {
                throw ServiceControlError.healthCheckFailed("找不到端口冲突测试端口。")
            }
            let occupier = try openLoopbackListener(port: conflictPort)
            defer { Darwin.close(occupier) }
            let conflictSite = Website(
                name: "冲突站点",
                rootPath: staticRoot.path,
                port: conflictPort,
                isEnabled: true
            )
            _ = try WebStackPreparer().prepare(
                installation: installation,
                preferences: preferences,
                layout: layout,
                websites: [conflictSite]
            )
            let conflictController = LocalWebStackController(installation: installation, layout: layout)
            var conflictRejected = false
            do { try await conflictController.startWebStack(httpPort: managementPort) }
            catch { conflictRejected = true }
            try? await conflictController.stopWebStack()
            guard conflictRejected, !availability.isAvailable(conflictPort) else {
                throw ServiceControlError.healthCheckFailed("站点端口冲突没有被拒绝，或占用端口的监听器受到了影响。")
            }
            print("双站点检查通过：PHP 动态页、静态 HTML/CSS、独立端口、停用隔离和敏感文件拦截均正常。")

            print("服务重启后站点端口保持：\(phpPort)、\(staticPort)。")
            print("站点端口冲突检查通过：Apache 回滚自己的进程，占用端口的监听器保持运行。")
        } catch {
            if let controller { try? await controller.stopWebStack() }
            throw error
        }
    }

    /// `.htaccess` 与伪静态的端到端验证。
    ///
    /// 这是「MacStack 能否真正替代 XAMPP」的核心回归测试：WordPress 固定链接、
    /// Laravel、ThinkPHP 都依赖 mod_rewrite + AllowOverride。单元测试只能断言生成的
    /// 配置文本，只有真实跑一遍 Apache 才能证明它按预期工作。
    private static func runHtaccessSmokeTest() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("MacStackHtaccessSmoke-\(UUID())", isDirectory: true)
        let siteRoot = root.appendingPathComponent("伪静态站点", isDirectory: true)
        let blockedRoot = root.appendingPathComponent("php_value 站点", isDirectory: true)
        let optionalRoot = root.appendingPathComponent("IndexOptions 站点", isDirectory: true)
        let frameworkRoot = root.appendingPathComponent("框架站点", isDirectory: true)
        let bareOptionsRoot = root.appendingPathComponent("裸 Options 站点", isDirectory: true)
        let shortRuntime = URL(fileURLWithPath: "/tmp/macstack-htaccess-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let layout = RuntimeLayout(root: shortRuntime)
        for directory in [siteRoot, blockedRoot, optionalRoot, frameworkRoot, bareOptionsRoot] {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer {
            try? files.removeItem(at: root)
            try? files.removeItem(at: shortRuntime)
        }

        // 伪静态 fixture：/pretty/<数字> 交给 index.php。
        try Data("""
        RewriteEngine On
        RewriteRule ^pretty/([0-9]+)$ index.php?id=$1 [L,QSA]
        """.utf8).write(to: siteRoot.appendingPathComponent(".htaccess"))
        try Data("<?php header('Content-Type: text/plain'); echo 'REWRITE-OK-' . ($_GET['id'] ?? 'none');".utf8)
            .write(to: siteRoot.appendingPathComponent("index.php"))
        try Data("SECRET".utf8).write(to: siteRoot.appendingPathComponent(".env"))
        try files.createDirectory(at: siteRoot.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
        try Data("SECRET-GIT".utf8).write(to: siteRoot.appendingPathComponent(".git/config"))

        // 顶层 php_value：PHP 走 PHP-FPM，没有 mod_php，站点必然 500，应在准备阶段被拒绝。
        try Data("php_value upload_max_filesize 128M".utf8).write(to: blockedRoot.appendingPathComponent(".htaccess"))
        // IndexOptions 需要 mod_autoindex，默认不加载，应给出提示而不是阻塞。
        try Data("IndexOptions FancyIndexing".utf8).write(to: optionalRoot.appendingPathComponent(".htaccess"))

        // Laravel / Symfony 官方 .htaccess 的写法。
        //
        // 注意其中的 `Options -MultiViews -Indexes` 被包在 `<IfModule mod_negotiation.c>` 里，
        // 而 MacStack 不加载 mod_negotiation —— 整块会被 Apache 跳过，因此不会因为
        // 「未授予 Options 覆盖类」而报错。这个 fixture 验证的是这个真实场景能用。
        try Data("""
        <IfModule mod_rewrite.c>
            <IfModule mod_negotiation.c>
                Options -MultiViews -Indexes
            </IfModule>

            RewriteEngine On
            RewriteCond %{REQUEST_FILENAME} !-d
            RewriteCond %{REQUEST_FILENAME} !-f
            RewriteRule ^ index.php [L]
        </IfModule>
        """.utf8).write(to: frameworkRoot.appendingPathComponent(".htaccess"))
        try Data("<?php header('Content-Type: text/plain'); echo 'FRAMEWORK-OK';".utf8)
            .write(to: frameworkRoot.appendingPathComponent("index.php"))

        // 裸 `Options`（不在会被跳过的 <IfModule> 里）。MacStack 默认不授予 Options
        // 覆盖类，Apache 会报 "not allowed here" 并返回 500，因此预检必须拦下来。
        try Data("Options -MultiViews -Indexes".utf8).write(to: bareOptionsRoot.appendingPathComponent(".htaccess"))

        let availability = PortAvailability()
        var excluded = Set<Int>()
        guard let managementPort = availability.nextAvailable(startingAt: 18180, excluding: excluded) else {
            throw ServiceControlError.healthCheckFailed("找不到测试管理端口。")
        }
        excluded.insert(managementPort)
        guard let sitePort = availability.nextAvailable(startingAt: managementPort + 1, excluding: excluded) else {
            throw ServiceControlError.healthCheckFailed("找不到测试站点端口。")
        }

        var preferences = Preferences()
        preferences.httpPort = managementPort
        preferences.databasePort = (managementPort == 19999 || sitePort == 19999) ? 20001 : 19999
        preferences.allowHtaccess = true
        let site = Website(name: "伪静态站点", rootPath: siteRoot.path, port: sitePort, isEnabled: true)
        let installation = try WebStackResolver().resolve()

        // ── 阶段一：允许 .htaccess 时，伪静态必须真的生效 ──
        let prepared = try WebStackPreparer().prepare(
            installation: installation,
            preferences: preferences,
            layout: layout,
            websites: [site]
        )
        guard prepared.htaccessReport.findings.isEmpty else {
            throw ServiceControlError.healthCheckFailed(
                "干净的 .htaccess 不应产生预检发现：\(prepared.htaccessReport.summary ?? "")"
            )
        }

        var controller: LocalWebStackController? = LocalWebStackController(installation: installation, layout: layout)
        do {
            try await controller!.startWebStack(httpPort: managementPort)
            let pretty = try await fetch(port: sitePort, path: "/pretty/42")
            let unmatched = try await fetch(port: sitePort, path: "/pretty/abc")
            let home = try await fetch(port: sitePort, path: "/")
            let env = try await fetch(port: sitePort, path: "/.env")
            let git = try await fetch(port: sitePort, path: "/.git/config")
            guard pretty.status == 200, pretty.body == "REWRITE-OK-42" else {
                throw ServiceControlError.healthCheckFailed(
                    "伪静态未生效：/pretty/42 返回 HTTP \(pretty.status)，正文 \(pretty.body)。"
                        + "说明 .htaccess 的 RewriteRule 没有被执行。"
                )
            }
            // 对照组：不匹配规则的路径应 404，证明上面是真的走了重写而不是兜底路由。
            guard unmatched.status == 404 else {
                throw ServiceControlError.healthCheckFailed("未匹配的路径应返回 404，实际 \(unmatched.status)。")
            }
            guard home.status == 200, env.status == 403, git.status == 403 else {
                throw ServiceControlError.healthCheckFailed(
                    "首页 \(home.status)，.env \(env.status)，.git/config \(git.status)；后两者应为 403。"
                )
            }
            try await controller!.stopWebStack()

            // ── 阶段二：关闭 .htaccess 支持后，同一份配置应不再生效 ──
            var closed = preferences
            closed.allowHtaccess = false
            _ = try WebStackPreparer().prepare(
                installation: installation,
                preferences: closed,
                layout: layout,
                websites: [site]
            )
            controller = LocalWebStackController(installation: installation, layout: layout)
            try await controller!.startWebStack(httpPort: managementPort)
            let disabled = try await fetch(port: sitePort, path: "/pretty/42")
            guard disabled.status == 404 else {
                throw ServiceControlError.healthCheckFailed(
                    "关闭 .htaccess 支持后 /pretty/42 应返回 404，实际 \(disabled.status)；说明开关没有生效。"
                )
            }
            try await controller!.stopWebStack()
            controller = nil

            // ── 阶段三：顶层 php_value 必须在准备阶段被拒绝 ──
            let blockedSite = Website(name: "php_value 站点", rootPath: blockedRoot.path, port: sitePort, isEnabled: true)
            var blockedRejected = false
            do {
                _ = try WebStackPreparer().prepare(
                    installation: installation,
                    preferences: preferences,
                    layout: layout,
                    websites: [blockedSite]
                )
            } catch { blockedRejected = true }
            guard blockedRejected else {
                throw ServiceControlError.healthCheckFailed(
                    "顶层 php_value 会导致站点返回 500，准备阶段应拒绝，但实际通过了。"
                )
            }

            // ── 阶段四：缺模块的指令应给出提示，开启模块后消失 ──
            let optionalSite = Website(name: "IndexOptions 站点", rootPath: optionalRoot.path, port: sitePort, isEnabled: true)
            let warned = try WebStackPreparer().prepare(
                installation: installation,
                preferences: preferences,
                layout: layout,
                websites: [optionalSite]
            )
            guard let summary = warned.htaccessReport.summary, summary.contains("autoindex") else {
                throw ServiceControlError.healthCheckFailed("IndexOptions 应提示需要 autoindex 模块，实际没有提示。")
            }
            var withAutoindex = preferences
            withAutoindex.optionalApacheModules = ["autoindex"]
            let resolved = try WebStackPreparer().prepare(
                installation: installation,
                preferences: withAutoindex,
                layout: layout,
                websites: [optionalSite]
            )
            guard resolved.htaccessReport.findings.isEmpty else {
                throw ServiceControlError.healthCheckFailed(
                    "开启 autoindex 后不应再有预检发现：\(resolved.htaccessReport.summary ?? "")"
                )
            }

            // ── 阶段五：真实框架的 .htaccess 写法必须能用 ──
            //
            // Laravel / Symfony 的官方 .htaccess 会在 <IfModule mod_rewrite.c> 里写
            // `Options -MultiViews -Indexes`。MacStack 的 AllowOverride 刻意不含
            // Options 类（为了保住 -FollowSymLinks 加固），如果 Apache 因此拒绝该指令，
            // 标准框架项目就会直接 500 —— 而这正是「替代 XAMPP」要支持的主要场景。
            let frameworkSite = Website(name: "框架站点", rootPath: frameworkRoot.path, port: sitePort, isEnabled: true)
            let frameworkPrepared = try WebStackPreparer().prepare(
                installation: installation,
                preferences: preferences,
                layout: layout,
                websites: [frameworkSite]
            )
            controller = LocalWebStackController(installation: installation, layout: layout)
            try await controller!.startWebStack(httpPort: managementPort)
            let framework = try await fetch(port: sitePort, path: "/")
            try await controller!.stopWebStack()
            controller = nil
            guard framework.status == 200, framework.body == "FRAMEWORK-OK" else {
                throw ServiceControlError.healthCheckFailed(
                    "Laravel / Symfony 风格的 .htaccess 让站点返回 HTTP \(framework.status)（应为 200）。\n"
                    + "预检结果：\(frameworkPrepared.htaccessReport.summary ?? "（无发现）")"
                )
            }

            // ── 阶段六：裸 Options 必须被拦下；开启覆盖后应当放行 ──
            let bareSite = Website(name: "裸 Options 站点", rootPath: bareOptionsRoot.path, port: sitePort, isEnabled: true)
            var bareRejected = false
            do {
                _ = try WebStackPreparer().prepare(
                    installation: installation,
                    preferences: preferences,
                    layout: layout,
                    websites: [bareSite]
                )
            } catch { bareRejected = true }
            guard bareRejected else {
                throw ServiceControlError.healthCheckFailed(
                    "裸 Options 会让站点返回 HTTP 500（实测确认），准备阶段应拒绝，但实际通过了。"
                )
            }
            // 用户显式开启 Options 覆盖后应当放行。
            var optionsOpen = preferences
            optionsOpen.allowHtaccessOptions = true
            _ = try WebStackPreparer().prepare(
                installation: installation,
                preferences: optionsOpen,
                layout: layout,
                websites: [bareSite]
            )

            print("伪静态检查通过：/pretty/42 → HTTP 200 且内容为 REWRITE-OK-42（mod_rewrite + AllowOverride 生效）。")
            print("对照组通过：不匹配规则的 /pretty/abc 返回 404。")
            print("敏感文件拦截通过：.env 与 .git/config 均返回 403。")
            print("开关检查通过：关闭 .htaccess 支持后 /pretty/42 返回 404。")
            print("php_value 检查通过：顶层 php_value 在准备阶段被拒绝，不会生成必然 500 的配置。")
            print("可选模块检查通过：IndexOptions 在未加载 autoindex 时给出提示，开启后提示消失。")
            print("框架兼容检查通过：Laravel / Symfony 风格的 .htaccess（含 Options -MultiViews）返回 HTTP 200。")
            print("覆盖类检查通过：裸 Options 在准备阶段被拒绝（实测会让站点 500），开启 Options 覆盖后放行。")
        } catch {
            if let controller { try? await controller.stopWebStack() }
            throw error
        }
    }

    /// 真实 HTTP 探测的验收入口。
    ///
    /// 执行与界面**完全相同**的探测逻辑（`WebsiteHealthProbe`），并打印请求地址、
    /// HTTP 状态、`Location`、系统错误域与错误码。这样任何一次「界面显示不对」的怀疑，
    /// 都能先用一条命令复现，而不是靠截图猜。
    ///
    /// **注意**：App Transport Security 的例外只对 app bundle 生效，CLI 进程读的是
    /// 自己的 Info.plist。因此这条命令验证的是**探测逻辑与状态分类**；
    /// 「ATS 是否真的放行」必须在安装后的应用里确认，不能由这条命令代替。
    private static func runHealthProbe(_ arguments: [String]) async throws {
        var port: Int?
        var host: String?
        var path = "/"
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--port":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]) else {
                    throw ServiceControlError.healthCheckFailed("--port 需要一个端口号。")
                }
                port = value
            case "--host":
                index += 1
                guard index < arguments.count else {
                    throw ServiceControlError.healthCheckFailed("--host 需要一个域名。")
                }
                host = arguments[index]
            case "--path":
                index += 1
                guard index < arguments.count else {
                    throw ServiceControlError.healthCheckFailed("--path 需要一个路径。")
                }
                path = arguments[index]
            default:
                throw ServiceControlError.healthCheckFailed("无法识别的参数：\(arguments[index])")
            }
            index += 1
        }

        var targets: [(label: String, url: URL)] = []
        if let port {
            // 用真实域名而不是 127.0.0.1：Host 必须与浏览器访问时一致。
            let hostname = (host?.isEmpty == false) ? host! : "127.0.0.1"
            let normalizedPath = path.hasPrefix("/") ? path : "/" + path
            guard let url = URL(string: "http://\(hostname):\(port)\(normalizedPath)") else {
                throw ServiceControlError.healthCheckFailed("无法构造请求地址。")
            }
            targets.append((hostname, url))
        } else {
            let settings = try SettingsStore().load()
            let enabled = settings.websites.filter(\.isEnabled)
            guard !enabled.isEmpty else {
                print("设置里没有已启用的网站。用 --port 指定一个地址，或先在应用里登记网站。")
                return
            }
            for website in enabled {
                targets.append((website.name, website.healthCheckURL))
            }
        }

        let probe = WebsiteHealthProbe()
        var failures = 0
        for target in targets {
            let result = await probe.probe(target.url)
            print(describeProbe(label: target.label, result: result))
            if result.outcome.isFailure { failures += 1 }
        }
        if targets.count > 1 {
            print("\n共 \(targets.count) 个站点，\(failures) 个需要关注。")
        }
    }

    private static func describeProbe(label: String, result: WebsiteHealthResult) -> String {
        var lines: [String] = []
        lines.append("[\(label)]")
        lines.append("  请求地址：\(result.requestURL)")
        lines.append("  HTTP 状态：\(result.status.map(String.init) ?? "（无响应）")")
        if let location = result.location {
            lines.append("  Location：\(location)")
        }
        lines.append("  分类：\(describeOutcome(result.outcome))")
        if let detail = result.detail {
            lines.append("  说明：\(detail)")
        }
        if let domain = result.errorDomain, let code = result.errorCode {
            lines.append("  系统错误：\(domain) \(code)")
        }
        if result.detectedRedirectLoop {
            lines.append("  ⚠️ 检测到跳转循环")
        }
        if result.skippedExternalRedirect {
            lines.append("  ⚠️ 跳转目标是外部地址，未跟随")
        }
        if let followedStatus = result.followedStatus, let followedURL = result.followedURL {
            lines.append("  跟随本地跳转后：HTTP \(followedStatus) @ \(followedURL)")
        }
        return lines.joined(separator: "\n")
    }

    private static func describeOutcome(_ outcome: WebsiteHealthOutcome) -> String {
        switch outcome {
        case .ok: "正常"
        case .redirect: "发生跳转"
        case .unauthorized: "需要认证"
        case .forbidden: "访问被拒绝（服务已响应）"
        case .notFound: "找不到页面"
        case .serverError: "服务器错误"
        case .clientError: "请求被拒绝"
        case .unexpectedStatus: "未预期的状态码"
        case .timedOut: "超时"
        case .connectionFailed: "连接失败"
        case .transportBlocked: "被传输安全策略拦截"
        case .tlsFailure: "TLS 失败"
        }
    }

    private static func fetch(port: Int, path: String) async throws -> (status: Int, body: String) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.timeoutInterval = 3
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }

    private static func openLoopbackListener(port: Int) throws -> Int32 {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(descriptor, 1) == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(.EADDRINUSE)
        }
        return descriptor
    }
}

/// 只触发一次的标志。
///
/// `DatabaseRestoreJob.restore` 的进度回调是 `@Sendable`，不能直接改捕获的局部变量，
/// 所以用一个带锁的引用类型来记录「取消是否已经触发过」。
private final class OneShotFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    /// 第一次调用返回 true，之后返回 false。
    func fire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }

    var hasFired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fired
    }
}
