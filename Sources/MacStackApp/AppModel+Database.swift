import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacStackCore
extension AppModel {
    func preparePHPMyAdmin() async {
        guard !preparingPHPMyAdmin, !webServicesRunning, !serviceOperationsBlocked else { return }
        preparingPHPMyAdmin = true
        let databasePort = settings.preferences.databasePort
        do {
            let prepared = try await Task.detached {
                try PHPMyAdminPreparer().prepare(
                    installation: PHPMyAdminResolver().resolve(),
                    databasePort: databasePort
                )
            }.value
            phpMyAdminPrepared = true
            phpMyAdminStatus = "phpMyAdmin \(prepared.version) 已准备。\n数据库密码未写入配置，使用 cookie 登录。"
            record("phpMyAdmin 独立副本与 cookie 登录配置已准备。")
            await prepareWebEnvironment()
        } catch {
            message = error.localizedDescription
            phpMyAdminStatus = "准备失败：\(error.localizedDescription)"
        }
        preparingPHPMyAdmin = false
    }

    func openPHPMyAdmin() {
        guard phpMyAdminPrepared, webServicesRunning, databaseRunning else {
            message = "请先准备 phpMyAdmin，并启动 Web 环境和数据库。"
            return
        }
        NSWorkspace.shared.open(URL(string: "http://127.0.0.1:\(settings.preferences.httpPort)/phpmyadmin/")!)
    }

    func copyDatabasePassword() async {
        do {
            let credentials: DatabaseCredentials
            if let databaseCredentials {
                credentials = databaseCredentials
            } else {
                credentials = try await Task.detached { try DatabaseCredentialStore().loadOrCreate() }.value
                databaseCredentials = credentials
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(credentials.password, forType: .string)
            record("数据库密码已复制到剪贴板，将在 60 秒后清除。用户名为 macstack。")
            let copied = credentials.password
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(60))
                if NSPasteboard.general.string(forType: .string) == copied {
                    NSPasteboard.general.clearContents()
                    self.record("数据库密码已从剪贴板清除。")
                }
            }
        } catch {
            message = error.localizedDescription
        }
    }

    func createDatabase(named rawName: String) async -> Bool {
        do {
            let name = try PHPProjectCreator().validateDatabaseName(rawName)
            if !databaseRunning { await startDatabase() }
            guard databaseRunning else { return false }
            let layout = RuntimeLayout.applicationSupport()
            try await Task.detached {
                let installation = try DatabaseStackResolver().resolve()
                try DatabaseBackupManager(installation: installation, layout: layout).createDatabase(named: name)
            }.value
            await refreshDatabases()
            selectedDatabase = name
            databaseBackupStatus = "数据库 \(name) 已创建，字符集为 utf8mb4。"
            record("已创建数据库 \(name)。")
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    func copyPDOConnectionTemplate() {
        guard !selectedDatabase.isEmpty else {
            message = "请先选择一个业务数据库。"
            return
        }
        let template = PHPProjectCreator.pdoTemplate(
            databaseName: selectedDatabase,
            databasePort: settings.preferences.databasePort
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(template, forType: .string)
        record("已复制 \(selectedDatabase) 的 PDO 连接模板；模板不包含钥匙串密码。")
    }

    func createPHPProject(name: String, parentPath: String, databaseName: String?, createDatabase: Bool) async -> Bool {
        guard !creatingProject, canSave else { return false }
        creatingProject = true
        defer { creatingProject = false }
        let creator = PHPProjectCreator()
        var created: CreatedPHPProject?
        var createdDatabase = false
        var safeDatabase: String?
        do {
            _ = try creator.validateProjectName(name)
            if createDatabase {
                let requested = databaseName ?? ""
                safeDatabase = try creator.validateDatabaseName(requested)
                if !databaseRunning { await startDatabase() }
                guard databaseRunning else { return false }
                let layout = RuntimeLayout.applicationSupport()
                let database = safeDatabase!
                createdDatabase = try await Task.detached {
                    let installation = try DatabaseStackResolver().resolve()
                    let manager = DatabaseBackupManager(installation: installation, layout: layout)
                    let existed = try manager.listDatabases().contains(database)
                    try manager.createDatabase(named: database)
                    return !existed
                }.value
            }

            let parent = URL(fileURLWithPath: parentPath, isDirectory: true)
            if parent.standardizedFileURL == RuntimeLayout.applicationSupport().documentRoot.standardizedFileURL {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            }
            let databasePort = settings.preferences.databasePort
            let databaseForProject = safeDatabase
            created = try await Task.detached {
                try creator.create(
                    named: name,
                    in: parent,
                    databaseName: databaseForProject,
                    databasePort: databasePort
                )
            }.value
            guard let created else { throw ProjectCreationError.registrationFailed }
            let reserved = Set(settings.websites.map(\.port) + [settings.preferences.httpPort, settings.preferences.databasePort, settings.preferences.httpsPort])
            guard let port = PortAvailability().nextAvailable(startingAt: 8081, excluding: reserved) else {
                throw SettingsError.invalidWebsitePort(name)
            }
            var next = settings
            try next.addWebsite(at: created.root, publicRoot: created.publicRoot, port: port)
            guard let id = next.websites.last?.id else { throw ProjectCreationError.registrationFailed }
            next.websites[next.websites.count - 1].isEnabled = true
            next.websites[next.websites.count - 1].hostname = LocalHostname.suggested(from: name)
            await applyWebsiteSettings(next, action: "已创建并登记 PHP 项目 \(name)，端口 \(port)。", changingID: id)
            guard settings.websites.contains(where: { $0.rootPath == created.root.path }) else {
                throw ProjectCreationError.registrationFailed
            }
            if databaseRunning { await refreshDatabases() }
            NSWorkspace.shared.open(created.root)
            record("PHP 项目已创建：\(created.root.path)。")
            return true
        } catch {
            if let created { try? FileManager.default.removeItem(at: created.root) }
            if createdDatabase, let safeDatabase {
                let layout = RuntimeLayout.applicationSupport()
                try? await Task.detached {
                    let installation = try DatabaseStackResolver().resolve()
                    try DatabaseBackupManager(installation: installation, layout: layout).dropDatabase(named: safeDatabase)
                }.value
            }
            message = error.localizedDescription
            return false
        }
    }

}
