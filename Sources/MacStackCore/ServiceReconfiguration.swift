import Foundation

// 服务重新配置的编排层。
//
// 背景：原先的 `AppModel.save` 在预设变化时直接把控制器置为 nil，却没有先停服务。
// 结果是进程继续运行而应用失去控制权。修复的关键不是「先停再置空」这么简单，
// 而是要把整套「校验 → 分类 → 停服 → 重新生成 → 重启 → 失败回滚」的顺序
// 放到一个可测试的地方，并保证控制器在整个过程中始终非 nil。
//
// 本文件只依赖协议，不依赖具体进程实现，因此可以在测试里用假实现完整驱动。

// MARK: - 控制器协议

/// Web 栈的控制接口。
///
/// `LocalWebStackController` 已具备全部方法，补一行 conformance 即可；
/// 引入协议的目的是让编排层和测试不依赖具体的进程实现。
public protocol WebStackControlling: Sendable {
    func startWebStack(httpPort: Int) async throws
    func stopWebStack() async throws
    func state(of component: Component) async -> ServiceState
}

// MARK: - 变更分类

/// 比较两份 `Preferences`，判断变更会影响到什么。
///
/// 分两类：
/// - **使控制器失效**：端口、PHP 版本、HTTPS、CGI。这些会改变进程启动参数，
///   必须停服并丢弃控制器，下次使用时重新 prepare。
/// - **只需重新生成配置**：时区、上传/内存限制、`.htaccess` 开关等。这些只影响
///   生成的配置文件内容，停服 → 用新设置重新生成 → 受控重启即可，控制器可以保留。
public struct PreferenceChanges: Equatable, Sendable {
    public enum Scope: Equatable, Sendable {
        /// 无需重新配置。
        case none
        /// 只需重新生成配置文件。
        case configurationOnly
        /// 使控制器失效，必须停服并丢弃控制器。
        case requiresControllerReset
    }

    /// 使控制器失效的偏好项。
    public static let controllerInvalidatingKeys: Set<String> = [
        "httpPort", "databasePort", "preferredPHPFormula",
        "httpsEnabled", "httpsPort", "perlCGIEnabled"
    ]

    /// 只需重新生成配置的偏好项。
    ///
    /// 这些只影响生成的配置文件内容，停服 → 用新设置重新生成 → 受控重启即可，
    /// 控制器可以保留。
    public static let configurationRegeneratingKeys: Set<String> = [
        "allowHtaccess", "allowHtaccessOptions", "phpTimezone",
        "memoryLimitMB", "uploadMaxFilesizeMB", "postMaxSizeMB",
        "optionalApacheModules"
    ]

    /// 不影响已生成配置、因此无需重新配置的偏好项。
    public static let nonReconfiguringKeys: Set<String> = [
        "restoreLastSession", "autoStartWeb", "autoStartDatabase",
        "automaticBackupEnabled", "backupIntervalHours", "backupRetentionDays"
    ]

    public private(set) var invalidatingKeys: [String] = []
    public private(set) var regeneratingKeys: [String] = []

    /// 直接指定变更集。主要供测试构造阶段二才会出现的 B 类变更。
    public init(invalidatingKeys: [String] = [], regeneratingKeys: [String] = []) {
        self.invalidatingKeys = invalidatingKeys
        self.regeneratingKeys = regeneratingKeys
    }

    public init(from old: Preferences, to new: Preferences) {
        func record(_ name: String, changed: Bool, into list: inout [String]) {
            if changed { list.append(name) }
        }
        record("httpPort", changed: old.httpPort != new.httpPort, into: &invalidatingKeys)
        record("databasePort", changed: old.databasePort != new.databasePort, into: &invalidatingKeys)
        record("preferredPHPFormula", changed: old.preferredPHPFormula != new.preferredPHPFormula, into: &invalidatingKeys)
        record("httpsEnabled", changed: old.httpsEnabled != new.httpsEnabled, into: &invalidatingKeys)
        record("httpsPort", changed: old.httpsPort != new.httpsPort, into: &invalidatingKeys)
        record("perlCGIEnabled", changed: old.perlCGIEnabled != new.perlCGIEnabled, into: &invalidatingKeys)

        record("allowHtaccess", changed: old.allowHtaccess != new.allowHtaccess, into: &regeneratingKeys)
        record("allowHtaccessOptions", changed: old.allowHtaccessOptions != new.allowHtaccessOptions, into: &regeneratingKeys)
        record("phpTimezone", changed: old.phpTimezone != new.phpTimezone, into: &regeneratingKeys)
        record("memoryLimitMB", changed: old.memoryLimitMB != new.memoryLimitMB, into: &regeneratingKeys)
        record("uploadMaxFilesizeMB", changed: old.uploadMaxFilesizeMB != new.uploadMaxFilesizeMB, into: &regeneratingKeys)
        record("postMaxSizeMB", changed: old.postMaxSizeMB != new.postMaxSizeMB, into: &regeneratingKeys)
        // 用集合比较，避免界面勾选顺序不同被误判成变更。
        record("optionalApacheModules",
               changed: Set(old.optionalApacheModules) != Set(new.optionalApacheModules),
               into: &regeneratingKeys)
    }

