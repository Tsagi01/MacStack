import Foundation

public struct CommandOutput: Sendable {
    public let status: Int32
    /// 标准输出与标准错误的**合并**内容。
    ///
    /// 这里刻意不分成两个字段：`FoundationCommandRunner` 把两个流接到同一个 pipe，
    /// 目的是避免「只读一个 pipe、另一个写满缓冲区」导致的父子进程互相等待。
    /// 之前保留过一个恒为空字符串的 `standardError` 字段，调用方写
    /// `standardOutput + standardError` 看着像在拼接，实际是无效操作，
    /// 因此改成如实的名字并删掉那个字段。
    public let combinedOutput: String
}

public enum WebStackError: Error, LocalizedError {
    case missingExecutable(String)
    case incompatibleExecutable(String)
    case commandFailed(String, Int32, String)
    case unsafePath(String)
    case socketPathTooLong(String)
    case invalidWebsite(String)
    case missingApacheModule(String)
    case missingTypesConfig(String)

    public var errorDescription: String? {
        switch self {
        case .missingExecutable(let path): "缺少可执行文件：\(path)"
        case .incompatibleExecutable(let path): "可执行文件不包含 ARM64：\(path)"
        case .commandFailed(let command, let status, let output):
            "命令校验失败（退出码 \(status)）：\(command)\n\(output)"
        case .unsafePath(let path): "路径含有配置文件无法安全表示的换行或空字符：\(path)"
        case .socketPathTooLong(let path): "PHP-FPM socket 路径过长：\(path)"
        case .invalidWebsite(let detail): "网站配置无效：\(detail)"
        case .missingApacheModule(let path):
            "缺少 Apache 模块：\(path)\n这个模块是当前 `.htaccess` 覆盖设置的必需项，缺失会让站点返回 HTTP 500，因此不静默跳过。"
        case .missingTypesConfig(let path):
            "找不到 Apache 的 mime.types：\(path)。便携运行时应在 apache/etc/httpd/mime.types 提供自己的副本。"
        }
    }
}

public struct FoundationCommandRunner: Sendable {
    public init() {}

    @discardableResult
    public func run(
        executable: URL,
        arguments: [String],
        standardInput: Data? = nil,
        environment: [String: String]? = nil
    ) throws -> CommandOutput {
        let process = Process()
        let combined = Pipe()
        let input = standardInput.map { _ in Pipe() }
        process.executableURL = executable
        process.arguments = arguments
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        process.standardOutput = combined
        process.standardError = combined
        process.standardInput = input
        try process.run()
        if let standardInput, let input {
            input.fileHandleForWriting.write(standardInput)
            try? input.fileHandleForWriting.close()
        }
        // 先持续读取再等待，避免输出超过管道缓冲区时子进程与父进程互相等待。
        let data = combined.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandOutput(
            status: process.terminationStatus,
            combinedOutput: String(decoding: data, as: UTF8.self)
        )
    }
}

public struct InstalledWebStack: Equatable, Sendable {
    public let apache: URL
    public let php: URL
    public let phpFPM: URL
    public let apacheVersion: String
    public let phpVersion: String
    public let phpRoot: URL?
    public let phpExtensionDirectory: URL?
    public let isBundled: Bool

    public init(
        apache: URL,
        php: URL,
        phpFPM: URL,
        apacheVersion: String,
        phpVersion: String,
        phpRoot: URL? = nil,
        phpExtensionDirectory: URL? = nil,
        isBundled: Bool = false
    ) {
        self.apache = apache
        self.php = php
        self.phpFPM = phpFPM
        self.apacheVersion = apacheVersion
        self.phpVersion = phpVersion
        self.phpRoot = phpRoot
        self.phpExtensionDirectory = phpExtensionDirectory
        self.isBundled = isBundled
    }
}

public struct WebStackResolver: Sendable {
    public let prefix: URL
    public let preferredFormula: String
    public let portableRuntimeRoot: URL?
    private let runner = FoundationCommandRunner()

    public init(
        prefix: URL = URL(fileURLWithPath: "/opt/homebrew"),
        preferredFormula: String = "auto",
        portableRuntimeRoot: URL? = nil
    ) {
        self.prefix = prefix
        self.preferredFormula = preferredFormula
        self.portableRuntimeRoot = portableRuntimeRoot
    }

