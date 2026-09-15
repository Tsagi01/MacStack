import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacStackCore
extension AppModel {
    func inspectDeveloperTools() async {
        guard !inspectingDeveloperTools else { return }
        inspectingDeveloperTools = true
        let formula = settings.preferences.preferredPHPFormula
        do {
            let result = try await Task.detached {
                let installation = try WebStackResolver(preferredFormula: formula).resolve()
                let tools = try DeveloperToolInspector().inspect(preferredPHPFormula: formula)
                let extensions = try PHPExtensionManager(installation: installation).inspect()
                return (tools, extensions)
            }.value
            developerTools = result.0
            phpExtensionReport = result.1
            let enabled = result.1.extensions.filter { $0.status == .enabled }.count
            phpExtensionStatus = "PHP 内置模块 \(result.1.builtInModules.count) 个 · 已启用动态扩展 \(enabled) 个"
            record("PHP 扩展、Composer、Perl 与 ProFTPD 检测完成。")
        } catch {
            message = "开发工具检测失败：\(error.localizedDescription)"
            phpExtensionStatus = "检测失败：\(error.localizedDescription)"
        }
        inspectingDeveloperTools = false
    }

    func setPHPExtension(_ extensionInfo: PHPExtensionInfo, enabled: Bool) async {
        guard changingPHPExtension == nil, !serviceOperationsBlocked else { return }
        changingPHPExtension = extensionInfo.name
        phpExtensionStatus = enabled ? "正在校验并启用 \(extensionInfo.title)…" : "正在校验并停用 \(extensionInfo.title)…"
        do {
            let formula = settings.preferences.preferredPHPFormula
            let result = try await Task.detached {
                let installation = try WebStackResolver(preferredFormula: formula).resolve()
                let manager = PHPExtensionManager(installation: installation)
                let change = try manager.setEnabled(extensionInfo.name, enabled: enabled)
                return (manager, change)
            }.value
            try await restartWebAfterExtensionChange(manager: result.0, change: result.1)
            let action = enabled ? "启用" : "停用"
            phpExtensionStatus = "已\(action) \(extensionInfo.title)；配置已校验并保留备份。"
            record("PHP 扩展 \(extensionInfo.name) 已\(action)。")
        } catch {
            message = error.localizedDescription
            phpExtensionStatus = "操作失败：\(error.localizedDescription)"
        }
        changingPHPExtension = nil
        await inspectDeveloperTools()
    }

    func installPHPExtension(_ extensionInfo: PHPExtensionInfo) async {
        guard changingPHPExtension == nil, !serviceOperationsBlocked else { return }
        let formula = settings.preferences.preferredPHPFormula
        let plan: String
        do {
            plan = try PHPExtensionManager(
                installation: WebStackResolver(preferredFormula: formula).resolve()
            ).installationDescription(for: extensionInfo.name)
        } catch {
            message = error.localizedDescription
            return
        }
        let alert = NSAlert()
        alert.messageText = "安装并启用 \(extensionInfo.title)？"
        alert.informativeText = "将执行：\n\(plan)\n\n安装只针对当前 Homebrew PHP 版本；MacStack 不会运行 brew upgrade，也不会修改 Homebrew 的全局 php.ini。完成后会验证 ARM64、备份私有配置，并在需要时重启 Web 服务。"
        alert.addButton(withTitle: "安装")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        changingPHPExtension = extensionInfo.name
        phpExtensionStatus = "正在安装 \(extensionInfo.title)，下载或编译可能需要几分钟…"
        do {
            let result = try await Task.detached {
                let installation = try WebStackResolver(preferredFormula: formula).resolve()
                let manager = PHPExtensionManager(installation: installation)
                _ = try manager.install(extensionInfo.name)
                let change = try manager.setEnabled(extensionInfo.name, enabled: true)
                return (manager, change)
            }.value
            try await restartWebAfterExtensionChange(manager: result.0, change: result.1)
            phpExtensionStatus = "\(extensionInfo.title) 已安装、启用并通过 PHP 加载校验。"
            record("PHP 扩展 \(extensionInfo.name) 已安装并启用。")
        } catch {
            message = error.localizedDescription
            phpExtensionStatus = "安装失败：\(error.localizedDescription)"
        }
        changingPHPExtension = nil
        await inspectDeveloperTools()
    }

