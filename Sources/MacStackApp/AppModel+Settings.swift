import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacStackCore
extension AppModel {
    func applyWebsiteSettings(_ next: WorkspaceSettings, action: String, changingID: UUID) async {
        guard changingWebsiteID == nil, !changingWebServices, !serviceOperationsBlocked else { return }
        changingWebsiteID = changingID
        let previous = settings
        let wasRunning = webServicesRunning
        var currentWasStopped = !wasRunning
        var replacementController: LocalWebStackController?
        do {
            try next.validate()
            if wasRunning {
                guard let webController else { throw ServiceControlError.notPrepared }
                try await webController.stopWebStack()
                currentWasStopped = true
            }
            let prepared = try await Task.detached {
                let installation = try WebStackResolver(preferredFormula: next.preferences.preferredPHPFormula).resolve()
                return try WebStackPreparer().prepare(
                    installation: installation,
                    preferences: next.preferences,
                    websites: next.websites
                )
            }.value
            let nextController = LocalWebStackController(installation: prepared.installation, layout: prepared.layout)
            replacementController = nextController
            if wasRunning { try await nextController.startWebStack(httpPort: next.preferences.httpPort) }
            try store.save(next)
            settings = next
            webController = nextController
            webServicesRunning = wasRunning
            record(action)
            await refreshWebsiteStatuses()
        } catch {
            var recovery = ""
            if let replacementController { try? await replacementController.stopWebStack() }
            if currentWasStopped {
                do {
                    let restored = try await Task.detached {
                        let installation = try WebStackResolver(preferredFormula: previous.preferences.preferredPHPFormula).resolve()
                        return try WebStackPreparer().prepare(
                            installation: installation,
                            preferences: previous.preferences,
                            websites: previous.websites
                        )
                    }.value
                    let restoredController = LocalWebStackController(installation: restored.installation, layout: restored.layout)
                    if wasRunning { try await restoredController.startWebStack(httpPort: previous.preferences.httpPort) }
                    webController = restoredController
                    webServicesRunning = wasRunning
                    recovery = wasRunning
                        ? "\n已恢复上一份配置并重新启动 Web 环境。"
                        : "\n已恢复上一份有效配置。"
                } catch {
                    webServicesRunning = false
                    recovery = "\n上一份配置未能恢复，请查看服务日志。"
                }
            } else {
                webServicesRunning = wasRunning
                recovery = "\n原 Web 进程仍保持原状态。"
            }
            message = error.localizedDescription + recovery
            settings = previous
            if webServicesRunning {
                await refreshWebsiteStatuses()
            } else {
                updateStoppedWebsiteStatuses()
            }
        }
        changingWebsiteID = nil
    }

    func refreshWebsiteStatuses() async {
        for website in settings.websites {
            guard website.isEnabled else {
                websiteStatuses[website.id] = "已停用"
                continue
            }
            guard webServicesRunning else {
                websiteStatuses[website.id] = "已启用 · 等待 Web 服务启动"
                continue
            }
            do {
                // Keep the browser-facing `.localhost` URL for people, but
                // probe the loopback address so ATS does not reject local HTTP.
                var request = URLRequest(url: website.healthCheckURL)
                request.timeoutInterval = 2
                let (_, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                websiteStatuses[website.id] = (200..<500).contains(status) ? "运行中 · HTTP \(status)" : "网站异常 · HTTP \(status)"
            } catch {
                websiteStatuses[website.id] = "网站无法访问 · \(error.localizedDescription)"
            }
        }
    }

    func updateStoppedWebsiteStatuses() {
        for website in settings.websites {
            websiteStatuses[website.id] = website.isEnabled ? "已启用 · 等待 Web 服务启动" : "已停用"
        }
    }

    func beginServiceMonitoring() {
        serviceMonitorTask?.cancel()
        serviceMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                await self.refreshManagedServiceStates()
                if !self.webServicesRunning && !self.databaseRunning { return }
            }
        }
    }

    func beginBackupScheduler() {
        backupSchedulerTask?.cancel()
        guard settings.preferences.automaticBackupEnabled else {
            automaticBackupStatus = "自动备份未启用。"
            return
        }
        automaticBackupStatus = "自动备份已启用：每 \(settings.preferences.backupIntervalHours) 小时检查一次。"
        backupSchedulerTask = Task { [weak self] in
            guard let self else { return }
            await self.runAutomaticBackupNow(force: false)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                await self.runAutomaticBackupNow(force: false)
            }
        }
    }

    private func refreshManagedServiceStates() async {
        // 保存预设期间暂停巡检：此时服务正在被受控停止或重启，标志位会短暂不一致，
        // 巡检介入会把中间状态当成「服务意外退出」。
        guard !savingSettings else { return }
        if webServicesRunning, !changingWebServices, let webController {
            let apache = await webController.state(of: .apache)
            let php = await webController.state(of: .php)
            if apache != .running || php != .running {
                webServicesRunning = false
                webStackStatus = "服务意外退出：Apache \(serviceStateText(apache))，PHP-FPM \(serviceStateText(php))。"
                record("检测到 Web 服务意外退出。")
                try? await webController.stopWebStack()
                updateStoppedWebsiteStatuses()
            }
        }
        if databaseRunning, !changingDatabase, let databaseController {
            let state = await databaseController.state(of: .mariadb)
            if state != .running {
                databaseRunning = false
                databaseStatus = "服务意外退出：\(serviceStateText(state))。请查看 MariaDB 日志。"
                databases = []
                selectedDatabase = ""
                record("检测到 MariaDB 意外退出。")
            }
        }
    }

}

