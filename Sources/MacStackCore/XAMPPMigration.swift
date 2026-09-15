import Foundation
import Darwin

public enum XAMPPAuditError: Error, LocalizedError {
    case rootMissing(String)
    case rootNotDirectory(String)
    case reportDirectoryIsSymlink(String)

    public var errorDescription: String? {
        switch self {
        case .rootMissing(let path): "没有找到旧 XAMPP：\(path)"
        case .rootNotDirectory(let path): "XAMPP 路径不是目录：\(path)"
        case .reportDirectoryIsSymlink(let path): "为避免把报告写到意外位置，拒绝使用符号链接目录：\(path)"
        }
    }
}

public struct XAMPPSiteAudit: Codable, Equatable, Sendable {
    public let name: String
    public let path: String
    public let byteCount: Int64
    public let fileCount: Int
    public let readable: Bool
    public let markers: [String]
    public let databaseReferenceFileCount: Int
}

public struct XAMPPDatabaseAudit: Codable, Equatable, Sendable {
    public let name: String
    public let path: String
    public let byteCount: Int64
    public let fileCount: Int
    public let readable: Bool
    public let isSystemDatabase: Bool
}

public struct XAMPPBinaryAudit: Codable, Equatable, Sendable {
    public let name: String
    public let path: String
    public let architectures: [String]
}

public struct XAMPPAuditReport: Codable, Equatable, Sendable {
    public let createdAt: Date
    public let rootPath: String
    public let totalByteCount: Int64
    public let readable: Bool
    public let sites: [XAMPPSiteAudit]
    public let databases: [XAMPPDatabaseAudit]
    public let binaries: [XAMPPBinaryAudit]
    public let apacheListen: String?
    public let apacheDocumentRoot: String?
    public let databasePort: String?
    public let databaseSocket: String?
    public let phpExtensions: [String]
    public let warnings: [String]

    public var businessDatabases: [XAMPPDatabaseAudit] {
        databases.filter { !$0.isSystemDatabase }
    }

    public func markdown() -> String {
        let date = createdAt.formatted(.iso8601)
        let siteRows = sites.isEmpty
            ? "| （未发现） | — | — | — | — | — |\n"
            : sites.map {
                "| \(escape($0.name)) | \(formatBytes($0.byteCount)) | \($0.fileCount) | \($0.readable ? "是" : "否") | \($0.markers.isEmpty ? "—" : escape($0.markers.joined(separator: "、"))) | \($0.databaseReferenceFileCount) |"
            }.joined(separator: "\n") + "\n"
        let databaseRows = databases.isEmpty
            ? "| （未发现） | — | — | — |\n"
            : databases.map {
                "| \(escape($0.name)) | \($0.isSystemDatabase ? "系统库" : "可能是业务库") | \(formatBytes($0.byteCount)) | \($0.readable ? "是" : "否") |"
            }.joined(separator: "\n") + "\n"
        let binaryRows = binaries.map {
            "| \(escape($0.name)) | \(escape($0.architectures.isEmpty ? "无法识别" : $0.architectures.joined(separator: ", "))) |"
        }.joined(separator: "\n")
        let extensionText = phpExtensions.isEmpty ? "未从启用项中检测到扩展。" : phpExtensions.map { "`\($0)`" }.joined(separator: "、")
        let warningText = warnings.isEmpty ? "- 无。" : warnings.map { "- \($0)" }.joined(separator: "\n")
        return """
        # 旧 XAMPP 只读盘点报告

        > 本报告只读取文件名、大小、Mach-O 头部和少量非敏感配置项。没有启动旧组件，没有复制站点，没有导出或导入数据库，也没有修改旧 XAMPP。

        - 生成时间：\(date)
        - XAMPP 根目录：`\(rootPath)`
        - 可统计大小：\(formatBytes(totalByteCount))
        - 根目录可读：\(readable ? "是" : "否")

        ## 网站候选

        | 名称 | 可统计大小 | 文件数 | 可完整读取 | 项目标记 | 含数据库引用的文件数 |
        |---|---:|---:|---|---|---:|
        \(siteRows)
        ## 数据库目录

        | 名称 | 分类 | 可统计大小 | 可完整读取 |
        |---|---|---:|---|
        \(databaseRows)
        发现可能的业务数据库：\(businessDatabases.isEmpty ? "无" : businessDatabases.map(\.name).joined(separator: "、"))。

        ## 旧组件架构

        | 组件 | 架构 |
        |---|---|
        \(binaryRows.isEmpty ? "| （未找到） | — |" : binaryRows)

        ## 旧配置摘要

        - Apache Listen：`\(apacheListen ?? "未识别")`
        - Apache DocumentRoot：`\(apacheDocumentRoot ?? "未识别")`
        - 数据库端口：`\(databasePort ?? "未识别")`
        - 数据库 socket：`\(databaseSocket ?? "未识别")`
        - PHP 启用扩展：\(extensionText)

        ## 警告

        \(warningText)

        ## 下一步

        先选择需要迁移的网站并创建副本，再使用逻辑 SQL 导出/导入数据库。不得直接复用旧 `var/mysql` 物理数据目录。任何实际迁移都应在单独确认后执行。
        """
    }

    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

public struct XAMPPAuditor: Sendable {
    public let root: URL
    private var fileManager: FileManager { .default }

