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

    /// 刷新保留策略预演。
    ///
    /// 与真正的清理共用 `pruneSelection`，因此「预览说会删几份」和「实际删几份」
    /// 不会出现分歧——分歧比没有预览更糟，用户会基于错误信息做决定。
    func refreshBackupPrunePreview() async {
        let catalog = backupCatalog
        let days = settings.preferences.backupRetentionDays
        backupPrunePreview = await catalog.prunePreview(olderThanDays: days)
    }

    /// 立即按当前保留策略清理一次自动备份。
    ///
    /// 需要这个入口是因为：自动备份被关闭时清理不会自动跑，而预览会一直显示
    /// 「有 N 份可清理」却没有办法执行。
    func pruneBackupsNow() async {
        guard !backingUpDatabase else {
            message = "已有备份任务在进行，请稍后再试。"
            return
        }
        let catalog = backupCatalog
        let days = settings.preferences.backupRetentionDays
        let removed = await catalog.pruneAutomaticBackups(olderThanDays: days)
        backupRecords = await catalog.load()
        await refreshBackupPrunePreview()
        databaseBackupStatus = removed > 0
            ? "已按保留策略清理 \(removed) 份自动备份。"
            : "没有需要清理的自动备份。"
        if removed > 0 { record("已清理 \(removed) 份过期自动备份。") }
    }

    /// 开始一个备份任务。用计数而不是布尔，见 `activeBackupJobs` 的说明。
    func beginBackupJob() {
        activeBackupJobs += 1
        backingUpDatabase = true
    }

    /// 结束一个备份任务。只有最后一个任务结束才把界面标志置回 false。
    func endBackupJob() {
        activeBackupJobs = max(0, activeBackupJobs - 1)
        backingUpDatabase = activeBackupJobs > 0
    }

    /// 恢复之前给现有业务库各做一份快照。
    ///
    /// 快照登记为**手动备份**（`automatic: false`），因此不会被保留策略清理 ——
    /// 恢复出错时它是唯一的退路。同时标记 `preRestoreSnapshot`，界面上单独说明来源。
    ///
    /// - Returns: 生成的快照数量。一个业务库都没有（全新环境）时返回 0，不阻塞恢复。
    private func createPreRestoreSnapshots(
        layout: RuntimeLayout,
        installation: InstalledDatabaseStack
    ) async throws -> Int {
        let catalog = backupCatalog
        return try await Task.detached { () -> Int in
            let manager = DatabaseBackupManager(installation: installation, layout: layout)
            let databases = try manager.listDatabases()
            var created = 0
            for database in databases {
                let destination = try await catalog.destination(database: database)
                try manager.exportDatabase(named: database, to: destination)
                _ = try await catalog.register(
                    database: database,
                    file: destination,
                    automatic: false,
                    preRestoreSnapshot: true
                )
                created += 1
            }
            return created
        }.value
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
        beginBackupJob()
        defer { endBackupJob() }
        let database = selectedDatabase
        let layout = RuntimeLayout.applicationSupport()
        do {
            try await Task.detached {
                let installation = try DatabaseStackResolver().resolve()
                try DatabaseBackupManager(installation: installation, layout: layout)
                    .exportDatabase(named: database, to: destination)
            }.value
            backupRecords = try await backupCatalog.register(database: database, file: destination, automatic: false)
            databaseBackupStatus = "已导出 \(database)：\(destination.path)"
            record("数据库 \(database) 已完整导出为 SQL。")
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch {
            message = error.localizedDescription
            databaseBackupStatus = "导出失败：\(error.localizedDescription)"
        }
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
        // 在 do 之外声明：catch 里也要用它说明「这次有没有退路」。
        var snapshotNote = ""
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

            // 恢复是破坏性操作：SQL 里的建库/删表语句会直接覆盖现有数据，选错文件就回不去。
            // 因此在真正执行之前，先给现有业务库各做一份快照。
            do {
                let count = try await createPreRestoreSnapshots(layout: layout, installation: installation)
                snapshotNote = count > 0
                    ? "已在恢复前为 \(count) 个现有数据库各生成一份快照。"
                    : "当前没有需要快照的业务库。"
            } catch {
                let failure = NSAlert()
                failure.messageText = "恢复前快照失败"
                failure.informativeText = """
                \(error.localizedDescription)

                没有快照就恢复，一旦选错文件将无法回退。仍要继续吗？
                """
                failure.alertStyle = .critical
                failure.addButton(withTitle: "仍然恢复")
                failure.addButton(withTitle: "取消")
                guard failure.runModal() == .alertFirstButtonReturn else { return }
                snapshotNote = "恢复前快照失败，已按你的选择继续（本次没有退路）。"
            }

            restoringDatabase = true
            restoreProgress = 0
            restoreJob = job
            try await Task.detached {
                try job.restore(plan: plan) { completed, total in
                    let value = total > 0 ? Double(completed) / Double(total) : 0
                    Task { @MainActor in self.restoreProgress = value }
                }
            }.value
            databaseBackupStatus = "恢复完成：\(source.path)　\(snapshotNote)"
            record("SQL 备份已恢复：\(source.lastPathComponent)。")
            await refreshDatabases()
        } catch {
            // 取消和中途失败都会留下「可能只执行了一部分语句」的数据库状态。
            // 这不能只用一行状态文字带过 —— 用户需要知道现在处于什么状态、该做什么。
            var cancelled = false
            if case DatabaseBackupError.restoreCancelled = error { cancelled = true }
            let headline = cancelled ? "恢复已取消" : "恢复中断"

            databaseBackupStatus = "\(headline)；数据库可能处于半恢复状态。"
            record("SQL 恢复\(cancelled ? "被取消" : "失败")：\(source.lastPathComponent)。")

            let alert = NSAlert()
            alert.messageText = headline
            alert.informativeText = """
            \(cancelled ? "" : "\(error.localizedDescription)\n\n")\
            数据库可能只执行了一部分语句，处于半恢复状态：有些表已经重建，有些还是旧的。

            \(snapshotNote)

            建议：重新完整恢复一次这个文件，或用上面的恢复前快照回退。
            """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "打开备份文件夹")
            alert.addButton(withTitle: "稍后处理")
            if alert.runModal() == .alertFirstButtonReturn {
                openBackupDirectory()
            }
            await refreshDatabases()
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

        beginBackupJob()
        defer { endBackupJob() }
        do {
            let result = try await Task.detached { () -> (records: [BackupRecord], backedUp: Int, skipped: Int, removed: Int) in
                let installation = try DatabaseStackResolver().resolve()
                let manager = DatabaseBackupManager(installation: installation, layout: layout)
                let databases = try manager.listDatabases()
                var latest = await catalog.load()
                var backedUp = 0
                var skipped = 0
                for database in databases {
                    // 按库判断间隔：新登记的业务库不该等满一整个周期才首次备份。
                    if !force,
                       let last = await catalog.lastAutomaticBackupDate(database: database),
                       Date().timeIntervalSince(last) < interval {
                        skipped += 1
                        continue
                    }
                    let destination = try await catalog.destination(database: database)
                    try manager.exportDatabase(named: database, to: destination)
                    latest = try await catalog.register(database: database, file: destination, automatic: true)
                    backedUp += 1
                }
                let removed = await catalog.pruneAutomaticBackups(olderThanDays: retentionDays)
                if removed > 0 { latest = await catalog.load() }
                return (latest, backedUp, skipped, removed)
            }.value
            backupRecords = result.records
            await refreshBackupPrunePreview()
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