// MARK: - 设置重新配置

/// 把 `AppModel` 接进 `ServiceReconfiguration` 的编排。
///
/// 编排本身（校验顺序、变更分类、停服核实、失败回滚）在 `MacStackCore` 里，
/// 可以在测试中用假实现完整驱动；这里只提供真实效果。
extension AppModel: ServiceReconfigurationEffects {
    func validateSettings(_ settings: WorkspaceSettings) throws {
        try settings.validate()
    }

    func stopWebForReconfiguration() async -> Bool {
        await stopWebStackUnlocked()
    }

    func stopDatabaseForReconfiguration() async -> Bool {
        await stopDatabaseUnlocked()
    }

    func persistSettings(_ settings: WorkspaceSettings) throws {
        try store.save(settings)
    }

    func invalidateServiceControllers() {
        webController = nil
        databaseController = nil
        databaseCredentials = nil
        phpMyAdminPrepared = false
        webServicesRunning = false
        databaseRunning = false
        databases = []
        selectedDatabase = ""
        webStackStatus = "端口预设已更改，请重新生成并校验配置。"
        databaseStatus = "端口预设已更改，请重新准备数据库配置。"
        phpMyAdminStatus = "端口预设已更改，请重新准备 phpMyAdmin 配置。"
        updateStoppedWebsiteStatuses()
    }

    func regenerateWebConfiguration(
        preferences: Preferences,
        websites: [Website],
        wasRunning: Bool
    ) async throws {
        try await rebuildWebStack(preferences: preferences, websites: websites, wasRunning: wasRunning)
    }

    func restoreWebConfiguration(
        preferences: Preferences,
        websites: [Website],
        wasRunning: Bool
    ) async throws {
        // 新配置可能已经成功启动，只是在随后持久化设置时失败。此时必须先停掉
        // replacement controller，否则旧配置会与它争用同一个监听端口，回滚必然失败。
        if webServicesRunning, let webController {
            try await webController.stopWebStack()
            webServicesRunning = false
        }
        try await rebuildWebStack(preferences: preferences, websites: websites, wasRunning: wasRunning)
    }

    /// 用**显式传入**的设置重新生成 Web 配置并受控重启。
    ///
    /// 刻意不复用 `prepareWebEnvironment()`：那个方法读的是 `settings.preferences`
    /// （尚未写入的旧值），失败时既不恢复旧配置也不恢复运行状态。
    ///
    /// 控制器在成功后一次性替换，全过程不置 nil；替换用的控制器若启动失败会先自行
    /// 停止，避免留下半运行的进程。
    private func rebuildWebStack(
        preferences: Preferences,
        websites: [Website],
        wasRunning: Bool
    ) async throws {
        let prepared = try await Task.detached {
            let installation = try WebStackResolver(preferredFormula: preferences.preferredPHPFormula).resolve()
            return try WebStackPreparer().prepare(
                installation: installation,
                preferences: preferences,
                websites: websites
            )
        }.value

        let replacement = LocalWebStackController(installation: prepared.installation, layout: prepared.layout)
        if wasRunning {
            do {
                try await replacement.startWebStack(httpPort: preferences.httpPort)
            } catch {
                try? await replacement.stopWebStack()
                throw error
            }
        }
        webController = replacement
        webServicesRunning = wasRunning
        var status = wasRunning
            ? "配置已更新并受控重启。\n\(prepared.installation.apacheVersion)\n\(prepared.installation.phpVersion)"
            : "配置已更新；服务未运行。"
        if let summary = prepared.htaccessReport.summary {
            status += "\n\n.htaccess 检查：\n\(summary)"
        }
        webStackStatus = status
        await inspect()
    }
}