    public func resolve() throws -> InstalledWebStack {
        if let runtime = try PortableRuntimeLocator(explicitRoot: portableRuntimeRoot).locate(),
           preferredFormula == "auto" || preferredFormula == runtime.manifest.phpFormula {
            try requireNative(runtime.layout.apache)
            try requireNative(runtime.layout.php)
            try requireNative(runtime.layout.phpFPM)
            return InstalledWebStack(
                apache: runtime.layout.apache,
                php: runtime.layout.php,
                phpFPM: runtime.layout.phpFPM,
                apacheVersion: "Apache/\(runtime.manifest.apacheVersion) (MacStack runtime)",
                phpVersion: "PHP \(runtime.manifest.phpVersion) (MacStack runtime)",
                phpRoot: runtime.layout.phpRoot,
                phpExtensionDirectory: runtime.layout.phpExtensionDirectory(api: runtime.manifest.phpAPI),
                isBundled: true
            )
        }
        let apache = prefix.appendingPathComponent("opt/httpd/bin/httpd").resolvingSymlinksInPath()
        let defaults = ["php@8.2", "php@8.3", "php@8.4", "php@8.5", "php"]
        let phpRoots = preferredFormula == "auto" ? defaults : [preferredFormula]
        try requireNative(apache)

        var chosenPHP: (URL, URL)?
        for name in phpRoots {
            let php = prefix.appendingPathComponent("opt/\(name)/bin/php").resolvingSymlinksInPath()
            let fpm = prefix.appendingPathComponent("opt/\(name)/sbin/php-fpm").resolvingSymlinksInPath()
            guard FileManager.default.isExecutableFile(atPath: php.path),
                  FileManager.default.isExecutableFile(atPath: fpm.path) else { continue }
            guard isNative(php), isNative(fpm) else { continue }
            chosenPHP = (php, fpm)
            break
        }
        guard let chosenPHP else {
            throw WebStackError.missingExecutable(prefix.appendingPathComponent("opt/php@8.2/bin/php").path)
        }

        let apacheOutput = try checked(apache, ["-v"])
        let phpOutput = try checked(chosenPHP.0, ["-v"])
        return InstalledWebStack(
            apache: apache,
            php: chosenPHP.0,
            phpFPM: chosenPHP.1,
            apacheVersion: VersionText.firstLine(apacheOutput),
            phpVersion: VersionText.firstLine(phpOutput)
        )
    }

    private func requireNative(_ url: URL) throws {
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw WebStackError.missingExecutable(url.path)
        }
        guard isNative(url) else { throw WebStackError.incompatibleExecutable(url.path) }
    }

    private func isNative(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096) else { return false }
        return MachOHeader.containsARM64(data)
    }

    private func checked(_ executable: URL, _ arguments: [String]) throws -> String {
        let result = try runner.run(executable: executable, arguments: arguments)
        let combined = result.combinedOutput
        guard result.status == 0 else {
            throw WebStackError.commandFailed(([executable.path] + arguments).joined(separator: " "), result.status, combined)
        }
        return combined
    }
}

public enum VersionText {
    public static func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "版本未知"
    }
}

