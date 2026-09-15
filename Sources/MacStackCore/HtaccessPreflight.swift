import Foundation

// `.htaccess` 预检。
//
// 为什么需要它：PHP 通过 PHP-FPM 运行，没有 mod_php。`.htaccess` 里出现
// `php_value` 这类指令时，Apache 不会「忽略」它，而是报 `Invalid command` 并返回
// HTTP 500。同样地，如果 `.htaccess` 用了 `IndexOptions` 而 mod_autoindex 没加载，
// 也会 500。
//
// 但直接按正则匹配就阻止站点是过度概括：被 `<IfModule mod_php.c>` 包起来的
// `php_value` 会被 Apache **整体跳过**，站点照常运行，只是那些设置静默失效。
// 因此预检必须求值 `<IfModule>` 条件，只报告**实际会被处理**的指令。

public enum HtaccessFinding: Equatable, Sendable {
    /// A 类：指令会被 Apache 处理，但提供它的模块不存在 → 必然 HTTP 500。
    /// 必须阻止站点启用。
    case unsupportedPhpDirective(file: String, line: Int, directive: String)
    /// A 类：指令需要当前**未授予**的覆盖类 → Apache 报 "not allowed here" 并返回 500。
    /// 必须阻止站点启用。
    case overrideNotPermitted(file: String, line: Int, directive: String, requiredOverride: String)
    /// B 类：指令会被处理，但所需模块未加载 → 会 HTTP 500。
    /// 提示用户在设置里开启对应模块。
    case missingModule(file: String, line: Int, directive: String, module: String)
    /// C 类：指令位于不会生效的 `<IfModule>` 块内，站点能跑，但这些设置静默失效。
    /// 用户往往以为它们生效了，所以要记录下来。
    case inactivePhpDirective(file: String, line: Int, directive: String)

    public var isBlocking: Bool {
        switch self {
        case .unsupportedPhpDirective, .overrideNotPermitted: true
        case .missingModule, .inactivePhpDirective: false
        }
    }

    public var file: String {
        switch self {
        case .unsupportedPhpDirective(let file, _, _),
             .overrideNotPermitted(let file, _, _, _),
             .missingModule(let file, _, _, _),
             .inactivePhpDirective(let file, _, _):
            file
        }
    }

    public var line: Int {
        switch self {
        case .unsupportedPhpDirective(_, let line, _),
             .overrideNotPermitted(_, let line, _, _),
             .missingModule(_, let line, _, _),
             .inactivePhpDirective(_, let line, _):
            line
        }
    }
}

public struct HtaccessPreflightReport: Equatable, Sendable {
    public let findings: [HtaccessFinding]
    public let scannedFileCount: Int

    public init(findings: [HtaccessFinding], scannedFileCount: Int) {
        self.findings = findings
        self.scannedFileCount = scannedFileCount
    }

    public var blockingFindings: [HtaccessFinding] { findings.filter(\.isBlocking) }
    public var hasBlockingFinding: Bool { findings.contains(where: \.isBlocking) }

