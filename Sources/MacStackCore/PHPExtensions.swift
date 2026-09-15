import Foundation

public enum PHPExtensionStatus: String, Sendable {
    case enabled = "已启用"
    case disabled = "已安装，未启用"
    case notInstalled = "未安装"
    case incompatible = "不兼容 ARM64"
}

public struct PHPExtensionInfo: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    public let title: String
    public let purpose: String
    public let status: PHPExtensionStatus
    public let libraryPath: String?
    public let canInstall: Bool
}

public struct PHPExtensionReport: Equatable, Sendable {
    public let phpVersion: String
    public let builtInModules: [String]
    public let extensions: [PHPExtensionInfo]
    public let configurationPath: String
    public let backupDirectoryPath: String
}

public struct PHPExtensionConfigurationChange: Sendable {
    public let previousData: Data?
    public let backupURL: URL?
}

public enum PHPExtensionError: Error, LocalizedError {
    case invalidName(String)
    case notInstalled(String)
    case notInstallable(String)
    case incompatible(String)
    case missingPECL(String)
    case missingHomebrew
    case commandFailed(String, Int32, String)
    case validationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName(let name): "PHP 扩展名称无效：\(name)"
        case .notInstalled(let name): "PHP 扩展 \(name) 尚未安装。"
        case .notInstallable(let name): "MacStack 没有为 \(name) 提供安全的一键安装方案；仍可在外部安装后回到这里启用。"
        case .incompatible(let path): "扩展不包含 ARM64，拒绝加载：\(path)"
        case .missingPECL(let path): "当前 PHP 没有可用的 PECL：\(path)"
        case .missingHomebrew: "没有找到 Apple Silicon Homebrew（/opt/homebrew/bin/brew）。"
        case .commandFailed(let command, let status, let output):
            "PHP 扩展命令失败（退出码 \(status)）：\(command)\n\(output)"
        case .validationFailed(let detail): "新扩展配置未通过 PHP 加载校验，原配置保持不变：\n\(detail)"
        }
    }
}

public struct PHPExtensionManager: Sendable {
    private struct CatalogEntry: Sendable {
        let title: String
        let purpose: String
        let peclPackage: String
        let brewDependencies: [String]
    }

    private static let catalog: [String: CatalogEntry] = [
        "xdebug": CatalogEntry(
            title: "Xdebug",
            purpose: "断点调试、调用栈与更清晰的开发错误信息",
            peclPackage: "xdebug",
            brewDependencies: []
        ),
        "imagick": CatalogEntry(
            title: "ImageMagick",
            purpose: "缩放、裁剪、转换等高级图片处理",
            peclPackage: "imagick",
            brewDependencies: ["imagemagick"]
        ),
        "redis": CatalogEntry(
            title: "Redis",
            purpose: "让 PHP 连接 Redis 缓存与会话存储",
            peclPackage: "redis",
            brewDependencies: []
        )
    ]

    public let installation: InstalledWebStack
    public let layout: RuntimeLayout
    private let runner = FoundationCommandRunner()
    private var files: FileManager { .default }

    public init(installation: InstalledWebStack, layout: RuntimeLayout = .applicationSupport()) {
        self.installation = installation
        self.layout = layout
    }

    /// Creates a private scan directory on first use. Existing Homebrew dynamic
    /// modules are copied into MacStack's own selection without editing Homebrew.
    public func ensureConfiguration() throws {
        try files.createDirectory(at: layout.phpExtensionConfigurationDirectory, withIntermediateDirectories: true)
        guard !files.fileExists(atPath: layout.phpExtensionConfiguration.path) else { return }

        let builtIn = try moduleNames(arguments: ["-n", "-m"], environment: ["PHP_INI_SCAN_DIR": ""])
        let defaults = try moduleNames(arguments: ["-m"], environment: nil)
        let libraries = try extensionLibraries()
        let enabledByDefault = libraries.filter { name, _ in
            !builtIn.contains(where: { normalized($0) == normalized(name) }) && moduleIsLoaded(name, modules: defaults)
        }
        try writeConfiguration(enabledByDefault, to: layout.phpExtensionConfiguration)
    }