    public var scope: Scope {
        if !invalidatingKeys.isEmpty { return .requiresControllerReset }
        if !regeneratingKeys.isEmpty { return .configurationOnly }
        return .none
    }

    /// 所有被登记的偏好项名称，供漂移测试使用。
    public static var classifiedKeys: Set<String> {
        controllerInvalidatingKeys
            .union(configurationRegeneratingKeys)
            .union(nonReconfiguringKeys)
    }
}

// MARK: - 操作闸门

/// 判断当前状态允许开始哪些操作。
///
/// 放在 Core 而不是散落在界面层，是因为「什么时候该拒绝」属于业务规则：
/// 重复保存、服务切换中保存、备份恢复中保存都必须被拒绝，而这些判断需要
/// 同时看到多个状态位。集中在纯结构体里也便于用单元测试锁住行为。
public struct OperationGate: Equatable, Sendable {
    public var savingSettings: Bool
    public var changingWebServices: Bool
    public var changingDatabase: Bool
    public var changingAllServices: Bool
    public var changingWebsite: Bool
    public var backingUpDatabase: Bool
    public var restoringDatabase: Bool

    public init(
        savingSettings: Bool = false,
        changingWebServices: Bool = false,
        changingDatabase: Bool = false,
        changingAllServices: Bool = false,
        changingWebsite: Bool = false,
        backingUpDatabase: Bool = false,
        restoringDatabase: Bool = false
    ) {
        self.savingSettings = savingSettings
        self.changingWebServices = changingWebServices
        self.changingDatabase = changingDatabase
        self.changingAllServices = changingAllServices
        self.changingWebsite = changingWebsite
        self.backingUpDatabase = backingUpDatabase
        self.restoringDatabase = restoringDatabase
    }

    /// 开始一次设置保存前的判据。返回 nil 表示允许。
    public var saveRejection: String? {
        if savingSettings { return "正在保存预设，请稍候。" }
        if changingAllServices || changingWebServices || changingDatabase || changingWebsite {
            return "服务正在切换状态，请稍候再保存预设。"
        }
        if backingUpDatabase || restoringDatabase {
            return "备份或恢复正在进行，请完成后再保存预设。"
        }
        return nil
    }

    /// 开始一次会改变服务状态的操作前的判据。返回 nil 表示允许。
    ///
    /// 注意这里**只**检查保存锁。各操作自身的互斥（如 `changingWebServices`）
    /// 仍由各自入口负责，因为那些判据与具体操作相关。
    public var serviceRejection: String? {
        savingSettings ? "正在保存预设，请稍候再操作服务。" : nil
    }
}

// MARK: - 编排所需的外部效果

/// 编排层需要外部提供的操作。
///
/// 用协议而不是闭包，是为了让测试可以用一个假实现记录调用顺序，
/// 从而断言「控制器在停服确认之前从未被丢弃」这类性质。
@MainActor
public protocol ServiceReconfigurationEffects: AnyObject {
    /// 校验新设置。失败必须抛错且不产生任何副作用。
    func validateSettings(_ settings: WorkspaceSettings) throws

    /// 停止 Web 服务，返回是否**确实已停止**。
    /// 返回 false 表示服务仍在运行，此时调用方必须中止流程并保留控制器。
    ///
    /// 名字刻意加 `ForReconfiguration` 后缀：`AppModel` 上已有
    /// `stopDatabase(recordIntent:)` 这类带默认参数的公开入口，若这里直接叫
    /// `stopDatabase()`，无参调用会被解析到这个方法上，绕过原有的状态管理。
    func stopWebForReconfiguration() async -> Bool

    /// 关闭数据库，返回是否确实已关闭。命名理由同上。
    func stopDatabaseForReconfiguration() async -> Bool

    /// 用给定设置重新生成 Web 配置并受控重启。
    func regenerateWebConfiguration(
        preferences: Preferences,
        websites: [Website],
        wasRunning: Bool
    ) async throws

    /// 持久化设置。
    func persistSettings(_ settings: WorkspaceSettings) throws

    /// 使控制器失效：丢弃控制器引用，并重置依赖它的状态与提示。
    /// **只能在服务已确认停止后调用。**
    func invalidateServiceControllers()