public struct RuntimeLayout: Equatable, Sendable {
    public let root: URL
    public var configurationDirectory: URL { root.appendingPathComponent("config", isDirectory: true) }
    public var logDirectory: URL { root.appendingPathComponent("logs", isDirectory: true) }
    public var runDirectory: URL { root.appendingPathComponent("run", isDirectory: true) }
    public var documentRoot: URL { root.appendingPathComponent("www", isDirectory: true) }
    public var healthDirectory: URL { root.appendingPathComponent("health", isDirectory: true) }
    public var healthScript: URL { healthDirectory.appendingPathComponent("health.php") }
    public var apacheConfiguration: URL { configurationDirectory.appendingPathComponent("httpd.conf") }
    public var phpFPMConfiguration: URL { configurationDirectory.appendingPathComponent("php-fpm.conf") }
    public var phpConfiguration: URL { configurationDirectory.appendingPathComponent("php.ini") }
    public var phpExtensionConfigurationDirectory: URL { configurationDirectory.appendingPathComponent("php.d", isDirectory: true) }
    public var phpExtensionConfiguration: URL { phpExtensionConfigurationDirectory.appendingPathComponent("50-macstack-extensions.ini") }
    public var phpExtensionBackupDirectory: URL { configurationDirectory.appendingPathComponent("php-extension-backups", isDirectory: true) }
    public var phpSocket: URL { runDirectory.appendingPathComponent("php-fpm.sock") }
    public var apachePID: URL { runDirectory.appendingPathComponent("httpd.pid") }
    public var phpPID: URL { runDirectory.appendingPathComponent("php-fpm.pid") }
    public var databaseDirectory: URL { root.appendingPathComponent("mariadb-data", isDirectory: true) }
    public var databaseConfiguration: URL { configurationDirectory.appendingPathComponent("mariadb.cnf") }
    public var databaseSocket: URL { runDirectory.appendingPathComponent("mariadb.sock") }
    public var databasePID: URL { runDirectory.appendingPathComponent("mariadb.pid") }
    public var phpMyAdminDirectory: URL { root.appendingPathComponent("phpmyadmin", isDirectory: true) }
    public var phpMyAdminTempDirectory: URL { root.appendingPathComponent("phpmyadmin-tmp", isDirectory: true) }
    public var phpMyAdminSecret: URL { configurationDirectory.appendingPathComponent("phpmyadmin-secret.hex") }
    public var tlsDirectory: URL { root.appendingPathComponent("tls", isDirectory: true) }
    public var tlsCertificate: URL { tlsDirectory.appendingPathComponent("localhost.crt") }
    public var tlsPrivateKey: URL { tlsDirectory.appendingPathComponent("localhost.key") }
    public var tlsHostsMarker: URL { tlsDirectory.appendingPathComponent("hosts.txt") }

    public init(root: URL) { self.root = root.standardizedFileURL }

    public static func applicationSupport(fileManager: FileManager = .default) -> RuntimeLayout {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return RuntimeLayout(root: base.appendingPathComponent("MacStack/runtime", isDirectory: true))
    }
}

public struct WebStackConfiguration: Equatable, Sendable {
    public let apache: String
    public let phpFPM: String
    public let php: String
}

/// Apache 模块加载计划。
///
/// 关键约束：`AllowOverride` 的每个覆盖类都需要对应模块已加载，否则 `.htaccess`
/// 里的指令会让站点返回 HTTP 500。授予覆盖类却不加载模块，等于把 500 埋进用户站点。
/// 因此必需模块集是由覆盖类反推出来的，两者必须一起改。
public enum ApacheModulePlan {
    /// 始终加载的基础模块。
    ///
    /// 抽成常量而不是散在模板里，是为了让 `.htaccess` 预检能准确知道
    /// 「哪些模块已经加载」，避免把不会报错的指令误判成问题。
    public static let baseModules = [
        "mpm_event", "unixd", "alias", "authz_core", "authz_host", "dir", "mime",
        "proxy", "proxy_fcgi", "log_config"
    ]

    /// 放开 `.htaccess` 所必需的模块。
    ///
    /// 对应 `AllowOverride FileInfo Indexes AuthConfig Limit`：
    /// - `FileInfo` → rewrite（RewriteRule）、headers（Header）、setenvif（SetEnvIf）
    /// - `AuthConfig` → authn_file（AuthUserFile）、auth_basic（AuthBasicProvider）、
    ///   authz_user / authz_groupfile（Require user/group）
    /// - `Limit` → access_compat（Order/Allow/Deny 的 2.2 兼容写法）
    /// - `Indexes` → 只需要已加载的 `dir`（DirectoryIndex），**不需要 autoindex**
    public static let requiredForHtaccess = [
        "rewrite", "headers", "setenvif",
        "authn_file", "auth_basic", "authz_user", "authz_groupfile",
        "access_compat"
    ]

    /// 可选模块的前置依赖。deflate 需要 filter 才能挂上过滤器链。
    public static let optionalDependencies: [String: [String]] = [
        "deflate": ["filter"],
        "expires": [],
        "autoindex": []
    ]

