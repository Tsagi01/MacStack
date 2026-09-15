import Foundation

public enum Component: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case apache, php, mariadb
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .apache: "Apache"
        case .php: "PHP / PHP-FPM"
        case .mariadb: "MariaDB"
        }
    }
    public var purpose: String {
        switch self {
        case .apache: "接收网页请求，提供静态文件与 PHP 入口"
        case .php: "执行 PHP 后端代码"
        case .mariadb: "保存网站的结构化数据"
        }
    }
}

// 安装情况和服务运行状态是两个概念；框架目前只检测安装情况。
public enum InstallationStatus: String, Sendable {
    case missing = "未发现"
    case appleSilicon = "包含 ARM64"
    case incompatible = "未确认 ARM64"
}

public struct ComponentInspection: Identifiable, Sendable {
    public var id: Component { component }
    public let component: Component
    public let status: InstallationStatus
    public let executablePaths: [String]
    public let detail: String
    public init(component: Component, status: InstallationStatus, executablePaths: [String], detail: String) {
        self.component = component
        self.status = status
        self.executablePaths = executablePaths
        self.detail = detail
    }
}

public enum ServiceState: Equatable, Sendable {
    case notConnected, stopped, starting, running, stopping, failed(String)
}

public enum ServiceControlError: Error, LocalizedError {
    case notImplemented
    case notPrepared
    case unsupportedComponent
    case exitedEarly(Component, Int32)
    case healthCheckFailed(String)
    case stopTimedOut(Component)

    public var errorDescription: String? {
        switch self {
        case .notImplemented: "服务控制器尚未接入；本版本不会启动或停止任何服务。"
        case .notPrepared: "请先生成并校验 MacStack 专属配置。"
        case .unsupportedComponent: "这个组件的服务控制尚未接入。"
        case .exitedEarly(let component, let status): "\(component.title) 启动后立即退出（退出码 \(status)），请查看服务日志。"
        case .healthCheckFailed(let detail): "服务健康检查失败：\(detail)"
        case .stopTimedOut(let component): "\(component.title) 未在限定时间内正常停止；未执行强制终止。"
        }
    }
}

// 后续用真正的进程管理器实现该接口；UI 不直接执行 shell 命令。
public protocol ServiceControlling: Sendable {
    func start(_ component: Component) async throws
    func stop(_ component: Component) async throws
    func state(of component: Component) async -> ServiceState
}

public struct PendingServiceController: ServiceControlling {
    public init() {}
    public func start(_ component: Component) async throws { throw ServiceControlError.notImplemented }
    public func stop(_ component: Component) async throws { throw ServiceControlError.notImplemented }
    public func state(of component: Component) async -> ServiceState { .notConnected }
}

public struct Website: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var rootPath: String
    public var publicRootPath: String
    public var port: Int
    public var isEnabled: Bool
    public var hostname: String

    public init(
        id: UUID = UUID(),
        name: String,
        rootPath: String,
        publicRootPath: String? = nil,
        port: Int = 0,
        isEnabled: Bool = false,
        hostname: String = ""
    ) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.publicRootPath = publicRootPath ?? rootPath
        self.port = port
        self.isEnabled = isEnabled
        self.hostname = hostname
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, rootPath, publicRootPath, port, isEnabled, hostname
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        rootPath = try values.decode(String.self, forKey: .rootPath)
        publicRootPath = try values.decodeIfPresent(String.self, forKey: .publicRootPath) ?? rootPath
        port = try values.decodeIfPresent(Int.self, forKey: .port) ?? 0
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        hostname = try values.decodeIfPresent(String.self, forKey: .hostname) ?? ""
    }

    public var localURLString: String {
        "http://\(hostname.isEmpty ? "127.0.0.1" : hostname):\(port)/"
    }

    public func secureURLString(port: Int) -> String? {
        guard !hostname.isEmpty else { return nil }
        return "https://\(hostname):\(port)/"
    }
}

public struct Preferences: Codable, Equatable, Sendable {
    public var httpPort = 8080
    public var databasePort = 3307
    public var restoreLastSession = true
    public var autoStartWeb = false
    public var autoStartDatabase = false
    public var automaticBackupEnabled = false
    public var backupIntervalHours = 24
    public var preferredPHPFormula = "auto"
    public var httpsEnabled = false
    public var httpsPort = 8443
    public var perlCGIEnabled = false

