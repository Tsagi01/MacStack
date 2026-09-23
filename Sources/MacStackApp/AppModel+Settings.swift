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

    /// 刷新所有已启用网站的状态。
    ///
    /// 两个要点：
    ///
    /// 1. **有限并发。** 之前是完全串行、每站 2 秒超时，站点一多总等待时间线性增长，
    ///    一个卡住的站点会拖住其余全部。现在按 `websiteProbeConcurrency` 分批并发。
    /// 2. **取消过期请求。** 新一轮刷新开始前取消上一轮，避免旧探测结果覆盖新结果。
    func refreshWebsiteStatuses() async {
        websiteStatusRefreshTask?.cancel()
        websiteSingleRefreshTokens.removeAll()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performWebsiteStatusRefresh()
        }
        websiteStatusRefreshTask = task
        await task.value
    }

    /// 只刷新一个网站。用于网站卡片上的手动刷新按钮。
    func refreshWebsiteStatus(_ id: UUID) async {
        guard let website = settings.websites.first(where: { $0.id == id }), website.isEnabled else { return }
        guard webServicesRunning else {
            updateStoppedWebsiteStatuses()
            return
        }
        // 用户主动刷单站时，以这次请求为准，不能让较早的全站巡检随后覆盖它。
        websiteStatusRefreshTask?.cancel()
        let token = UUID()
        websiteSingleRefreshTokens[id] = token
        let result = await WebsiteHealthProbe().probe(website.healthCheckURL)
        guard !Task.isCancelled, webServicesRunning,
              websiteSingleRefreshTokens[id] == token,
              settings.websites.first(where: { $0.id == id }) == website else { return }
        websiteSingleRefreshTokens[id] = nil
        websiteStatuses[id] = WebsiteStatus.from(result)
    }

    private func performWebsiteStatusRefresh() async {
        guard webServicesRunning else {
            updateStoppedWebsiteStatuses()
            return
        }
        let websites = settings.websites.filter(\.isEnabled)
        let probe = WebsiteHealthProbe()
        let limit = max(1, Self.websiteProbeConcurrency)
        var collected: [UUID: WebsiteStatus] = [:]

        var index = 0
        while index < websites.count {
            if Task.isCancelled { return }
            let chunk = Array(websites[index..<min(index + limit, websites.count)])
            index += limit
            await withTaskGroup(of: (UUID, WebsiteStatus).self) { group in
                for website in chunk {
                    group.addTask {
                        (website.id, WebsiteStatus.from(await probe.probe(website.healthCheckURL)))
                    }
                }
                for await (id, status) in group {
                    collected[id] = status
                }
            }
        }

        // 默认网站也探一次。它不在 settings.websites 里，但同样由 Apache 提供。
        var defaultStatus: WebsiteStatus?
        if let url = defaultWebsiteURL {
            defaultStatus = WebsiteStatus.from(await probe.probe(url))
        }

        guard !Task.isCancelled, webServicesRunning else { return }
        for (id, status) in collected {
            websiteStatuses[id] = status
        }
        if let defaultStatus { defaultWebsiteStatus = defaultStatus }
    }

    /// 默认网站的访问地址。它由管理端口的 vhost 提供。
    var defaultWebsiteURL: URL? {
        URL(string: "http://127.0.0.1:\(settings.preferences.httpPort)/")
    }

    /// 服务未运行时的状态刷新。
    ///
    /// **只更新「状态更新时间」，保留上一次真实请求的「最后检查时间」。**
    /// 两个都刷新的话，停掉服务看起来像刚做过 HTTP 检查，而实际那次检查发生在更早、
    /// 服务还在运行的时候。
    /// 检查是否有新版本。
    ///
    /// 只查、只展示，**不下载、不替换、不自动打开浏览器**。自动更新要处理签名验证、
    /// 停服、替换失败回滚，以及「MariaDB 大版本升级不能等同于程序文件回退」，
    /// 是独立的一件事。
    func checkForUpdate() async {
        guard !checkingForUpdate else { return }
        guard let current = AppVersion.marketing else {
            updateCheckResult = UpdateCheckResult(
                status: .failed,
                currentVersion: "—",
                failureReason: "当前是开发构建，没有版本号可用于比较。"
            )
            return
        }
        checkingForUpdate = true
        defer { checkingForUpdate = false }
        updateCheckResult = await UpdateChecker().check(currentVersion: current)
    }

    /// 打开新版本的下载页。只在用户点按钮时调用。
    func openUpdateDownloadPage() {
        guard let url = updateCheckResult?.releaseURL ?? UpdateChecker.releasesPage as URL? else { return }
        NSWorkspace.shared.open(url)
    }

    /// 打开所有版本的列表页。
    func openReleasesPage() {
        NSWorkspace.shared.open(UpdateChecker.releasesPage)
    }

    func updateStoppedWebsiteStatuses(summary: String? = nil) {
        // 停服期间未结束的 HTTP 请求不能在稍后把状态重新写成“页面正常”。
        websiteStatusRefreshTask?.cancel()
        websiteSingleRefreshTokens.removeAll()
        let now = Date()
        for website in settings.websites {
            if let summary, website.isEnabled {
                websiteStatuses[website.id] = WebsiteStatus.serviceStopped(
                    previous: websiteStatuses[website.id],
                    summary: summary,
                    now: now
                )
            } else {
                websiteStatuses[website.id] = WebsiteStatus.notRunning(
                    enabled: website.isEnabled,
                    previous: websiteStatuses[website.id],
                    now: now
                )
            }
        }
        // 默认网站同样要更新，否则它会一直显示上一次真实检查的结果。
        defaultWebsiteStatus = WebsiteStatus.notRunning(
            enabled: true,
            previous: defaultWebsiteStatus,
            now: now
        )
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
                updateStoppedWebsiteStatuses(summary: "Web 服务已停止，网站不可访问")
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
