import Foundation
import Darwin
import MacStackCore

@main
struct MacStackCLI {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard let command = arguments.first,
                  ["prepare", "smoke-test", "prepare-database", "database-smoke-test", "database-backup-smoke-test", "prepare-phpmyadmin", "full-smoke-test", "audit-xampp", "sites-smoke-test", "htaccess-smoke-test"].contains(command) else {
                print("用法：macstackctl prepare [网站目录]\n      macstackctl smoke-test\n      macstackctl sites-smoke-test\n      macstackctl htaccess-smoke-test\n      macstackctl prepare-database\n      macstackctl database-smoke-test\n      macstackctl database-backup-smoke-test\n      macstackctl prepare-phpmyadmin\n      macstackctl full-smoke-test\n      macstackctl audit-xampp [XAMPP目录]")
                exit(arguments.isEmpty ? 0 : 64)
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
            FileHandle.standardError.write(Data("MacStack：\(error.localizedDescription)\n".utf8))
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
