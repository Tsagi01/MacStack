import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacStackCore

@MainActor
final class AppModel: ObservableObject {
    // 关于访问级别：本类型按职责拆在 AppModel.swift 与若干 AppModel+*.swift 里，
    // 而 Swift 的 `private` 是**文件级**作用域，因此被多个文件共用的状态与辅助方法
    // 只能是 internal。这是拆分大类型的固有代价，不是随手放宽。
    //
    // 代价是模块内其他类型（例如各 View）技术上也能读到 `webController` 这类内部状态。
    // 新增成员时请优先保持 `private`；确实需要跨文件时，先考虑这段逻辑是否本该
    // 属于 MacStackCore，而不是直接放宽访问级别。
    @Published var inspections: [ComponentInspection] = []
    @Published var settings = WorkspaceSettings()
    @Published var scanning = false
    @Published var preparingWebStack = false
    @Published var webStackStatus = "尚未生成 MacStack 专属配置。"
    @Published var webServicesRunning = false
    @Published var changingWebServices = false
    @Published var preparingDatabase = false
    @Published var databaseRunning = false
    @Published var changingDatabase = false
    @Published var changingAllServices = false
    /// 覆盖整个「保存预设」过程的状态锁。
    ///
    /// 仅把它加进 `hasCriticalOperation` 不会阻止任何操作——那个属性只被退出流程读取。
    /// 真正生效需要每个操作入口各自检查它，见 `serviceOperationsBlocked`。
    @Published var savingSettings = false
    @Published var databaseStatus = "尚未准备 MacStack 独立数据库。"
    @Published var databases: [String] = []
    @Published var selectedDatabase = ""
    @Published var databaseBackupStatus = "启动数据库后可刷新列表、导出 SQL 或恢复备份。"
    @Published var backingUpDatabase = false
    @Published var restoringDatabase = false
    @Published var restoreProgress = 0.0
    @Published var backupRecords: [BackupRecord] = []
    @Published var automaticBackupStatus = "自动备份未启用。"
    @Published var preparingPHPMyAdmin = false
    @Published var phpMyAdminPrepared = false
    @Published var phpMyAdminStatus = "尚未准备 phpMyAdmin。"
    @Published var auditingXAMPP = false
    @Published var xamppAuditStatus = "尚未盘点旧 XAMPP。只读盘点不会执行迁移。"
    @Published var xamppAuditReportPath: String?
    @Published var xamppSites: [XAMPPSiteAudit] = []
    @Published var migratingSite: String?
    @Published var websiteMigrationStatus = "请先生成只读盘点报告，再选择网站创建迁移副本。"
    @Published var legacyDatabases: [String] = []
    @Published var checkingLegacyDatabase = false
    @Published var migratingLegacyDatabase: String?
    @Published var legacyDatabaseStatus = "连接正在运行的旧 XAMPP 数据库后，可按逻辑 SQL 方式复制到 MacStack。"
    @Published var websiteStatuses: [UUID: String] = [:]
    @Published var changingWebsiteID: UUID?
    @Published var creatingProject = false
    @Published var message: String?
    @Published var canSave = true
    @Published var activities: [String] = []
    @Published var developerTools: DeveloperToolReport?
    @Published var phpExtensionReport: PHPExtensionReport?
    @Published var inspectingDeveloperTools = false
    @Published var changingPHPExtension: String?
    @Published var phpExtensionStatus = "正在读取当前 PHP 的内置与动态扩展。"
    @Published var composerProjectID: UUID?
    @Published var tlsStatus = "HTTPS 默认关闭；启用后会生成仅用于本机开发的证书。"
    @Published var dependencyReport: HomebrewDependencyReport?
    @Published var portableRuntime: PortableRuntime?
    @Published var installingDependencies = false
    @Published var dependencyStatus = "尚未检查 Homebrew 依赖。"
    let store = SettingsStore()
    private let intentStore = ServiceIntentStore()
    let backupCatalog = BackupCatalogStore()
    var webController: LocalWebStackController?
    var databaseController: LocalDatabaseController?
    var databaseCredentials: DatabaseCredentials?
    var serviceMonitorTask: Task<Void, Never>?
    var backupSchedulerTask: Task<Void, Never>?
    var restoreJob: DatabaseRestoreJob?
    private var didLaunch = false

