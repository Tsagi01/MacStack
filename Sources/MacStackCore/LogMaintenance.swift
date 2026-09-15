import Foundation

public struct LogMaintenanceResult: Equatable, Sendable {
    public let rotated: Int
    public let removed: Int
}

/// 日志文件的归属。
///
/// Web 与数据库共用一个日志目录，因此「准备 A 的配置」时 B 可能正在运行。
/// 轮转做的是「改名 + 建同名空文件」，如果动到 B 仍持有写入句柄的日志，
/// 后续写入会继续进入被改名的 `.1` 文件，而新建的空文件永远是空的。
///
/// 所以每个组件只轮转**自己**的日志前缀；跨组件的全量整理只在所有服务都停止时做
/// （见 `AppModel.rotateLogsNow`）。
public enum LogOwnership {
    /// Web 栈：Apache、PHP-FPM 与各站点（`site-<uuid>-*.log`）。
    public static let web: Set<String> = ["apache", "php", "site-", "httpd"]
    /// 数据库：MariaDB。
    public static let database: Set<String> = ["mariadb"]
}

public struct LogMaintainer: Sendable {
    public init() {}

    /// 轮转目录下超过阈值的日志文件。
    ///
    /// **调用前必须确认目标日志没有打开的写入句柄。** 安全时点只有两类：
    /// 服务已停止时，或某个组件在自己打开句柄之前（见 `LocalWebStackController.start`）。
    /// 因此调用方应当用 `prefixes` 把范围限制在自己确定已停止的那个组件上，
    /// 不要在图省事时轮转整个共享目录。
    ///
    /// - Parameter prefixes: 只轮转文件名以这些前缀开头的日志；nil 表示全部。
    @discardableResult
    public func rotate(
        directory: URL,
        maximumBytes: Int64 = 5 * 1_024 * 1_024,
        retainedCopies: Int = 3,
        prefixes: Set<String>? = nil
    ) throws -> LogMaintenanceResult {
        guard retainedCopies > 0 else { return LogMaintenanceResult(rotated: 0, removed: 0) }
        let files = FileManager.default
        guard files.fileExists(atPath: directory.path) else {
            return LogMaintenanceResult(rotated: 0, removed: 0)
        }
        var rotated = 0
        var removed = 0
        for log in try files.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) where log.pathExtension == "log" && Self.matches(log.lastPathComponent, prefixes: prefixes) {
            let values = try log.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  Int64(values.fileSize ?? 0) >= maximumBytes else { continue }

            let oldest = URL(fileURLWithPath: log.path + ".\(retainedCopies)")
            if files.fileExists(atPath: oldest.path) {
                try files.removeItem(at: oldest)
                removed += 1
            }
            if retainedCopies > 1 {
                for index in stride(from: retainedCopies - 1, through: 1, by: -1) {
                    let source = URL(fileURLWithPath: log.path + ".\(index)")
                    let target = URL(fileURLWithPath: log.path + ".\(index + 1)")
                    if files.fileExists(atPath: source.path) { try files.moveItem(at: source, to: target) }
                }
            }
            try files.moveItem(at: log, to: URL(fileURLWithPath: log.path + ".1"))
            files.createFile(atPath: log.path, contents: nil)
            rotated += 1
        }
        return LogMaintenanceResult(rotated: rotated, removed: removed)
    }

    /// 文件名是否落在给定的前缀集合内。`prefixes` 为 nil 时表示全部匹配。
    private static func matches(_ fileName: String, prefixes: Set<String>?) -> Bool {
        guard let prefixes else { return true }
        return prefixes.contains { fileName.hasPrefix($0) }
    }
}