    /// 回滚：用旧设置恢复 Web 配置与运行状态。
    func restoreWebConfiguration(
        preferences: Preferences,
        websites: [Website],
        wasRunning: Bool
    ) async throws
}

// MARK: - 结果

public enum ReconfigurationOutcome: Equatable, Sendable {
    /// 被拒绝，未产生任何变更。
    case rejected(String)
    /// 无需重新配置，仅持久化。
    case persistedOnly
    /// 已重新配置。
    case reconfigured(webRestarted: Bool)

    public var isFailure: Bool {
        if case .rejected = self { return true }
        return false
    }
}

// MARK: - 编排

public struct ServiceReconfiguration: Sendable {
    /// 执行一次设置保存。变更集由调用方从两份设置算出。
    ///
    /// 顺序是固定的，每一步都有理由：
    /// 1. **先校验**——否则一个非法端口会白白停掉正在运行的服务。
    /// 2. **再停服并确认**——停不掉就中止，此时什么都没改变。
    /// 3. **然后持久化**。
    /// 4. **最后才丢弃控制器**——这是原实现的错误所在：它先丢弃再停服。
    ///
    /// 全过程 `effects` 都持有控制器，因此「失去进程控制权」在结构上不可能发生。
    @MainActor
    public static func apply(
        previous: WorkspaceSettings,
        next: WorkspaceSettings,
        changes: PreferenceChanges,
        webWasRunning: Bool,
        databaseWasRunning: Bool,
        effects: any ServiceReconfigurationEffects
    ) async -> ReconfigurationOutcome {
        do {
            try effects.validateSettings(next)
        } catch {
            return .rejected("设置未保存：\(error.localizedDescription)")
        }

        switch changes.scope {
        case .none:
            do {
                try effects.persistSettings(next)
                return .persistedOnly
            } catch {
                return .rejected("设置未保存：\(error.localizedDescription)")
            }

        case .requiresControllerReset:
            if webWasRunning, await effects.stopWebForReconfiguration() == false {
                return .rejected("运行中的 Web 服务未能停止，已取消保存。请先手动停止服务再修改端口预设。")
            }
            if databaseWasRunning, await effects.stopDatabaseForReconfiguration() == false {
                return .rejected("运行中的数据库未能正常关闭，已取消保存。请先手动停止数据库再修改端口预设。")
            }
            do {
                try effects.persistSettings(next)
            } catch {
                // 服务已停但设置没落盘。旧配置在磁盘上仍然有效，如实说明即可，
                // 不谎称已恢复运行状态。
                return .rejected("""
                设置未保存：\(error.localizedDescription)
                服务已停止，磁盘上的配置未更改，可重新启动。
                """)
            }
            effects.invalidateServiceControllers()
            return .reconfigured(webRestarted: false)

        case .configurationOnly:
            // 无论服务是否在运行，都必须重新生成配置。
            //
            // 之前服务未运行时走的是「只保存设置」的早返回，看似无害，实则会让磁盘上的
            // 配置保持旧值。之后启动时 `webController` 仍然存在（没有被失效），
            // `startWebServices` 会直接复用它、跳过 `prepareWebEnvironment`，
            // 于是「启动过 → 停止 → 改上传限制或 .htaccess 开关 → 再启动」这条
            // 最常见的路径上，设置静默不生效。
            if webWasRunning, await effects.stopWebForReconfiguration() == false {
                return .rejected("运行中的 Web 服务未能停止，已取消保存。")
            }
            do {
                try await effects.regenerateWebConfiguration(
                    preferences: next.preferences,
                    websites: next.websites,
                    wasRunning: webWasRunning
                )
                try effects.persistSettings(next)
                return .reconfigured(webRestarted: webWasRunning)
            } catch {
                var note = "\n已恢复上一份配置"
                do {
                    try await effects.restoreWebConfiguration(
                        preferences: previous.preferences,
                        websites: previous.websites,
                        wasRunning: webWasRunning
                    )
                    note += webWasRunning ? "与运行状态。" : "。"
                } catch {
                    note += "，但配置未能恢复，请查看服务日志。"
                }
                return .rejected(error.localizedDescription + note)
            }
        }
    }

    /// 便捷重载：自动从两份设置算出变更集。生产代码用这个。
    @MainActor
    public static func apply(
        previous: WorkspaceSettings,
        next: WorkspaceSettings,
        webWasRunning: Bool,
        databaseWasRunning: Bool,
        effects: any ServiceReconfigurationEffects
    ) async -> ReconfigurationOutcome {
        await apply(
            previous: previous,
            next: next,
            changes: PreferenceChanges(from: previous.preferences, to: next.preferences),
            webWasRunning: webWasRunning,
            databaseWasRunning: databaseWasRunning,
            effects: effects
        )
    }
}
