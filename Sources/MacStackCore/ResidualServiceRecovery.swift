import Darwin
import Foundation

public enum ResidualServiceRecoveryError: Error, LocalizedError {
    case processDidNotStop(Int32)

    public var errorDescription: String? {
        switch self {
        case .processDidNotStop(let pid):
            "已确认 PID \(pid) 属于 MacStack，但发送终止信号后仍未退出。"
        }
    }
}

/// 一个无法确认身份、因此没有被终止的进程。
///
/// 这类进程**不会中断整个恢复流程**——之前只要遇到一个就抛错，后面的候选
/// （PHP-FPM、MariaDB）根本不会被检查。
public struct UnresolvedResidualProcess: Equatable, Sendable {
    public let pid: Int32
    public let command: String
    public let reason: String

    public init(pid: Int32, command: String, reason: String) {
        self.pid = pid
        self.command = command
        self.reason = reason
    }
}

public struct ResidualServiceRecoveryResult: Equatable, Sendable {
    public let stoppedProcessCount: Int
    public let removedStalePIDCount: Int
    /// 无法确认身份、已跳过且未终止的进程。
    public let unresolved: [UnresolvedResidualProcess]

    public init(
        stoppedProcessCount: Int,
        removedStalePIDCount: Int,
        unresolved: [UnresolvedResidualProcess] = []
    ) {
        self.stoppedProcessCount = stoppedProcessCount
        self.removedStalePIDCount = removedStalePIDCount
        self.unresolved = unresolved
    }
}

public struct ResidualServiceRecovery: Sendable {
    public init() {}

    public func recover(layout: RuntimeLayout = .applicationSupport()) throws -> ResidualServiceRecoveryResult {
        let candidates: [(URL, String)] = [
            (layout.apachePID, layout.apacheConfiguration.path),
            (layout.phpPID, layout.phpFPMConfiguration.path),
            (layout.databasePID, layout.databaseConfiguration.path)
        ]
        var stopped = 0
        var removed = 0
        var unresolved: [UnresolvedResidualProcess] = []

        for (pidFile, requiredArgument) in candidates {
            guard let raw = try? String(contentsOf: pidFile, encoding: .utf8),
                  let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else {
                continue
            }

            switch liveness(of: pid) {
            case .gone:
                // 进程确实不存在，PID 文件是失效的。
                try? FileManager.default.removeItem(at: pidFile)
                removed += 1
                continue
            case .noPermission:
                // 进程存在但我们无权读取。**不能**当成已死——否则会删掉一个
                // 仍然有效的 PID 文件。
                unresolved.append(UnresolvedResidualProcess(
                    pid: pid,
                    command: "（无权限读取进程信息）",
                    reason: "进程存在但当前用户无权访问，未终止也未删除 PID 文件。"
                ))
                continue
            case .running:
                break
            }

            guard let snapshot = processSnapshot(pid: pid) else {
                unresolved.append(UnresolvedResidualProcess(
                    pid: pid, command: "（无法读取进程信息）",
                    reason: "无法读取进程的命令行与启动时间，无法确认身份。"
                ))
                continue
            }
            guard snapshot.command.contains(requiredArgument) else {
                unresolved.append(UnresolvedResidualProcess(
                    pid: pid, command: snapshot.command,
                    reason: "命令行里没有 MacStack 专属配置路径，无法确认它属于 MacStack。"
                ))
                continue
            }
            // 发信号前复核身份：PID 可能已经被回收并分配给另一个进程。
            guard let rechecked = processSnapshot(pid: pid), rechecked == snapshot else {
                unresolved.append(UnresolvedResidualProcess(
                    pid: pid, command: snapshot.command,
                    reason: "发信号前进程身份发生变化，已跳过以避免误杀。"
                ))
                continue
            }

            _ = kill(pid, SIGTERM)
            for _ in 0..<50 {
                if liveness(of: pid) != .running { break }
                usleep(100_000)
            }
            if liveness(of: pid) == .running {
                // 强杀前再复核一次，同样是为了避免 PID 复用导致的误杀。
                if let beforeKill = processSnapshot(pid: pid), beforeKill == snapshot {
                    _ = kill(pid, SIGKILL)
                }
                for _ in 0..<20 {
                    if liveness(of: pid) != .running { break }
                    usleep(100_000)
                }
            }

            guard liveness(of: pid) != .running else {
                unresolved.append(UnresolvedResidualProcess(
                    pid: pid, command: snapshot.command,
                    reason: "已确认属于 MacStack，但发送终止信号后仍未退出。"
                ))
                continue
            }
            try? FileManager.default.removeItem(at: pidFile)
            stopped += 1
        }
        return ResidualServiceRecoveryResult(
            stoppedProcessCount: stopped,
            removedStalePIDCount: removed,
            unresolved: unresolved
        )
    }

    // MARK: - 进程存活与身份

    private enum Liveness {
        case running
        case gone
        /// 进程存在，但当前用户没有权限访问。
        case noPermission
    }

    /// `kill(pid, 0)` 在进程存在但无权限时返回 -1 且 `errno == EPERM`。
    /// 旧实现把这种情况也当成「进程已死」，进而删掉了仍然有效的 PID 文件。
    private func liveness(of pid: Int32) -> Liveness {
        if kill(pid, 0) == 0 { return .running }
        return errno == ESRCH ? .gone : .noPermission
    }

    /// 进程身份快照：命令行 + 启动时间。
    ///
    /// 只用 `kill(pid, 0)` 判断存活是不够的——PID 被回收后重新分配时它照样返回成功，
    /// 因此它只能证明「某个进程占用了这个 PID」，不能证明「还是原来那个进程」。
    /// 启动时间在同一 PID 复用后会不同，所以「命令行 + 启动时间」双重比对才是
    /// macOS 上可行的身份判据（macOS 没有 pidfd）。
    private struct ProcessSnapshot: Equatable {
        let command: String
        let startedAt: String
    }

    private func processSnapshot(pid: Int32) -> ProcessSnapshot? {
        // 分两次单字段调用，各自原样取用，避免依赖 `ps` 多列输出的固定宽度格式。
        guard let startedAt = psField(pid: pid, keyword: "lstart="),
              let command = psField(pid: pid, keyword: "command="),
              !startedAt.isEmpty, !command.isEmpty else { return nil }
        return ProcessSnapshot(command: command, startedAt: startedAt)
    }

    private func psField(pid: Int32, keyword: String) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", keyword]
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