    /// 是否允许站点目录使用 `.htaccess`。
    ///
    /// 默认开启：XAMPP 默认就是 `AllowOverride All`，关闭它会让 WordPress 固定链接、
    /// Laravel、ThinkPHP 这类依赖伪静态的项目直接 404。放开的是
    /// `FileInfo Indexes AuthConfig Limit` 四类覆盖，**不含 `Options`**，
    /// 因此站点无法通过 `.htaccess` 推翻 MacStack 设置的符号链接与目录列表策略。
    public var allowHtaccess = true

    /// 是否额外放开 `Options` 覆盖。仅供确实需要 `.htaccess` 调整 Options 的项目。
    public var allowHtaccessOptions = false

    /// PHP 时区。空字符串表示跟随系统时区。
    public var phpTimezone = ""

    public var memoryLimitMB = 512
    public var uploadMaxFilesizeMB = 64
    public var postMaxSizeMB = 80

    /// 自动备份的保留天数。超期的**自动**备份会被清理，手工备份不受影响。
    /// 设为 0 表示不清理。
    public var backupRetentionDays = 30

    /// 按需加载的可选 Apache 模块。可选值见 `Preferences.optionalApacheModulesWhitelist`。
    public var optionalApacheModules: [String] = []

    public init() {}

    /// 可以按需加载的可选模块。`status` 刻意不在列表里——它不提供任何 `.htaccess`
    /// 覆盖类，且会暴露服务状态。
    public static let optionalApacheModulesWhitelist = ["expires", "deflate", "autoindex"]

    private enum CodingKeys: String, CodingKey {
        case httpPort, databasePort, restoreLastSession, autoStartWeb, autoStartDatabase
        case automaticBackupEnabled, backupIntervalHours, preferredPHPFormula
        case httpsEnabled, httpsPort
        case perlCGIEnabled
        case allowHtaccess, allowHtaccessOptions, phpTimezone
        case memoryLimitMB, uploadMaxFilesizeMB, postMaxSizeMB
        case optionalApacheModules
        case backupRetentionDays
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        httpPort = try values.decodeIfPresent(Int.self, forKey: .httpPort) ?? 8080
        databasePort = try values.decodeIfPresent(Int.self, forKey: .databasePort) ?? 3307
        restoreLastSession = try values.decodeIfPresent(Bool.self, forKey: .restoreLastSession) ?? true
        autoStartWeb = try values.decodeIfPresent(Bool.self, forKey: .autoStartWeb) ?? false
        autoStartDatabase = try values.decodeIfPresent(Bool.self, forKey: .autoStartDatabase) ?? false
        automaticBackupEnabled = try values.decodeIfPresent(Bool.self, forKey: .automaticBackupEnabled) ?? false
        backupIntervalHours = try values.decodeIfPresent(Int.self, forKey: .backupIntervalHours) ?? 24
        preferredPHPFormula = try values.decodeIfPresent(String.self, forKey: .preferredPHPFormula) ?? "auto"
        httpsEnabled = try values.decodeIfPresent(Bool.self, forKey: .httpsEnabled) ?? false
        httpsPort = try values.decodeIfPresent(Int.self, forKey: .httpsPort) ?? 8443
        perlCGIEnabled = try values.decodeIfPresent(Bool.self, forKey: .perlCGIEnabled) ?? false
        allowHtaccess = try values.decodeIfPresent(Bool.self, forKey: .allowHtaccess) ?? true
        allowHtaccessOptions = try values.decodeIfPresent(Bool.self, forKey: .allowHtaccessOptions) ?? false
        phpTimezone = try values.decodeIfPresent(String.self, forKey: .phpTimezone) ?? ""
        memoryLimitMB = try values.decodeIfPresent(Int.self, forKey: .memoryLimitMB) ?? 512
        uploadMaxFilesizeMB = try values.decodeIfPresent(Int.self, forKey: .uploadMaxFilesizeMB) ?? 64
        postMaxSizeMB = try values.decodeIfPresent(Int.self, forKey: .postMaxSizeMB) ?? 80
        optionalApacheModules = try values.decodeIfPresent([String].self, forKey: .optionalApacheModules) ?? []
        backupRetentionDays = try values.decodeIfPresent(Int.self, forKey: .backupRetentionDays) ?? 30
    }

