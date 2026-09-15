import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacStackCore
extension AppModel {
    func rotateLogsNow() {
        guard !webServicesRunning, !databaseRunning else {
            message = "请先停止全部服务，再整理日志。"
            return
        }
        do {
            let result = try LogMaintainer().rotate(directory: RuntimeLayout.applicationSupport().logDirectory)
            record("日志整理完成：轮转 \(result.rotated) 个，移除 \(result.removed) 个最旧副本。")
            if result.rotated == 0 { message = "日志目前都小于 5 MB，不需要轮转。" }
        } catch { message = error.localizedDescription }
    }

    func auditXAMPP() async {
        guard !auditingXAMPP else { return }
        auditingXAMPP = true
        do {
            let result = try await Task.detached {
                let auditor = XAMPPAuditor()
                let report = try auditor.audit()
                let url = try auditor.writeReport(report)
                return (report, url)
            }.value
            let report = result.0
            xamppAuditReportPath = result.1.path
            xamppSites = report.sites
            let size = ByteCountFormatter.string(fromByteCount: report.totalByteCount, countStyle: .file)
            xamppAuditStatus = "只读盘点完成：可统计 \(size)\n网站候选 \(report.sites.count) 个，可能的业务数据库 \(report.businessDatabases.count) 个。\n没有执行复制、导出、导入或删除。"
            record("旧 XAMPP 只读盘点完成；未执行迁移或修改。")
        } catch {
            message = error.localizedDescription
            xamppAuditStatus = "盘点失败：\(error.localizedDescription)"
        }
        auditingXAMPP = false
    }

    func revealXAMPPAuditReport() {
        guard let xamppAuditReportPath else {
            message = "请先生成只读盘点报告。"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: xamppAuditReportPath)])
    }

    func migrateWebsiteCopy(_ site: XAMPPSiteAudit) async {
        guard migratingSite == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "选择迁移副本的上级目录"
        panel.prompt = "选择"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let destinationParent = panel.url else { return }

        migratingSite = site.name
        do {
            let source = URL(fileURLWithPath: site.path, isDirectory: true)
            let plan = try await Task.detached {
                try WebsiteMigrator().prepare(source: source, destinationParent: destinationParent)
            }.value
            let size = ByteCountFormatter.string(fromByteCount: plan.totalByteCount, countStyle: .file)
            let alert = NSAlert()
            alert.messageText = "确认创建网站迁移副本？"
            alert.informativeText = "源目录不会被修改或删除。\n\n源：\(plan.source.path)\n目标：\(plan.destination.path)\n文件：\(plan.fileCount) 个，\(size)\n\n复制后会逐文件验证 SHA-256；目标已存在时绝不覆盖。"
            alert.addButton(withTitle: "复制并验证")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else {
                websiteMigrationStatus = "已取消；没有复制任何文件。"
                migratingSite = nil
                return
            }
            let result = try await Task.detached { try WebsiteMigrator().migrate(plan) }.value
            let resultSize = ByteCountFormatter.string(fromByteCount: result.byteCount, countStyle: .file)
            websiteMigrationStatus = "迁移副本已验证：\(result.destination.path)\n\(result.fileCount) 个文件，\(resultSize)。原网站保持不变。"
            record("网站 \(site.name) 的迁移副本已创建并通过 SHA-256 校验；原网站未改动。")
            NSWorkspace.shared.activateFileViewerSelecting([result.destination])
        } catch {
            message = error.localizedDescription
            websiteMigrationStatus = "迁移未完成：\(error.localizedDescription)"
        }
        migratingSite = nil
    }

    func listLegacyDatabases(credentials: LegacyDatabaseCredentials) async -> Bool {
        guard !checkingLegacyDatabase else { return false }
        guard credentials.port != settings.preferences.databasePort else {
            message = "旧数据库端口不能与 MacStack 数据库端口相同。"
            return false
        }
        checkingLegacyDatabase = true
        defer { checkingLegacyDatabase = false }
        do {
            let list = try await Task.detached {
                let installation = try DatabaseStackResolver().resolve()
                return try LegacyDatabaseConnector(installation: installation).listDatabases(credentials: credentials)
            }.value
            legacyDatabases = list
            legacyDatabaseStatus = list.isEmpty ? "已连接，但没有发现业务数据库。" : "已连接，发现 \(list.count) 个业务数据库；尚未复制。"
            return true
        } catch {
            message = error.localizedDescription
            legacyDatabaseStatus = "连接失败：\(error.localizedDescription)"
            return false
        }
    }

    func migrateLegacyDatabase(named database: String, credentials: LegacyDatabaseCredentials) async -> Bool {
        guard migratingLegacyDatabase == nil else { return false }
        let alert = NSAlert()
        alert.messageText = "把旧数据库 \(database) 复制到 MacStack？"
        alert.informativeText = "源数据库只会被读取，不会删除或修改。MacStack 会先创建临时逻辑 SQL，再导入自己的 MariaDB；若同名库已存在，SQL 可能更新其中的数据。"
        alert.addButton(withTitle: "导出并导入")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        migratingLegacyDatabase = database
        restoreProgress = 0
        let dump = FileManager.default.temporaryDirectory.appendingPathComponent("macstack-xampp-\(UUID().uuidString).sql")
        defer {
            try? FileManager.default.removeItem(at: dump)
            migratingLegacyDatabase = nil
            restoreJob = nil
        }
        do {
            let installation = try await Task.detached { try DatabaseStackResolver().resolve() }.value
            try await Task.detached {
                try LegacyDatabaseConnector(installation: installation)
                    .exportDatabase(named: database, credentials: credentials, to: dump)
            }.value
            if !databaseRunning { await startDatabase() }
            guard databaseRunning else { return false }
            let job = DatabaseRestoreJob(installation: installation, layout: .applicationSupport())
            restoreJob = job
            let plan = try job.prepare(source: dump)
            try await Task.detached {
                try job.restore(plan: plan) { completed, total in
                    let value = total > 0 ? Double(completed) / Double(total) : 0
                    Task { @MainActor in self.restoreProgress = value }
                }
            }.value
            legacyDatabaseStatus = "迁移完成：\(database)。旧数据库保持不变。"
            record("旧 XAMPP 数据库 \(database) 已通过逻辑 SQL 复制并导入。")
            await refreshDatabases()
            return true
        } catch {
            if case DatabaseBackupError.restoreCancelled = error {
                legacyDatabaseStatus = "迁移导入已取消；请检查 MacStack 中可能已经写入的部分数据。"
            } else {
                message = error.localizedDescription
                legacyDatabaseStatus = "迁移失败：\(error.localizedDescription)"
            }
            return false
        }
    }

}