    /// 计算实际要加载的模块名列表（已去重、依赖在前）。
    public static func modulesToLoad(for preferences: Preferences) -> [String] {
        var ordered: [String] = []
        func append(_ name: String) {
            if !ordered.contains(name) { ordered.append(name) }
        }
        if preferences.allowHtaccess {
            requiredForHtaccess.forEach(append)
        }
        for module in preferences.optionalApacheModules {
            (optionalDependencies[module] ?? []).forEach(append)
            append(module)
        }
        return ordered
    }

    /// 给定偏好下实际会加载的全部模块名。
    public static func loadedModules(for preferences: Preferences) -> Set<String> {
        var names = Set(baseModules)
        if preferences.httpsEnabled { names.formUnion(["socache_shmcb", "ssl"]) }
        if preferences.perlCGIEnabled { names.insert("cgid") }
        names.formUnion(modulesToLoad(for: preferences))
        return names
    }

    /// 指令名 → 提供它的模块。用于预检判断「这条指令会不会因为模块没加载而 500」。
    ///
    /// 只登记**由可选模块提供**的指令；基础模块提供的指令（如 `Require` 来自
    /// 已加载的 authz_core）不在此列，避免误报。
    public static let directiveProviders: [String: String] = [
        "ExpiresActive": "expires", "ExpiresDefault": "expires", "ExpiresByType": "expires",
        "AddOutputFilterByType": "deflate", "DeflateFilterNote": "deflate",
        "SetOutputFilter": "filter", "AddOutputFilter": "filter",
        "IndexOptions": "autoindex", "AddIcon": "autoindex", "AddIconByType": "autoindex",
        "AddIconByEncoding": "autoindex", "HeaderName": "autoindex", "ReadmeName": "autoindex"
    ]
}

public struct WebStackConfigurationGenerator: Sendable {
    /// 站点目录（含默认站点 `www`）的 Options。
    ///
    /// `-FollowSymLinks` 必须显式写出：Apache 手册明确说明 `FollowSymLinks`
    /// **就是默认值**，而带 `+`/`-` 前缀的 Options 是「合并到当前生效的选项集」。
    /// 只写 `+SymLinksIfOwnerMatch` 会让继承来的默认 `FollowSymLinks` 继续生效，
    /// 实际效果比预期宽松得多。
    ///
    /// 同时 `SymLinksIfOwnerMatch` 是 mod_rewrite 在目录级上下文工作的前提
    /// （官方文档：per-directory 重写要求 `FollowSymLinks` 或
    /// `SymLinksIfOwnerMatch` 至少启用一个）。
    ///
    /// 注意这两个选项在官方手册里都注明「不应视为安全限制」，因为符号链接检查
    /// 存在竞态；这里只是满足重写的启用条件，不是加固手段。
    static let siteOptions = "-Indexes -FollowSymLinks +SymLinksIfOwnerMatch"

    /// MacStack 自有目录（内部健康检查、phpMyAdmin）的 Options。
    /// 它们不参与目录级重写，因此不需要符号链接选项。
    static let managedOptions = "-Indexes -FollowSymLinks"

    public init() {}