    /// 面向界面的简述。没有问题时返回 nil。
    ///
    /// 每一类都带上「文件:行 + 指令 + 需要什么」，而不是只给数量——
    /// B 类提示的全部意义就是告诉用户去开启哪个模块。
    public var summary: String? {
        guard !findings.isEmpty else { return nil }
        var lines: [String] = []

        let blocking = blockingFindings
        if !blocking.isEmpty {
            lines.append("发现 \(blocking.count) 处会导致站点返回 HTTP 500 的指令，站点未启用：")
            lines.append(contentsOf: blocking.prefix(5).map(describe))
        }
        let missing = findings.filter { if case .missingModule = $0 { return true } else { return false } }
        if !missing.isEmpty {
            let modules = Set(missing.compactMap { finding -> String? in
                if case .missingModule(_, _, _, let module) = finding { return module }
                return nil
            }).sorted()
            lines.append("有 \(missing.count) 处指令需要尚未加载的模块（\(modules.joined(separator: "、"))），启用前站点会返回 HTTP 500。可在设置页的「按需加载的可选 Apache 模块」中开启：")
            lines.append(contentsOf: missing.prefix(5).map(describe))
        }

        let inactive = findings.filter { if case .inactivePhpDirective = $0 { return true } else { return false } }
        if !inactive.isEmpty {
            lines.append("另有 \(inactive.count) 条指令位于不会生效的 <IfModule> 块内（例如 <IfModule mod_php.c>），站点可以运行，但这些设置不会生效：")
            lines.append(contentsOf: inactive.prefix(5).map(describe))
        }

        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private func describe(_ finding: HtaccessFinding) -> String {
        switch finding {
        case .unsupportedPhpDirective(let file, let line, let directive):
            "· \(shortPath(file)):\(line) 使用了 \(directive)；PHP 由 PHP-FPM 执行，没有 mod_php。可改用 .user.ini 或 MacStack 的 php.ini。"
        case .overrideNotPermitted(let file, let line, let directive, let requiredOverride):
            "· \(shortPath(file)):\(line) 使用了 \(directive)，需要 `\(requiredOverride)` 覆盖类。"
                + "MacStack 默认不放开它（以免站点推翻符号链接与目录列表策略）；"
                + "确实需要时可在设置页开启「允许 .htaccess 覆盖 Options」。"
        case .missingModule(let file, let line, let directive, let module):
            "· \(shortPath(file)):\(line) 使用了 \(directive)，需要 \(module) 模块。"
        case .inactivePhpDirective(let file, let line, let directive):
            "· \(shortPath(file)):\(line) 的 \(directive) 被 <IfModule> 跳过，不会生效。"
        }
    }

    private func shortPath(_ path: String) -> String {
        let components = path.split(separator: "/")
        return components.suffix(2).joined(separator: "/")
    }
}

public struct HtaccessPreflight: Sendable {
    /// 由可选模块提供的指令 → 模块名。基础模块提供的指令不在此列，避免误报。
    private static let phpDirectives: Set<String> = [
        "php_value", "php_flag", "php_admin_value", "php_admin_flag"
    ]

    /// 需要 `AllowOverride Options` 的指令。
    ///
    /// MacStack 默认只放开 `FileInfo Indexes AuthConfig Limit`，**刻意不含 `Options`**
    /// —— 否则站点能用 `.htaccess` 推翻 `-FollowSymLinks` 加固。代价是这些指令一旦
    /// 出现在**会生效**的位置（不在被跳过的 `<IfModule>` 里），Apache 就报
    /// "not allowed here" 并返回 500。
    ///
    /// 实测确认：裸 `Options -MultiViews -Indexes` 会让站点 500，而 Laravel / Symfony
    /// 官方 `.htaccess` 里同样的指令因为被包在 `<IfModule mod_negotiation.c>` 里
    /// （该模块未加载 → 整块跳过）反而不会报错。所以必须求值 `IfModule` 后再判断。
    static let optionsOverrideDirectives: Set<String> = ["Options", "XBitHack"]

    /// 单文件读取上限，避免误把大文件当配置扫描。
    private static let maximumFileBytes = 512 * 1_024
    /// 目录递归深度上限。
    private static let maximumDepth = 8

    public init() {}

    /// 扫描公开目录下所有 `.htaccess`。
    ///
    /// - Parameters:
    ///   - publicRoot: 站点公开目录。
    ///   - loadedModules: 当前配置实际会加载的模块名集合，见
    ///     `ApacheModulePlan.loadedModules(for:)`。
    ///   - allowsOptionsOverride: 是否授予了 `Options` 覆盖类，见
    ///     `Preferences.allowHtaccessOptions`。
    public func scan(
        publicRoot: URL,
        loadedModules: Set<String>,
        allowsOptionsOverride: Bool = false
    ) -> HtaccessPreflightReport {
        let root = publicRoot.standardizedFileURL
        var files: [URL] = []
        collectHtaccessFiles(in: root, depth: 0, into: &files)

        var findings: [HtaccessFinding] = []
        for file in files.sorted(by: { $0.path < $1.path }) {
            findings.append(contentsOf: inspect(
                file: file,
                loadedModules: loadedModules,
                allowsOptionsOverride: allowsOptionsOverride
            ))
        }
        return HtaccessPreflightReport(findings: findings, scannedFileCount: files.count)
    }