    var backupDirectory: URL { backupCatalog.directory }
    var hasCriticalOperation: Bool {
        savingSettings || restoringDatabase || backingUpDatabase || migratingLegacyDatabase != nil ||
            creatingProject || installingDependencies || changingPHPExtension != nil
    }

    /// 各操作入口共用的状态闸门。判据本身在 `MacStackCore.OperationGate`，可单元测试。
    ///
    /// 内部受控重启（重新生成配置并重启）走不带检查的私有实现，不受它限制，
    /// 否则保存过程会把自己挡住。
    var operationGate: OperationGate {
        OperationGate(
            savingSettings: savingSettings,
            changingWebServices: changingWebServices,
            changingDatabase: changingDatabase,
            changingAllServices: changingAllServices,
            changingWebsite: changingWebsiteID != nil,
            backingUpDatabase: backingUpDatabase,
            restoringDatabase: restoringDatabase
        )
    }

    /// 保存预设期间，其他会改变服务状态或写入配置的操作都应被拒绝。
    var serviceOperationsBlocked: Bool {
        operationGate.serviceRejection != nil
    }

    init() {
        do { settings = try store.load() }
        catch {
            canSave = false
            message = "配置读取失败：\(error.localizedDescription)\n为保护原文件，本次已禁用保存。"
        }
        let layout = RuntimeLayout.applicationSupport()
        phpMyAdminPrepared = FileManager.default.fileExists(
            atPath: layout.phpMyAdminDirectory.appendingPathComponent("index.php").path
        )
        if phpMyAdminPrepared { phpMyAdminStatus = "已发现 MacStack 的 phpMyAdmin 副本。" }
        backupRecords = backupCatalog.load()
        updateStoppedWebsiteStatuses()
    }

    func launch() async {
        guard !didLaunch else { return }
        didLaunch = true
        await inspect()
        await inspectDeveloperTools()
        await inspectDependencies()
        do {
            let result = try await Task.detached { try ResidualServiceRecovery().recover() }.value
            if result.stoppedProcessCount > 0 || result.removedStalePIDCount > 0 {
                record("已清理上次强制退出留下的服务：终止 \(result.stoppedProcessCount) 个进程，移除 \(result.removedStalePIDCount) 个失效 PID。")
            }
            if !result.unresolved.isEmpty {
                // 逐个汇报，而不是只显示第一个：这些进程都没有被终止，
                // 需要让用户知道并自行判断。
                let details = result.unresolved
                    .map { "PID \($0.pid)：\($0.reason)\n\($0.command)" }
                    .joined(separator: "\n\n")
                message = "有 \(result.unresolved.count) 个进程无法确认是否属于 MacStack，因此没有终止：\n\n\(details)"
            }
        } catch {
            message = "残留服务检查未完成：\(error.localizedDescription)"
        }
        let lastIntent = intentStore.load()
        let shouldStartWeb = settings.preferences.autoStartWeb || (settings.preferences.restoreLastSession && lastIntent.webRunning)
        let shouldStartDatabase = settings.preferences.autoStartDatabase || (settings.preferences.restoreLastSession && lastIntent.databaseRunning)
        if shouldStartDatabase { await startDatabase(recordIntent: false) }
        if shouldStartWeb { await startWebServices(recordIntent: false) }
        if shouldStartWeb || shouldStartDatabase {
            record("已按启动设置恢复服务状态。")
        }
        beginBackupScheduler()
    }

    func inspect() async {
        guard !scanning else { return }
        scanning = true
        inspections = await Task.detached { ComponentDetector().inspectAll() }.value
        scanning = false
        record("组件检测完成：\(inspections.filter { $0.status == .appleSilicon }.count)/3 包含 ARM64。未启动服务。")
    }


    func record(_ text: String) {
        activities.insert("\(Date().formatted(date: .omitted, time: .standard))  \(text)", at: 0)
        activities = Array(activities.prefix(100))
    }

    func updateServiceIntent(web: Bool? = nil, database: Bool? = nil) {
        var value = intentStore.load()
        if let web { value.webRunning = web }
        if let database { value.databaseRunning = database }
        do { try intentStore.save(value) }
        catch { message = "服务状态偏好保存失败：\(error.localizedDescription)" }
    }

    func serviceStateText(_ state: ServiceState) -> String {
        switch state {
        case .notConnected: "未连接"
        case .stopped: "已停止"
        case .starting: "启动中"
        case .running: "运行中"
        case .stopping: "停止中"
        case .failed(let detail): "失败（\(detail)）"
        }
    }
}