    public func generate(
        installation: InstalledWebStack,
        preferences: Preferences,
        documentRoot: URL,
        layout: RuntimeLayout,
        phpMyAdminRoot: URL? = nil,
        websites: [Website] = [],
        tlsCertificate: TLSCertificate? = nil
    ) throws -> WebStackConfiguration {
        try preferences.validate()
        var configuredPorts = Set([preferences.httpPort, preferences.databasePort, preferences.httpsPort])
        for website in websites where website.isEnabled {
            do { try WebsiteHostingValidator().validate(website) }
            catch { throw WebStackError.invalidWebsite(error.localizedDescription) }
            guard configuredPorts.insert(website.port).inserted else {
                throw WebStackError.invalidWebsite("端口 \(website.port) 重复。")
            }
        }
        let paths = [documentRoot, layout.root, layout.phpSocket]
        for url in paths { try validate(url.path) }
        guard layout.phpSocket.path.utf8.count < 100 else {
            throw WebStackError.socketPathTooLong(layout.phpSocket.path)
        }

        let serverRoot = installation.apache.deletingLastPathComponent().deletingLastPathComponent()
        let moduleRoot = serverRoot.appendingPathComponent("lib/httpd/modules")
        let root = quote(documentRoot.path)
        let socket = quote(layout.phpSocket.path)
        let logs = quote(layout.logDirectory.path)
        let run = quote(layout.runDirectory.path)
        let healthDirectory = quote(layout.healthDirectory.path)
        let healthScript = quote(layout.healthScript.path)
        let modules = quote(moduleRoot.path)
        let allowOverride = preferences.allowOverrideValue
        let baseModuleLines = ApacheModulePlan.baseModules
            .map { "LoadModule \($0)_module \"\(modules)/mod_\($0).so\"" }
            .joined(separator: "\n")

        // 按需加载模块。缺失即报错——授予了覆盖类却没有对应模块，站点会返回 500，
        // 静默跳过只会把问题推给用户。
        let extraModuleLines = try ApacheModulePlan.modulesToLoad(for: preferences).map { name -> String in
            let file = moduleRoot.appendingPathComponent("mod_\(name).so")
            guard FileManager.default.fileExists(atPath: file.path) else {
                throw WebStackError.missingApacheModule(file.path)
            }
            return "LoadModule \(name)_module \"\(quote(file.path))\""
        }.joined(separator: "\n")
        let typesConfig = try resolveTypesConfig(serverRoot: serverRoot)
        let phpMyAdminBlock: String
        if let phpMyAdminRoot {
            try validate(phpMyAdminRoot.path)
            let phpMyAdmin = quote(phpMyAdminRoot.path)
            phpMyAdminBlock = """

            Alias "/phpmyadmin" "\(phpMyAdmin)"
            <Directory "\(phpMyAdmin)">
                Options \(Self.managedOptions)
                AllowOverride None
                Require local
            </Directory>
            """
        } else {
            phpMyAdminBlock = ""
        }
        let cgiModule = preferences.perlCGIEnabled
            ? "LoadModule cgid_module \"\(modules)/mod_cgid.so\"\nScriptSock \"\(run)/cgisock\""
            : ""
        func cgiBlock(for siteRoot: String) -> String {
            guard preferences.perlCGIEnabled else { return "" }
            return """
            ScriptAlias "/cgi-bin/" "\(siteRoot)/cgi-bin/"
            <Directory "\(siteRoot)/cgi-bin">
                Options +ExecCGI -Indexes -FollowSymLinks
                AllowOverride None
                AddHandler cgi-script .cgi .pl
                Require all granted
            </Directory>
            """
        }
        let siteBlocks = try websites.filter(\.isEnabled).map { website -> String in
            try validate(website.publicRootPath)
            let siteRoot = quote(website.publicRootPath)
            let identifier = website.id.uuidString.lowercased()
            let serverName = website.hostname.isEmpty ? "127.0.0.1" : website.hostname
            return """

            Listen 127.0.0.1:\(website.port)
            <VirtualHost 127.0.0.1:\(website.port)>
                ServerName \(serverName)
                DocumentRoot "\(siteRoot)"
                DirectoryIndex index.php index.html
                ErrorLog "\(logs)/site-\(identifier)-error.log"
                CustomLog "\(logs)/site-\(identifier)-access.log" combined

                <Directory "\(siteRoot)">
                    Options \(Self.siteOptions)
                    AllowOverride \(allowOverride)
                    Require all granted
                </Directory>

                <FilesMatch "^\\.">
                    Require all denied
                </FilesMatch>

                <DirectoryMatch "(^|/)\\.">
                    Require all denied
                </DirectoryMatch>

                <FilesMatch "\\.php$">
                    SetHandler "proxy:unix:\(socket)|fcgi://localhost/"
                </FilesMatch>
                \(cgiBlock(for: siteRoot))
            </VirtualHost>
            """
        }.joined(separator: "\n")

        let tlsModules = tlsCertificate == nil ? "" : """
        LoadModule socache_shmcb_module "\(modules)/mod_socache_shmcb.so"
        LoadModule ssl_module "\(modules)/mod_ssl.so"
        """
        let tlsBlock: String
        if let tlsCertificate {
            let certificate = quote(tlsCertificate.certificate.path)
            let privateKey = quote(tlsCertificate.privateKey.path)
            let secureSites = try websites.filter { $0.isEnabled && !$0.hostname.isEmpty }.map { website -> String in
                try validate(website.publicRootPath)
                let siteRoot = quote(website.publicRootPath)
                let identifier = website.id.uuidString.lowercased()
                return """

                <VirtualHost 127.0.0.1:\(preferences.httpsPort)>
                    ServerName \(website.hostname)
                    DocumentRoot "\(siteRoot)"
                    DirectoryIndex index.php index.html
                    SSLEngine on
                    SSLCertificateFile "\(certificate)"
                    SSLCertificateKeyFile "\(privateKey)"
                    ErrorLog "\(logs)/site-\(identifier)-ssl-error.log"
                    CustomLog "\(logs)/site-\(identifier)-ssl-access.log" combined
                    <Directory "\(siteRoot)">
                        Options \(Self.siteOptions)
                        AllowOverride \(allowOverride)
                        Require all granted
                    </Directory>
                    <FilesMatch "^\\.">
                        Require all denied
                    </FilesMatch>
                    <DirectoryMatch "(^|/)\\.">
                        Require all denied
                    </DirectoryMatch>
                    <FilesMatch "\\.php$">
                        SetHandler "proxy:unix:\(socket)|fcgi://localhost/"
                    </FilesMatch>
                    \(cgiBlock(for: siteRoot))
                </VirtualHost>
                """
            }.joined(separator: "\n")
            tlsBlock = """

            Listen 127.0.0.1:\(preferences.httpsPort)
            SSLSessionCache "shmcb:\(run)/ssl_scache(512000)"
            <VirtualHost 127.0.0.1:\(preferences.httpsPort)>
                ServerName localhost
                DocumentRoot "\(root)"
                DirectoryIndex index.php index.html
                SSLEngine on
                SSLCertificateFile "\(certificate)"
                SSLCertificateKeyFile "\(privateKey)"
                <Directory "\(root)">
                    Options \(Self.siteOptions)
                    AllowOverride \(allowOverride)
                    Require all granted
                </Directory>
                <FilesMatch "\\.php$">
                    SetHandler "proxy:unix:\(socket)|fcgi://localhost/"
                </FilesMatch>
                \(cgiBlock(for: root))
                \(phpMyAdminBlock)
            </VirtualHost>
            \(secureSites)
            """
        } else {
            tlsBlock = ""
        }

        let apache = """
        ServerRoot "\(quote(serverRoot.path))"
        ServerName 127.0.0.1
        Listen 127.0.0.1:\(preferences.httpPort)
        PidFile "\(run)/httpd.pid"
        ErrorLog "\(logs)/apache-error.log"
        LogLevel warn

        \(baseModuleLines)
        \(extraModuleLines)
        \(tlsModules)
        \(cgiModule)

        TypesConfig "\(quote(typesConfig))"

        <VirtualHost 127.0.0.1:\(preferences.httpPort)>
            ServerName 127.0.0.1
            DocumentRoot "\(root)"
            DirectoryIndex index.php index.html
            CustomLog "\(logs)/apache-access.log" combined

            Alias "/__macstack/health.php" "\(healthScript)"
            <Directory "\(healthDirectory)">
                Options \(Self.managedOptions)
                AllowOverride None
                Require local
            </Directory>

            <Directory "\(root)">
                Options \(Self.siteOptions)
                AllowOverride \(allowOverride)
                Require all granted
            </Directory>

            <FilesMatch "^\\.">
                Require all denied
            </FilesMatch>

            <DirectoryMatch "(^|/)\\.">
                Require all denied
            </DirectoryMatch>

            <FilesMatch "\\.php$">
                SetHandler "proxy:unix:\(socket)|fcgi://localhost/"
            </FilesMatch>
            \(cgiBlock(for: root))
            \(phpMyAdminBlock)
        </VirtualHost>
        \(siteBlocks)
        \(tlsBlock)
        """

        let phpFPM = """
        [global]
        pid = \(run)/php-fpm.pid
        error_log = \(logs)/php-fpm-error.log
        daemonize = no

        [macstack]
        listen = \(socket)
        listen.mode = 0600
        pm = ondemand
        pm.max_children = 8
        pm.process_idle_timeout = 10s
        pm.max_requests = 500
        catch_workers_output = yes
        clear_env = no
        security.limit_extensions = .php
        """

        let php = """
        display_errors = On
        display_startup_errors = On
        error_reporting = E_ALL
        log_errors = On
        error_log = "\(logs)/php-error.log"
        date.timezone = \(preferences.resolvedTimezone)
        expose_php = Off
        memory_limit = \(preferences.memoryLimitMB)M
        upload_max_filesize = \(preferences.uploadMaxFilesizeMB)M
        post_max_size = \(preferences.postMaxSizeMB)M
        max_execution_time = 120
        max_input_time = 120
        max_input_vars = 5000
        \(installation.phpExtensionDirectory.map { "extension_dir = \"\(quote($0.path))\"" } ?? "")
        """
        return WebStackConfiguration(apache: apache + "\n", phpFPM: phpFPM + "\n", php: php + "\n")
    }