    func openPHPExtensionConfigurationFolder() {
        let directory = RuntimeLayout.applicationSupport().configurationDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(directory)
        } catch {
            message = "无法打开 PHP 配置目录：\(error.localizedDescription)"
        }
    }

    private func restartWebAfterExtensionChange(
        manager: PHPExtensionManager,
        change: PHPExtensionConfigurationChange
    ) async throws {
        guard webServicesRunning else { return }
        guard let webController else {
            try? manager.restore(change)
            throw ServiceControlError.notPrepared
        }
        changingWebServices = true
        do {
            try await webController.stopWebStack()
            webServicesRunning = false
            try await webController.startWebStack(httpPort: settings.preferences.httpPort)
            webServicesRunning = true
            webStackStatus = "运行中：http://127.0.0.1:\(settings.preferences.httpPort)\nPHP 扩展配置已重新加载。"
            await refreshWebsiteStatuses()
        } catch {
            try? manager.restore(change)
            if !webServicesRunning {
                do {
                    try await webController.startWebStack(httpPort: settings.preferences.httpPort)
                    webServicesRunning = true
                    webStackStatus = "已恢复上一份 PHP 扩展配置并重新启动 Web 环境。"
                } catch {
                    webServicesRunning = false
                    webStackStatus = "扩展变更失败，上一份配置也未能重新启动；请查看日志。"
                }
            }
            changingWebServices = false
            throw error
        }
        changingWebServices = false
    }

    func inspectDependencies() async {
        do {
            if let runtime = try PortableRuntimeLocator().locate() {
                portableRuntime = runtime
                dependencyReport = nil
                dependencyStatus = "内置便携运行时 \(runtime.manifest.runtimeVersion) 已就绪；运行服务不需要 Homebrew。"
                return
            }
        } catch {
            portableRuntime = nil
            dependencyReport = nil
            dependencyStatus = "内置便携运行时损坏：\(error.localizedDescription)"
            return
        }
        portableRuntime = nil
        dependencyReport = await Task.detached { HomebrewDependencyManager().inspect() }.value
        if let dependencyReport {
            let missingRequired = dependencyReport.dependencies.filter { $0.required && $0.installedVersion == nil }
            dependencyStatus = dependencyReport.brewPath == nil
                ? "未发现 Apple Silicon Homebrew。"
                : (missingRequired.isEmpty ? "核心依赖已齐全。" : "缺少 \(missingRequired.count) 个核心依赖。")
        }
    }

    func installDependencies(_ formulas: [String]) async {
        guard !installingDependencies, !formulas.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "通过 Homebrew 安装这些组件？"
        alert.informativeText = formulas.joined(separator: "、") + "\n\nMacStack 不会执行 brew upgrade，也不会启动 brew services。安装会下载软件并占用磁盘空间。"
        alert.addButton(withTitle: "安装")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        installingDependencies = true
        dependencyStatus = "正在安装：\(formulas.joined(separator: "、"))"
        do {
            _ = try await Task.detached { try HomebrewDependencyManager().install(formulas: formulas) }.value
            dependencyStatus = "安装完成。"
            record("Homebrew 依赖安装完成：\(formulas.joined(separator: "、"))。")
            await inspectDependencies()
            await inspect()
            await inspectDeveloperTools()
        } catch {
            message = error.localizedDescription
            dependencyStatus = "安装失败：\(error.localizedDescription)"
        }
        installingDependencies = false
    }

    func runComposerInstall(for website: Website) async {
        guard composerProjectID == nil else { return }
        let alert = NSAlert()
        alert.messageText = "在 \(website.name) 中运行 Composer install？"
        alert.informativeText = "这会根据项目的 composer.json 下载或更新 vendor 目录和锁文件，只会修改所选项目。"
        alert.addButton(withTitle: "运行")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        composerProjectID = website.id
        do {
            let root = URL(fileURLWithPath: website.rootPath, isDirectory: true)
            let output = try await Task.detached { try ComposerRunner().install(project: root) }.value
            record("Composer install 已完成：\(website.name)。")
            if !output.isEmpty { webStackStatus = "Composer 完成：\n\(String(output.suffix(2_000)))" }
        } catch { message = error.localizedDescription }
        composerProjectID = nil
    }

    func prepareWebEnvironment() async {
        guard !preparingWebStack, !serviceOperationsBlocked else { return }
        preparingWebStack = true
        let preferences = settings.preferences
        let websites = settings.websites
        do {
            let prepared = try await Task.detached {
                let installation = try WebStackResolver(preferredFormula: preferences.preferredPHPFormula).resolve()
                return try WebStackPreparer().prepare(
                    installation: installation,
                    preferences: preferences,
                    websites: websites
                )
            }.value
            var status = "配置校验通过\n\(prepared.installation.apacheVersion)\n\(prepared.installation.phpVersion)\n\(prepared.layout.configurationDirectory.path)"
            if let summary = prepared.htaccessReport.summary {
                status += "\n\n.htaccess 检查：\n\(summary)"
            }
            webStackStatus = status
            webController = LocalWebStackController(installation: prepared.installation, layout: prepared.layout)
            record("Apache 与 PHP-FPM 专属配置已生成并通过语法校验；服务未启动。")
            await inspect()
        } catch {
            message = error.localizedDescription
            webStackStatus = "准备失败：\(error.localizedDescription)"
        }
        preparingWebStack = false
    }

    func startWebServices(recordIntent: Bool = true) async {
        guard !changingWebServices, !serviceOperationsBlocked else { return }
        if webController == nil { await prepareWebEnvironment() }
        guard let webController else { return }
        changingWebServices = true
        do {
            try await webController.startWebStack(httpPort: settings.preferences.httpPort)
            webServicesRunning = true
            let secure = settings.preferences.httpsEnabled ? "\nHTTPS：https://localhost:\(settings.preferences.httpsPort)" : ""
            webStackStatus = "运行中：http://127.0.0.1:\(settings.preferences.httpPort)\(secure)\nPHP 健康检查通过。"
            record("Apache + PHP-FPM 已启动，真实 PHP 健康检查通过。")
            await refreshWebsiteStatuses()
            beginServiceMonitoring()
            if recordIntent { updateServiceIntent(web: true) }
        } catch {
            webServicesRunning = false
            message = error.localizedDescription
            webStackStatus = "启动失败：\(error.localizedDescription)"
        }
        changingWebServices = false
    }

    func stopWebServices(recordIntent: Bool = true) async {
        guard !changingWebServices, !serviceOperationsBlocked else { return }
        changingWebServices = true
        let stopped = await stopWebStackUnlocked()
        changingWebServices = false
        if stopped, recordIntent { updateServiceIntent(web: false) }
    }

    /// 停止 Web 栈并**核实**结果，返回是否确实已停止。
    ///
    /// 不带锁检查，供 `save` 的受控重启流程内部调用。
    /// 与旧实现的两点区别：
    /// 1. 没有控制器时不再直接把状态置为「已停止」——那会把「进程可能仍在运行」误报成已停止；
    /// 2. 停止超时且进程仍在运行时明确返回 false，让调用方中止流程并**保留**控制器。
    func stopWebStackUnlocked() async -> Bool {
        guard let webController else {
            if webServicesRunning {
                message = "Web 服务状态不一致：标记为运行中但没有可用的进程句柄，未执行停止。请重新生成配置。"
                return false
            }
            return true
        }
        do {
            try await webController.stopWebStack()
            webServicesRunning = false
            webStackStatus = "已正常停止。配置仍保留，可再次启动。"
            record("Apache + PHP-FPM 已正常停止。")
            updateStoppedWebsiteStatuses()
            return true
        } catch {
            let apache = await webController.state(of: .apache)
            let php = await webController.state(of: .php)
            let stillRunning = apache == .running || php == .running
            webServicesRunning = stillRunning
            message = stillRunning
                ? "\(error.localizedDescription)\nWeb 服务仍在运行；控制器已保留，可再次尝试停止。"
                : error.localizedDescription
            if !stillRunning { updateStoppedWebsiteStatuses() }
            return !stillRunning
        }
    }

    func prepareDatabaseEnvironment() async {
        guard !preparingDatabase, !serviceOperationsBlocked else { return }
        preparingDatabase = true
        let preferences = settings.preferences
        do {
            let result = try await Task.detached {
                let installation = try DatabaseStackResolver().resolve()
                let prepared = try DatabaseStackPreparer().prepare(
                    installation: installation,
                    preferences: preferences
                )
                let credentials = try DatabaseCredentialStore().loadOrCreate()
                return (prepared, credentials)
            }.value
            let prepared = result.0
            databaseCredentials = result.1
            databaseController = LocalDatabaseController(
                installation: prepared.installation,
                layout: prepared.layout,
                databasePort: preferences.databasePort
            )
            databaseStatus = "已准备：\(prepared.installation.version)\n数据目录：\(prepared.layout.databaseDirectory.path)\n凭据已保存在 macOS 钥匙串。\n\(prepared.initializedNow ? "本次新建了空数据目录。" : "沿用已识别的 MacStack 数据目录，未重新初始化。")"
            record("MariaDB 独立配置和数据目录已准备；数据库未启动。")
            await inspect()
        } catch {
            message = error.localizedDescription
            databaseStatus = "准备失败：\(error.localizedDescription)"
        }
        preparingDatabase = false
    }

    func startDatabase(recordIntent: Bool = true) async {
        guard !changingDatabase, !serviceOperationsBlocked else { return }
        if databaseController == nil { await prepareDatabaseEnvironment() }
        guard let databaseController else { return }
        changingDatabase = true
        do {
            let version = try await databaseController.startAndCheck(credentials: databaseCredentials)
            databaseRunning = true
            databaseStatus = "运行中：MariaDB \(version)\n127.0.0.1:\(settings.preferences.databasePort)"
            record("MariaDB 已启动，真实 SELECT VERSION() 查询通过。")
            await refreshDatabases()
            beginServiceMonitoring()
            if recordIntent { updateServiceIntent(database: true) }
        } catch {
            databaseRunning = false
            message = error.localizedDescription
            databaseStatus = "启动失败：\(error.localizedDescription)"
        }
        changingDatabase = false
    }

    func stopDatabase(recordIntent: Bool = true) async {
        guard !changingDatabase, !serviceOperationsBlocked else { return }
        changingDatabase = true
        let stopped = await stopDatabaseUnlocked()
        changingDatabase = false
        if stopped, recordIntent { updateServiceIntent(database: false) }
    }

    /// 关闭数据库并核实结果，返回是否确实已关闭。不带锁检查，理由同 `stopWebStackUnlocked`。
    func stopDatabaseUnlocked() async -> Bool {
        guard let databaseController else {
            if databaseRunning {
                message = "数据库状态不一致：标记为运行中但没有可用的进程句柄，未执行关闭。请重新准备数据库。"
                return false
            }
            return true
        }
        do {
            try await databaseController.stop(.mariadb)
            databaseRunning = false
            databaseStatus = "已正常关闭。数据目录保持不变。"
            databases = []
            selectedDatabase = ""
            record("MariaDB 已正常关闭。")
            return true
        } catch {
            let stillRunning = await databaseController.state(of: .mariadb) == .running
            databaseRunning = stillRunning
            message = stillRunning
                ? "\(error.localizedDescription)\nMariaDB 仍在运行；控制器已保留，可再次尝试关闭。"
                : error.localizedDescription
            return !stillRunning
        }
    }

    func stopAllServicesForTermination() async {
        serviceMonitorTask?.cancel()
        backupSchedulerTask?.cancel()
        // 退出路径必须能停服，因此直接走不带锁的实现，不受保存锁影响。
        if webServicesRunning { _ = await stopWebStackUnlocked() }
        if databaseRunning { _ = await stopDatabaseUnlocked() }
    }

    func startAllServices() async {
        guard !changingAllServices, !serviceOperationsBlocked else { return }
        changingAllServices = true
        if !databaseRunning { await startDatabase() }
        if !webServicesRunning { await startWebServices() }
        if webServicesRunning && databaseRunning {
            record("全部服务已启动。")
        } else {
            message = "部分服务未能启动，请查看总览中的状态和日志。"
        }
        changingAllServices = false
    }

    func stopAllServices() async {
        guard !changingAllServices, !serviceOperationsBlocked else { return }
        changingAllServices = true
        if webServicesRunning { await stopWebServices() }
        if databaseRunning { await stopDatabase() }
        if !webServicesRunning && !databaseRunning { record("全部服务已停止。") }
        changingAllServices = false
    }

}