    /// 实际生效的时区标识符。空值表示跟随系统。
    public var resolvedTimezone: String {
        let trimmed = phpTimezone.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let system = TimeZone.current.identifier
            return system.isEmpty ? "UTC" : system
        }
        return TimeZone(identifier: trimmed) != nil ? trimmed : (TimeZone.current.identifier.isEmpty ? "UTC" : TimeZone.current.identifier)
    }

    /// 生成 `.htaccess` 的 `AllowOverride` 取值。
    ///
    /// 刻意不含 `Options`：`FollowSymLinks` 的默认值就是开启，而 `.htaccess` 里的
    /// `Options` 指令会推翻 MacStack 的 `-Indexes -FollowSymLinks +SymLinksIfOwnerMatch`。
    /// 确实需要时才由 `allowHtaccessOptions` 显式放开。
    public var allowOverrideValue: String {
        guard allowHtaccess else { return "None" }
        return allowHtaccessOptions ? "All" : "FileInfo Indexes AuthConfig Limit"
    }

    public func validate() throws {
        guard (1024...65535).contains(httpPort), (1024...65535).contains(databasePort),
              (1024...65535).contains(httpsPort) else {
            throw SettingsError.invalidPorts
        }
        guard Set([httpPort, databasePort, httpsPort]).count == 3 else { throw SettingsError.duplicatePorts }
        guard (1...168).contains(backupIntervalHours) else { throw SettingsError.invalidBackupInterval }
        guard (0...3650).contains(backupRetentionDays) else { throw SettingsError.invalidBackupRetention }
        guard ["auto", "php@8.2", "php@8.3", "php@8.4", "php@8.5", "php"].contains(preferredPHPFormula) else {
            throw SettingsError.invalidPHPFormula
        }
        guard (32...4096).contains(memoryLimitMB) else { throw SettingsError.invalidMemoryLimit }
        guard (1...2048).contains(uploadMaxFilesizeMB) else { throw SettingsError.invalidUploadLimit }
        guard (1...4096).contains(postMaxSizeMB) else { throw SettingsError.invalidPostLimit }
        // multipart 请求体除文件本身外还有 boundary 与各字段头开销，
        // post_max_size 必须严格大于 upload_max_filesize，否则大文件上传会静默失败。
        guard postMaxSizeMB > uploadMaxFilesizeMB else { throw SettingsError.postLimitNotLargerThanUpload }
        // memory_limit 需要容纳一整个 post_max_size 大小的请求体。
        guard memoryLimitMB >= postMaxSizeMB else { throw SettingsError.memoryLimitBelowPostLimit }
        let trimmedTimezone = phpTimezone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedTimezone.isEmpty || TimeZone(identifier: trimmedTimezone) != nil else {
            throw SettingsError.invalidTimezone
        }
        for module in optionalApacheModules {
            guard Preferences.optionalApacheModulesWhitelist.contains(module) else {
                throw SettingsError.invalidOptionalApacheModule
            }
        }
        guard Set(optionalApacheModules).count == optionalApacheModules.count else {
            throw SettingsError.invalidOptionalApacheModule
        }
    }
}