    /// 解析 `TypesConfig` 指向的 mime.types。
    ///
    /// 优先使用便携运行时自带的副本：写死系统路径 `/etc/apache2/mime.types` 与
    /// 「核心运行时不依赖系统组件」的定位矛盾，而且在没有系统 Apache 的机器上会失败。
    private func resolveTypesConfig(serverRoot: URL) throws -> String {
        let bundled = serverRoot.appendingPathComponent("etc/httpd/mime.types")
        if FileManager.default.fileExists(atPath: bundled.path) { return bundled.path }
        let system = "/etc/apache2/mime.types"
        if FileManager.default.fileExists(atPath: system) { return system }
        throw WebStackError.missingTypesConfig(bundled.path)
    }

    private func validate(_ value: String) throws {
        if value.contains("\n") || value.contains("\r") || value.contains("\0") {
            throw WebStackError.unsafePath(value)
        }
    }

    private func quote(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

public struct PreparedWebStack: Sendable {
    public let installation: InstalledWebStack
    public let layout: RuntimeLayout
    public let documentRoot: URL
    /// `.htaccess` 预检结果。阻塞项在 prepare 阶段就会抛错，因此这里只可能带
    /// 非阻塞的提示（模块未加载、被 `<IfModule>` 跳过的 PHP 指令）。
    public let htaccessReport: HtaccessPreflightReport

    public init(
        installation: InstalledWebStack,
        layout: RuntimeLayout,
        documentRoot: URL,
        htaccessReport: HtaccessPreflightReport = HtaccessPreflightReport(findings: [], scannedFileCount: 0)
    ) {
        self.installation = installation
        self.layout = layout
        self.documentRoot = documentRoot
        self.htaccessReport = htaccessReport
    }
}

public struct WebStackPreparer: Sendable {
    private let runner = FoundationCommandRunner()
    public init() {}

    public func prepare(
        installation: InstalledWebStack,
        preferences: Preferences,
        documentRoot: URL? = nil,
        layout: RuntimeLayout = .applicationSupport(),
        websites: [Website] = []
    ) throws -> PreparedWebStack {
        let files = FileManager.default
        let chosenRoot = (documentRoot ?? layout.documentRoot).standardizedFileURL
        for directory in [layout.configurationDirectory, layout.logDirectory, layout.runDirectory, layout.healthDirectory, chosenRoot] {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        // 只轮转 Web 自己的日志。日志目录是与数据库共享的，准备 Web 配置时数据库
        // 可能正在运行；轮转整个目录会动到它仍持有写入句柄的 mariadb-launcher.log。
        _ = try LogMaintainer().rotate(directory: layout.logDirectory, prefixes: LogOwnership.web)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: layout.runDirectory.path)

        // `.htaccess` 预检。阻塞项直接拒绝，避免生成一份必然返回 500 的配置——
        // 静态预检负责提前拦截，运行时的 500 检测只是兜底。
        let htaccessReport = scanHtaccess(preferences: preferences, websites: websites, defaultRoot: chosenRoot)
        if htaccessReport.hasBlockingFinding {
            throw WebStackError.invalidWebsite(
                htaccessReport.summary ?? "站点 .htaccess 含当前 PHP 运行方式不支持的指令。"
            )
        }

        let tls = preferences.httpsEnabled
            ? try TLSCertificateManager().prepare(hostnames: websites.map(\.hostname).filter { !$0.isEmpty }, layout: layout)
            : nil
        let configuration = try WebStackConfigurationGenerator().generate(
            installation: installation,
            preferences: preferences,
            documentRoot: chosenRoot,
            layout: layout,
            phpMyAdminRoot: files.fileExists(atPath: layout.phpMyAdminDirectory.appendingPathComponent("index.php").path)
                ? layout.phpMyAdminDirectory
                : nil,
            websites: websites,
            tlsCertificate: tls
        )

        let index = chosenRoot.appendingPathComponent("index.php")
        if !files.fileExists(atPath: index.path) {
            let body = "<?php header('Content-Type: text/plain; charset=utf-8'); echo \"MacStack PHP OK\\n\" . PHP_VERSION . \"\\n\";"
            try Data(body.utf8).write(to: index, options: .atomic)
        }
        let healthBody = "<?php header('Content-Type: text/plain; charset=utf-8'); echo \"MacStack Internal Health OK\\n\" . PHP_VERSION . \"\\n\";"
        try Data(healthBody.utf8).write(to: layout.healthScript, options: .atomic)

        let candidateID = UUID().uuidString.lowercased()
        let candidateApache = layout.configurationDirectory.appendingPathComponent("httpd-\(candidateID).conf")
        let candidatePHPFPM = layout.configurationDirectory.appendingPathComponent("php-fpm-\(candidateID).conf")
        let candidatePHP = layout.configurationDirectory.appendingPathComponent("php-\(candidateID).ini")
        defer {
            for url in [candidateApache, candidatePHPFPM, candidatePHP] { try? files.removeItem(at: url) }
        }
        try Data(configuration.apache.utf8).write(to: candidateApache, options: .atomic)
        try Data(configuration.phpFPM.utf8).write(to: candidatePHPFPM, options: .atomic)
        try Data(configuration.php.utf8).write(to: candidatePHP, options: .atomic)
        try check(installation.apache, ["-t", "-f", candidateApache.path])
        try check(
            installation.phpFPM,
            ["--test", "--fpm-config", candidatePHPFPM.path, "--php-ini", candidatePHP.path],
            environment: ["PHP_INI_SCAN_DIR": layout.phpExtensionConfigurationDirectory.path]
        )
        try PHPExtensionManager(installation: installation, layout: layout).ensureConfiguration()
        try Data(configuration.apache.utf8).write(to: layout.apacheConfiguration, options: .atomic)
        try Data(configuration.phpFPM.utf8).write(to: layout.phpFPMConfiguration, options: .atomic)
        try Data(configuration.php.utf8).write(to: layout.phpConfiguration, options: .atomic)
        return PreparedWebStack(
            installation: installation,
            layout: layout,
            documentRoot: chosenRoot,
            htaccessReport: htaccessReport
        )
    }

    /// 扫描默认站点与所有已启用站点的 `.htaccess`。
    ///
    /// 默认站点 `www` 与登记网站同等对待——它就是 XAMPP `htdocs` 的对应目录，
    /// 只处理登记网站会让默认站点仍不兼容。
    private func scanHtaccess(
        preferences: Preferences,
        websites: [Website],
        defaultRoot: URL
    ) -> HtaccessPreflightReport {
        let loadedModules = ApacheModulePlan.loadedModules(for: preferences)
        var roots: [URL] = websites.filter(\.isEnabled).map {
            URL(fileURLWithPath: $0.publicRootPath).standardizedFileURL
        }
        let defaultRootStandardized = defaultRoot.standardizedFileURL
        if !roots.contains(where: { $0.path == defaultRootStandardized.path }) {
            roots.append(defaultRootStandardized)
        }

        let preflight = HtaccessPreflight()
        var findings: [HtaccessFinding] = []
        var scanned = 0
        for root in roots {
            let report = preflight.scan(
                publicRoot: root,
                loadedModules: loadedModules,
                allowsOptionsOverride: preferences.allowHtaccessOptions
            )
            findings.append(contentsOf: report.findings)
            scanned += report.scannedFileCount
        }
        return HtaccessPreflightReport(findings: findings, scannedFileCount: scanned)
    }

    private func check(_ executable: URL, _ arguments: [String], environment: [String: String]? = nil) throws {
        let output = try runner.run(executable: executable, arguments: arguments, environment: environment)
        guard output.status == 0 else {
            let combined = output.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            throw WebStackError.commandFailed(([executable.path] + arguments).joined(separator: " "), output.status, combined)
        }
    }
}