    public init(root: URL = URL(fileURLWithPath: "/Applications/XAMPP", isDirectory: true)) {
        self.root = root.standardizedFileURL
    }

    public func audit() throws -> XAMPPAuditReport {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            throw XAMPPAuditError.rootMissing(root.path)
        }
        guard isDirectory.boolValue else { throw XAMPPAuditError.rootNotDirectory(root.path) }

        let rootStats = statistics(root)
        var warnings = rootStats.readable ? [] : ["部分 XAMPP 文件不可读，大小和文件数是下限，不应据此认定目录为空。"]
        let htdocs = root.appendingPathComponent("xamppfiles/htdocs", isDirectory: true)
        let sites = childDirectories(htdocs)
            .filter { !["dashboard", "img", "webalizer"].contains($0.lastPathComponent.lowercased()) }
            .map(siteAudit)
        let databaseRoot = root.appendingPathComponent("xamppfiles/var/mysql", isDirectory: true)
        let systemDatabases: Set<String> = ["mysql", "performance_schema", "information_schema", "sys", "phpmyadmin", "test"]
        let databases = childDirectories(databaseRoot).map { url in
            let stats = statistics(url)
            return XAMPPDatabaseAudit(
                name: url.lastPathComponent,
                path: url.path,
                byteCount: stats.bytes,
                fileCount: stats.files,
                readable: stats.readable,
                isSystemDatabase: systemDatabases.contains(url.lastPathComponent.lowercased())
            )
        }
        if databases.contains(where: { !$0.readable }) {
            warnings.append("至少一个数据库目录无法完整读取；报告仍列出可见目录名，但容量和内容可能不完整。")
        }

        let binaryPaths = [
            ("Apache httpd", "xamppfiles/bin/httpd"),
            ("PHP", "xamppfiles/bin/php"),
            ("MySQL/MariaDB", "xamppfiles/sbin/mysqld")
        ]
        let binaries = binaryPaths.compactMap { name, relative -> XAMPPBinaryAudit? in
            let url = root.appendingPathComponent(relative)
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            return XAMPPBinaryAudit(name: name, path: url.path, architectures: architectures(url))
        }

        let httpd = text(root.appendingPathComponent("xamppfiles/etc/httpd.conf"))
        let my = text(root.appendingPathComponent("xamppfiles/etc/my.cnf"))
        let php = text(root.appendingPathComponent("xamppfiles/etc/php.ini"))
        let report = XAMPPAuditReport(
            createdAt: Date(),
            rootPath: root.path,
            totalByteCount: rootStats.bytes,
            readable: rootStats.readable,
            sites: sites.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            databases: databases.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            binaries: binaries,
            apacheListen: directive("Listen", in: httpd),
            apacheDocumentRoot: directive("DocumentRoot", in: httpd)?.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")),
            databasePort: iniValue("port", in: my),
            databaseSocket: iniValue("socket", in: my),
            phpExtensions: phpExtensionNames(in: php),
            warnings: warnings
        )
        return report
    }