public enum SettingsError: Error, LocalizedError {
    case invalidPorts, duplicatePorts, unsupportedSchema, duplicateWebsite
    case invalidWebsitePort(String), duplicateWebsitePort(Int), invalidWebsiteName, duplicateHostname(String)
    case invalidBackupInterval, invalidPHPFormula
    case invalidBackupRetention
    case invalidMemoryLimit, invalidUploadLimit, invalidPostLimit
    case postLimitNotLargerThanUpload, memoryLimitBelowPostLimit
    case invalidTimezone, invalidOptionalApacheModule
    public var errorDescription: String? {
        switch self {
        case .invalidPorts: "端口必须在 1024–65535 之间。"
        case .duplicatePorts: "网站和数据库不能使用同一个端口。"
        case .unsupportedSchema: "配置来自不兼容的版本，未覆盖现有文件。"
        case .duplicateWebsite: "这个网站目录已经登记。"
        case .invalidWebsitePort(let name): "网站“\(name)”的端口必须在 1024–65535 之间，且不能占用管理或数据库端口。"
        case .duplicateWebsitePort(let port): "多个网站使用了同一端口 \(port)。"
        case .invalidWebsiteName: "网站名称不能为空，也不能包含换行或空字符。"
        case .duplicateHostname(let hostname): "多个网站使用了同一个本地域名：\(hostname)"
        case .invalidBackupInterval: "自动备份间隔必须在 1–168 小时之间。"
        case .invalidBackupRetention: "自动备份保留天数必须在 0–3650 之间，0 表示不清理。"
        case .invalidPHPFormula: "PHP 版本预设无效。"
        case .invalidMemoryLimit: "memory_limit 必须在 32–4096 MB 之间。"
        case .invalidUploadLimit: "upload_max_filesize 必须在 1–2048 MB 之间。"
        case .invalidPostLimit: "post_max_size 必须在 1–4096 MB 之间。"
        case .postLimitNotLargerThanUpload:
            "post_max_size 必须大于 upload_max_filesize。multipart 请求体除文件本身外还有额外开销，两者相等会导致大文件上传静默失败。"
        case .memoryLimitBelowPostLimit: "memory_limit 必须不小于 post_max_size，否则接收大请求体时会耗尽内存。"
        case .invalidTimezone: "PHP 时区标识符无效，例如应写成 Asia/Shanghai。留空表示跟随系统。"
        case .invalidOptionalApacheModule: "可选 Apache 模块名不在允许列表内，或存在重复项。"
        }
    }
}

public struct WorkspaceSettings: Codable, Equatable, Sendable {
    public var schemaVersion = 2
    public var preferences = Preferences()
    public var websites: [Website] = []
    public init() {}
    public mutating func addWebsite(at url: URL, publicRoot: URL? = nil, port: Int? = nil) throws {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        guard !websites.contains(where: { $0.rootPath == canonical.path }) else {
            throw SettingsError.duplicateWebsite
        }
        let chosenPublicRoot = (publicRoot ?? canonical).standardizedFileURL.resolvingSymlinksInPath()
        websites.append(Website(
            name: canonical.lastPathComponent,
            rootPath: canonical.path,
            publicRootPath: chosenPublicRoot.path,
            port: port ?? nextWebsitePort()
        ))
        try validate()
    }

    public mutating func migrateFromVersion1() throws {
        guard schemaVersion == 1 else { return }
        var used = Set([preferences.httpPort, preferences.databasePort, preferences.httpsPort])
        for index in websites.indices {
            websites[index].publicRootPath = websites[index].publicRootPath.isEmpty
                ? websites[index].rootPath
                : websites[index].publicRootPath
            if websites[index].port < 1024 || used.contains(websites[index].port) {
                var candidate = 8081
                while used.contains(candidate) { candidate += 1 }
                websites[index].port = candidate
            }
            used.insert(websites[index].port)
        }
        schemaVersion = 2
        try validate()
    }

    public func validate() throws {
        try preferences.validate()
        var ports = Set<Int>()
        var roots = Set<String>()
        var hostnames = Set<String>()
        for website in websites {
            let name = website.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !website.name.contains("\0"), !website.name.contains("\n"), !website.name.contains("\r") else {
                throw SettingsError.invalidWebsiteName
            }
            guard (1024...65535).contains(website.port),
                  website.port != preferences.httpPort,
                  website.port != preferences.databasePort,
                  website.port != preferences.httpsPort else {
                throw SettingsError.invalidWebsitePort(website.name)
            }
            guard ports.insert(website.port).inserted else {
                throw SettingsError.duplicateWebsitePort(website.port)
            }
            let root = URL(fileURLWithPath: website.rootPath).standardizedFileURL.path
            guard roots.insert(root).inserted else { throw SettingsError.duplicateWebsite }
            if !website.hostname.isEmpty, !hostnames.insert(website.hostname).inserted {
                throw SettingsError.duplicateHostname(website.hostname)
            }
        }
    }

    public func nextWebsitePort(startingAt: Int = 8081) -> Int {
        let used = Set(websites.map(\.port) + [preferences.httpPort, preferences.databasePort, preferences.httpsPort])
        var candidate = max(1024, startingAt)
        while used.contains(candidate), candidate < 65535 { candidate += 1 }
        return candidate
    }
}
