import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacStackCore
extension AppModel {
    func refreshDatabases() async {
        guard databaseRunning else {
            message = "请先启动数据库。"
            return
        }
        do {
            let layout = RuntimeLayout.applicationSupport()
            let list = try await Task.detached {
                let installation = try DatabaseStackResolver().resolve()
                return try DatabaseBackupManager(installation: installation, layout: layout).listDatabases()
            }.value
            databases = list
            if !list.contains(selectedDatabase) { selectedDatabase = list.first ?? "" }
            databaseBackupStatus = list.isEmpty ? "当前没有业务数据库。" : "发现 \(list.count) 个业务数据库。"
        } catch {
            message = error.localizedDescription
            databaseBackupStatus = "读取数据库列表失败：\(error.localizedDescription)"
        }
    }

    func exportSelectedDatabase() async {
        guard databaseRunning, !selectedDatabase.isEmpty else {
            message = "请先启动数据库并选择要导出的数据库。"
            return
        }
        let panel = NSSavePanel()
        panel.title = "导出数据库 SQL"
        let date = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        panel.nameFieldStringValue = "\(selectedDatabase)-\(date).sql"
        panel.allowedContentTypes = [UTType(filenameExtension: "sql")!]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        backingUpDatabase = true
        let database = selectedDatabase
        let layout = RuntimeLayout.applicationSupport()
        do {
            try await Task.detached {
                let installation = try DatabaseStackResolver().resolve()
                try DatabaseBackupManager(installation: installation, layout: layout)
                    .exportDatabase(named: database, to: destination)
            }.value
            backupRecords = try backupCatalog.register(database: database, file: destination, automatic: false)
            databaseBackupStatus = "已导出 \(database)：\(destination.path)"
            record("数据库 \(database) 已完整导出为 SQL。")
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch {
            message = error.localizedDescription
            databaseBackupStatus = "导出失败：\(error.localizedDescription)"
        }
        backingUpDatabase = false
    }

    func restoreDatabaseBackup() async {
        guard !serviceOperationsBlocked else {
            message = "正在保存预设，请完成后再恢复备份。"
            return
        }
        guard databaseRunning else {
            message = "请先启动数据库。"
            return
        }
        let panel = NSOpenPanel()
        panel.title = "选择 MariaDB SQL 备份"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "sql")!]
        guard panel.runModal() == .OK, let source = panel.url else { return }

        let layout = RuntimeLayout.applicationSupport()
        do {
            let installation = try await Task.detached { try DatabaseStackResolver().resolve() }.value
            let job = DatabaseRestoreJob(installation: installation, layout: layout)
            let plan = try job.prepare(source: source)
            let size = ByteCountFormatter.string(fromByteCount: plan.sourceBytes, countStyle: .file)
            let free = plan.availableBytes > 0
                ? ByteCountFormatter.string(fromByteCount: plan.availableBytes, countStyle: .file)
                : "未知"
            let alert = NSAlert()
            alert.messageText = "恢复这个 SQL 备份？"
            alert.informativeText = "文件大小：\(size)；可用空间：\(free)。\n\nSQL 中的建库、删表和写入语句会在 MacStack 数据库中执行。请确认备份来源可信。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "恢复")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            restoringDatabase = true
            restoreProgress = 0
            restoreJob = job
            try await Task.detached {
                try job.restore(plan: plan) { completed, total in
                    let value = total > 0 ? Double(completed) / Double(total) : 0
                    Task { @MainActor in self.restoreProgress = value }
                }
            }.value
            databaseBackupStatus = "恢复完成：\(source.path)"
            record("SQL 备份已恢复：\(source.lastPathComponent)。")
            await refreshDatabases()
        } catch {
            if case DatabaseBackupError.restoreCancelled = error {
                databaseBackupStatus = "恢复已取消；数据库可能包含取消前已经执行的语句，请检查后再继续。"
            } else {
                message = error.localizedDescription
                databaseBackupStatus = "恢复失败：\(error.localizedDescription)"
            }
        }
        restoreJob = nil
        restoringDatabase = false
    }

    func cancelDatabaseRestore() {
        restoreJob?.cancel()
    }

    func openBackupDirectory() {
        do {
            try FileManager.default.createDirectory(at: backupCatalog.directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(backupCatalog.directory)
        } catch { message = error.localizedDescription }
    }

    func revealBackup(_ record: BackupRecord) {
        let url = URL(fileURLWithPath: record.filePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            message = "备份文件已经移动或删除：\(url.path)"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func runAutomaticBackupNow(force: Bool = true) async {
        // 保存预设期间跳过，调度器 60 秒后会重试。
        guard !serviceOperationsBlocked else { return }
        guard databaseRunning, !backingUpDatabase, !restoringDatabase else {
            automaticBackupStatus = "数据库未运行或另一个备份任务正在进行。"
            return
        }
        let interval = TimeInterval(settings.preferences.backupIntervalHours * 3600)
        let retentionDays = settings.preferences.backupRetentionDays
        let layout = RuntimeLayout.applicationSupport()
        let catalog = backupCatalog

        backingUpDatabase = true
        defer { backingUpDatabase = false }
        do {
            let result = try await Task.detached { () -> (records: [BackupRecord], backedUp: Int, skipped: Int, removed: Int) in
                let installation = try DatabaseStackResolver().resolve()
                let manager = DatabaseBackupManager(installation: installation, layout: layout)
                let databases = try manager.listDatabases()
                var latest = catalog.load()
                var backedUp = 0
                var skipped = 0
                for database in databases {
                    // 按库判断间隔：新登记的业务库不该等满一整个周期才首次备份。
                    if !force,
                       let last = catalog.lastAutomaticBackupDate(database: database),
                       Date().timeIntervalSince(last) < interval {
                        skipped += 1
                        continue
                    }
                    let destination = try catalog.destination(database: database)
                    try manager.exportDatabase(named: database, to: destination)
                    latest = try catalog.register(database: database, file: destination, automatic: true)
                    backedUp += 1
                }
                let removed = catalog.pruneAutomaticBackups(olderThanDays: retentionDays)
                if removed > 0 { latest = catalog.load() }
                return (latest, backedUp, skipped, removed)
            }.value
            backupRecords = result.records
            // 用任务返回的计数，而不是界面上可能过期的 databases 列表。
            var summary = "自动备份完成：\(result.backedUp) 个业务库已导出。"
            if result.skipped > 0 { summary += "\(result.skipped) 个尚未到备份时间。" }
            if result.removed > 0 { summary += "已清理 \(result.removed) 个过期自动备份。" }
            automaticBackupStatus = summary
            record("自动数据库备份完成。")
        } catch {
            automaticBackupStatus = "自动备份失败：\(error.localizedDescription)"
        }
    }

}