    @discardableResult
    public func writeReport(_ report: XAMPPAuditReport, directory: URL? = nil) throws -> URL {
        let destination = directory ?? Self.defaultReportDirectory(fileManager: fileManager)
        if let values = try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
            throw XAMPPAuditError.reportDirectoryIsSymlink(destination.path)
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stamp = ISO8601DateFormatter().string(from: report.createdAt)
            .replacingOccurrences(of: ":", with: "-")
        let url = destination.appendingPathComponent("xampp-audit-\(stamp).md")
        try Data(report.markdown().utf8).write(to: url, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    public static func defaultReportDirectory(fileManager: FileManager = .default) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("MacStack/migration-reports", isDirectory: true)
    }

    private func childDirectories(_ url: URL) -> [URL] {
        guard let children = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return children.filter {
            guard let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
            return values.isDirectory == true && values.isSymbolicLink != true
        }
    }

    private func siteAudit(_ url: URL) -> XAMPPSiteAudit {
        let stats = statistics(url)
        let markerFiles = [
            ("composer.json", "Composer"),
            ("wp-config.php", "WordPress"),
            ("artisan", "Laravel"),
            ("index.php", "PHP 入口")
        ]
        let markers = markerFiles.compactMap { file, label in
            fileManager.fileExists(atPath: url.appendingPathComponent(file).path) ? label : nil
        }
        return XAMPPSiteAudit(
            name: url.lastPathComponent,
            path: url.path,
            byteCount: stats.bytes,
            fileCount: stats.files,
            readable: stats.readable,
            markers: markers,
            databaseReferenceFileCount: databaseReferenceCount(url)
        )
    }

    private func statistics(_ url: URL) -> (bytes: Int64, files: Int, readable: Bool) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .isReadableKey]
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: keys, options: []) else {
            return (0, 0, false)
        }
        var bytes: Int64 = 0
        var files = 0
        var readable = Darwin.access(url.path, R_OK | X_OK) == 0
        while let item = enumerator.nextObject() as? URL {
            guard let values = try? item.resourceValues(forKeys: Set(keys)) else {
                readable = false
                continue
            }
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values.isReadable == false { readable = false }
            if values.isRegularFile == true {
                files += 1
                bytes += Int64(values.fileSize ?? 0)
            }
        }
        return (bytes, files, readable)
    }

    private func architectures(_ url: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096) else { return [] }
        return MachOHeader.architectures(data)
    }

    private func text(_ url: URL, maximumBytes: Int = 2_000_000) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumBytes) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func activeLines(_ text: String?) -> [String] {
        guard let text else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            return line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") ? nil : line
        }
    }

    private func directive(_ name: String, in text: String?) -> String? {
        let prefix = name.lowercased() + " "
        return activeLines(text).first { $0.lowercased().hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
    }

    private func iniValue(_ name: String, in text: String?) -> String? {
        activeLines(text).compactMap { line -> String? in
            guard let equals = line.firstIndex(of: "=") else { return nil }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            guard key == name.lowercased() else { return nil }
            return line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        }.first
    }

    private func phpExtensionNames(in text: String?) -> [String] {
        Set(activeLines(text).compactMap { line -> String? in
            guard let equals = line.firstIndex(of: "=") else { return nil }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            guard key == "extension" || key == "zend_extension" else { return nil }
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return URL(fileURLWithPath: value).lastPathComponent
        }).sorted()
    }

    private func databaseReferenceCount(_ root: URL) -> Int {
        let extensions = Set(["php", "env", "ini", "json", "yaml", "yml", "xml"])
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]) else { return 0 }
        var count = 0
        while let url = enumerator.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  (values.fileSize ?? 0) <= 512_000,
                  extensions.contains(url.pathExtension.lowercased()),
                  let content = text(url, maximumBytes: 512_000)?.lowercased() else { continue }
            if ["mysqli", "pdo_mysql", "new pdo", "mysql:", "mysql_connect", "database_url", "db_host"].contains(where: content.contains) {
                count += 1
            }
        }
        return count
    }
}