    // MARK: - 目录遍历

    private func collectHtaccessFiles(in directory: URL, depth: Int, into files: inout [URL]) {
        guard depth <= Self.maximumDepth else { return }
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey],
            options: []
        )) ?? []

        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
            // 不跟随符号链接：与站点配置里的 -FollowSymLinks 保持一致。
            guard values?.isSymbolicLink != true else { continue }
            if entry.lastPathComponent == ".htaccess", values?.isRegularFile == true {
                files.append(entry)
                continue
            }
            guard values?.isDirectory == true else { continue }
            // 版本库与依赖目录里不会有需要执行的 .htaccess。
            if [".git", "node_modules", "vendor", ".svn", ".hg"].contains(entry.lastPathComponent) { continue }
            collectHtaccessFiles(in: entry, depth: depth + 1, into: &files)
        }
    }

    // MARK: - 单文件解析

    private func inspect(
        file: URL,
        loadedModules: Set<String>,
        allowsOptionsOverride: Bool
    ) -> [HtaccessFinding] {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              size <= Int64(Self.maximumFileBytes),
              let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }

        var findings: [HtaccessFinding] = []
        // 每一层 <IfModule> 的条件是否成立。空栈表示处于顶层，始终生效。
        var conditionStack: [Bool] = []

        for (offset, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineNumber = offset + 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let lowered = line.lowercased()
            if lowered.hasPrefix("<ifmodule") {
                conditionStack.append(evaluateIfModule(line, loadedModules: loadedModules))
                continue
            }
            if lowered.hasPrefix("</ifmodule") {
                if !conditionStack.isEmpty { conditionStack.removeLast() }
                continue
            }

            let active = conditionStack.allSatisfy { $0 }
            guard let token = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) else { continue }

            if Self.phpDirectives.contains(token) {
                if active {
                    findings.append(.unsupportedPhpDirective(file: file.path, line: lineNumber, directive: token))
                } else {
                    findings.append(.inactivePhpDirective(file: file.path, line: lineNumber, directive: token))
                }
                continue
            }

            // 需要未授予的覆盖类。只有**会生效**的指令才报——被跳过的 <IfModule>
            // 里写 Options 是无害的（Laravel 官方 .htaccess 就是这种写法）。
            if active,
               !allowsOptionsOverride,
               Self.optionsOverrideDirectives.contains(token) {
                findings.append(.overrideNotPermitted(
                    file: file.path, line: lineNumber,
                    directive: token, requiredOverride: "Options"
                ))
                continue
            }

            if let module = ApacheModulePlan.directiveProviders[token],
               !loadedModules.contains(module),
               active {
                findings.append(.missingModule(file: file.path, line: lineNumber, directive: token, module: module))
            }
        }
        return findings
    }

    /// 求值 `<IfModule ...>` 的条件。
    ///
    /// 支持 `mod_php.c`、`php_module`、`php7_module` 这类写法，以及 `!` 取反。
    private func evaluateIfModule(_ line: String, loadedModules: Set<String>) -> Bool {
        let inner = line
            .replacingOccurrences(of: "<", with: "")
            .replacingOccurrences(of: ">", with: "")
        let tokens = inner.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        // tokens[0] 是 "IfModule"，其余是模块条件。
        guard let condition = tokens.dropFirst().first else { return false }
        let negated = condition.hasPrefix("!")
        let name = Self.normalizeModuleToken(negated ? String(condition.dropFirst()) : condition)
        let loaded = loadedModules.contains(name)
        return negated ? !loaded : loaded
    }

    /// 把 `<IfModule>` 里的模块写法归一化成 `ApacheModulePlan` 使用的短名。
    ///
    /// `mod_php.c` → `php`；`php_module` → `php`；`rewrite_module` → `rewrite`。
    static func normalizeModuleToken(_ token: String) -> String {
        var name = token.lowercased()
        for suffix in [".c", ".so"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        if name.hasSuffix("_module") { name = String(name.dropLast("_module".count)) }
        if name.hasPrefix("mod_") { name = String(name.dropFirst(4)) }
        return name
    }
}