    public func inspect() throws -> PHPExtensionReport {
        try ensureConfiguration()
        let builtIn = try moduleNames(arguments: ["-n", "-m"], environment: ["PHP_INI_SCAN_DIR": ""])
        let managed = try moduleNames(
            arguments: phpConfigurationArguments() + ["-m"],
            environment: managedEnvironment()
        )
        let libraries = try extensionLibraries()
        let configured = try configuredNames(at: layout.phpExtensionConfiguration)
        let names = Set(Self.catalog.keys).union(libraries.keys).union(configured)
        let extensions = names.sorted().map { name -> PHPExtensionInfo in
            let library = libraries[name]
            let compatible = library.map(isARM64) ?? false
            let status: PHPExtensionStatus
            if library == nil {
                status = .notInstalled
            } else if !compatible {
                status = .incompatible
            } else if configured.contains(name) && moduleIsLoaded(name, modules: managed) {
                status = .enabled
            } else {
                status = .disabled
            }
            let entry = Self.catalog[name]
            return PHPExtensionInfo(
                name: name,
                title: entry?.title ?? name,
                purpose: entry?.purpose ?? "已在当前 PHP 扩展目录中发现的动态模块",
                status: status,
                libraryPath: library?.path,
                canInstall: entry != nil && !installation.isBundled
            )
        }
        return PHPExtensionReport(
            phpVersion: installation.phpVersion,
            builtInModules: builtIn.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending },
            extensions: extensions,
            configurationPath: layout.phpExtensionConfiguration.path,
            backupDirectoryPath: layout.phpExtensionBackupDirectory.path
        )
    }

    public func installationDescription(for name: String) throws -> String {
        guard !installation.isBundled else {
            throw PHPExtensionError.notInstallable("\(name)（便携运行时需使用经过签名的扩展包）")
        }
        let safeName = try validated(name)
        guard let entry = Self.catalog[safeName] else { throw PHPExtensionError.notInstallable(safeName) }
        var steps: [String] = []
        if !entry.brewDependencies.isEmpty {
            steps.append("Homebrew：" + entry.brewDependencies.joined(separator: "、"))
        }
        steps.append("PECL：\(entry.peclPackage)")
        return steps.joined(separator: "\n")
    }

    /// Installs only catalogued packages. It does not enable them or modify a global php.ini.
    public func install(_ name: String) throws -> String {
        guard !installation.isBundled else {
            throw PHPExtensionError.notInstallable("\(name)（便携运行时需使用经过签名的扩展包）")
        }
        let safeName = try validated(name)
        guard let entry = Self.catalog[safeName] else { throw PHPExtensionError.notInstallable(safeName) }
        if let existing = try extensionLibraries()[safeName] {
            guard isARM64(existing) else { throw PHPExtensionError.incompatible(existing.path) }
            return "扩展已经安装：\(existing.path)"
        }

        let brew = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        if !entry.brewDependencies.isEmpty {
            guard files.isExecutableFile(atPath: brew.path) else { throw PHPExtensionError.missingHomebrew }
            for formula in entry.brewDependencies {
                let present = try runner.run(executable: brew, arguments: ["list", "--versions", formula])
                if present.status != 0 {
                    let result = try runner.run(executable: brew, arguments: ["install", formula])
                    try checked(result, command: "brew install \(formula)")
                }
            }
        }

        let pecl = installation.php.deletingLastPathComponent().appendingPathComponent("pecl")
        guard files.isExecutableFile(atPath: pecl.path) else { throw PHPExtensionError.missingPECL(pecl.path) }
        let result = try runner.run(
            executable: pecl,
            arguments: ["install", entry.peclPackage],
            standardInput: Data("\n".utf8),
            environment: commandEnvironment()
        )
        try checked(result, command: "pecl install \(entry.peclPackage)")
        guard let installed = try extensionLibraries()[safeName] else {
            throw PHPExtensionError.validationFailed("PECL 已结束，但扩展目录中没有出现 \(safeName).so。")
        }
        guard isARM64(installed) else { throw PHPExtensionError.incompatible(installed.path) }
        return result.combinedOutput
    }

    /// Validates in a temporary scan directory before atomically publishing the selection.
    public func setEnabled(_ name: String, enabled: Bool) throws -> PHPExtensionConfigurationChange {
        try ensureConfiguration()
        let safeName = try validated(name)
        let libraries = try extensionLibraries()
        if enabled {
            guard let library = libraries[safeName] else { throw PHPExtensionError.notInstalled(safeName) }
            guard isARM64(library) else { throw PHPExtensionError.incompatible(library.path) }
        }

        var next = try configuredNames(at: layout.phpExtensionConfiguration)
        if enabled { next.insert(safeName) } else { next.remove(safeName) }
        let selectedLibraries = Dictionary(uniqueKeysWithValues: try next.map { selectedName in
            guard let library = libraries[selectedName] else { throw PHPExtensionError.notInstalled(selectedName) }
            guard isARM64(library) else { throw PHPExtensionError.incompatible(library.path) }
            return (selectedName, library)
        })

        let candidateDirectory = layout.configurationDirectory.appendingPathComponent("php.d-candidate-\(UUID().uuidString)", isDirectory: true)
        defer { try? files.removeItem(at: candidateDirectory) }
        try files.createDirectory(at: candidateDirectory, withIntermediateDirectories: true)
        let candidate = candidateDirectory.appendingPathComponent(layout.phpExtensionConfiguration.lastPathComponent)
        try writeConfiguration(selectedLibraries, to: candidate)
        let result = try runner.run(
            executable: installation.php,
            arguments: phpConfigurationArguments() + ["-m"],
            environment: ["PHP_INI_SCAN_DIR": candidateDirectory.path]
        )
        guard result.status == 0 else {
            throw PHPExtensionError.validationFailed(result.combinedOutput)
        }
        let loaded = Self.parseModules(result.combinedOutput)
        if enabled, !moduleIsLoaded(safeName, modules: loaded) {
            throw PHPExtensionError.validationFailed("PHP 没有报告已加载 \(safeName)。")
        }
        if !enabled, moduleIsLoaded(safeName, modules: loaded) {
            throw PHPExtensionError.validationFailed("PHP 仍然报告 \(safeName) 已加载。")
        }

        let previousData = try? Data(contentsOf: layout.phpExtensionConfiguration)
        let backupURL = try previousData.map { data -> URL in
            try files.createDirectory(at: layout.phpExtensionBackupDirectory, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let url = layout.phpExtensionBackupDirectory.appendingPathComponent(
                "extensions-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8)).ini"
            )
            try data.write(to: url, options: .withoutOverwriting)
            return url
        }
        try Data(contentsOf: candidate).write(to: layout.phpExtensionConfiguration, options: .atomic)
        return PHPExtensionConfigurationChange(previousData: previousData, backupURL: backupURL)
    }

    public func restore(_ change: PHPExtensionConfigurationChange) throws {
        if let previousData = change.previousData {
            try previousData.write(to: layout.phpExtensionConfiguration, options: .atomic)
        } else if files.fileExists(atPath: layout.phpExtensionConfiguration.path) {
            try files.removeItem(at: layout.phpExtensionConfiguration)
        }
    }

    public static func parseModules(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("[") }
    }

    private func phpConfigurationArguments() -> [String] {
        files.fileExists(atPath: layout.phpConfiguration.path)
            ? ["--php-ini", layout.phpConfiguration.path]
            : ["-n"]
    }

    private func managedEnvironment() -> [String: String] {
        ["PHP_INI_SCAN_DIR": layout.phpExtensionConfigurationDirectory.path]
    }

    private func commandEnvironment() -> [String: String] {
        let phpBin = installation.php.deletingLastPathComponent().path
        let inherited = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return ["PATH": "\(phpBin):/opt/homebrew/bin:\(inherited)"]
    }

    private func moduleNames(arguments: [String], environment: [String: String]?) throws -> [String] {
        let result = try runner.run(executable: installation.php, arguments: arguments, environment: environment)
        try checked(result, command: ([installation.php.path] + arguments).joined(separator: " "))
        return Self.parseModules(result.combinedOutput)
    }

    private func extensionDirectory() throws -> URL {
        if let directory = installation.phpExtensionDirectory { return directory }
        let result = try runner.run(
            executable: installation.php,
            arguments: ["-n", "-r", "echo ini_get('extension_dir');"],
            environment: ["PHP_INI_SCAN_DIR": ""]
        )
        try checked(result, command: "php -n -r extension_dir")
        let path = result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { throw PHPExtensionError.validationFailed("PHP 没有返回 extension_dir。") }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func extensionLibraries() throws -> [String: URL] {
        let directory = try extensionDirectory()
        guard let urls = try? files.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [:] }
        return Dictionary(uniqueKeysWithValues: urls.compactMap { url -> (String, URL)? in
            guard url.pathExtension.lowercased() == "so" else { return nil }
            return (url.deletingPathExtension().lastPathComponent.lowercased(), url.resolvingSymlinksInPath())
        })
    }

    private func configuredNames(at url: URL) throws -> Set<String> {
        guard files.fileExists(atPath: url.path) else { return [] }
        let text = try String(contentsOf: url, encoding: .utf8)
        return Set(text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.hasPrefix(";") && !trimmed.hasPrefix("#"),
                  let equals = trimmed.firstIndex(of: "=") else { return nil }
            let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            guard key == "extension" || key == "zend_extension" else { return nil }
            var value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value.removeFirst(); value.removeLast()
            }
            return URL(fileURLWithPath: value).deletingPathExtension().lastPathComponent.lowercased()
        })
    }

    private func writeConfiguration(_ selected: [String: URL], to url: URL) throws {
        var lines = [
            "; Managed by MacStack. Changes here affect only MacStack's PHP-FPM.",
            "; Use the PHP Extensions page so changes are validated and backed up."
        ]
        for name in selected.keys.sorted() {
            guard let library = selected[name] else { continue }
            let path = library.path
            guard !path.contains("\n"), !path.contains("\r"), !path.contains("\0"), !path.contains("\"") else {
                throw PHPExtensionError.validationFailed("扩展路径无法安全写入配置：\(path)")
            }
            let directive = (name == "xdebug" || name == "opcache") ? "zend_extension" : "extension"
            lines.append("\(directive)=\"\(path)\"")
        }
        lines.append("")
        try Data(lines.joined(separator: "\n").utf8).write(to: url, options: .atomic)
    }

    private func checked(_ result: CommandOutput, command: String) throws {
        guard result.status == 0 else {
            throw PHPExtensionError.commandFailed(command, result.status, result.combinedOutput)
        }
    }

    private func validated(_ name: String) throws -> String {
        let value = name.lowercased()
        guard !value.isEmpty, value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else {
            throw PHPExtensionError.invalidName(name)
        }
        return value
    }

    private func moduleIsLoaded(_ name: String, modules: [String]) -> Bool {
        let wanted = normalized(name)
        return modules.contains { module in
            let value = normalized(module)
            return value == wanted || (wanted == "opcache" && value == "zendopcache")
        }
    }

    private func normalized(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private func isARM64(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096) else { return false }
        return MachOHeader.containsARM64(data)
    }
}
