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

/// 残留服务的身份判据。
///
/// **独立成类型是为了可测**：判据本身是纯函数，不需要真的去读进程信息，
/// 因此单元测试可以直接喂进各种命令行。
enum ResidualIdentity {
    static let apacheNames: Set<String> = ["httpd"]
    static let phpNames: Set<String> = ["php-fpm"]
    /// MariaDB 的服务端在部分构建里也叫 `mysqld`。
    static let databaseNames: Set<String> = ["mariadbd", "mysqld"]

    /// 判断一个进程是否确实是 MacStack 启动的那个服务。
    ///
    /// 两道判据**缺一不可**：
    ///
    /// 1. **可执行文件名**来自 `proc_pidpath`，是内核对「这个 PID 正在运行哪个程序」的
    ///    回答。它不读 argv，因此无法用 `exec -a` 伪造。用文件名而不是完整路径，
    ///    是为了不受符号链接解析（Homebrew 的 `opt` → `Cellar`）与安装位置影响。
    /// 2. **专属配置路径**出现在命令行里，证明它用的是 MacStack 的配置，
    ///    而不是同名的其他实例。
    ///
    /// 只用第 2 条（旧实现）是不够的：命令行里出现该路径的进程**未必是服务本身**。
    /// 用户用编辑器打开这个配置文件、或者 `tail -f` 它，命令行里就带着这个路径——
    /// 一旦 PID 被回收并分配给那个进程，只匹配路径就会把它当成残留服务杀掉。
    ///
    /// 刻意**不**改成「开关 + 路径」（例如 `-f <路径>`）：`tail -f <路径>` 同样满足，
    /// 那只是把问题缩小一点，并没有解决。
    static func matches(
        executable: String,
        command: String,
        configurationPath: String,
        executableNames: Set<String>
    ) -> Bool {
        let name = (executable as NSString).lastPathComponent
        guard executableNames.contains(name) else { return false }
        return command.contains(configurationPath)
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

    /// 一个残留服务候选。
    private struct Candidate {
        let pidFile: URL
        /// MacStack 生成的专属配置路径。命令行里必须出现它。
        let configurationPath: String
        /// 该服务的可执行文件名。内核给出的可执行路径必须以它结尾。
        let executableNames: Set<String>
    }

    public func recover(layout: RuntimeLayout = .applicationSupport()) throws -> ResidualServiceRecoveryResult {
        let candidates: [Candidate] = [
            Candidate(
                pidFile: layout.apachePID,
                configurationPath: layout.apacheConfiguration.path,
                executableNames: ResidualIdentity.apacheNames
            ),
            Candidate(
                pidFile: layout.phpPID,
                configurationPath: layout.phpFPMConfiguration.path,
                executableNames: ResidualIdentity.phpNames
            ),
            Candidate(
                pidFile: layout.databasePID,
                configurationPath: layout.databaseConfiguration.path,
                executableNames: ResidualIdentity.databaseNames
            )
        ]
        var stopped = 0
        var removed = 0
        var unresolved: [UnresolvedResidualProcess] = []

        for candidate in candidates {
            guard let raw = try? String(contentsOf: candidate.pidFile, encoding: .utf8),
                  let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else {
                continue
            }

            switch liveness(of: pid) {
            case .gone:
                // 进程确实不存在，PID 文件是失效的。
                try? FileManager.default.removeItem(at: candidate.pidFile)
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
                    reason: "无法读取进程的可执行文件与命令行，无法确认身份。"
                ))
                continue
            }
            guard ResidualIdentity.matches(
                executable: snapshot.executable,
                command: snapshot.command,
                configurationPath: candidate.configurationPath,
                executableNames: candidate.executableNames
            ) else {
                unresolved.append(UnresolvedResidualProcess(
                    pid: pid, command: snapshot.command,
                    reason: "可执行文件是「\((snapshot.executable as NSString).lastPathComponent)」，"
                        + "且命令行里没有 MacStack 专属配置路径，无法确认它属于 MacStack。"
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
            try? FileManager.default.removeItem(at: candidate.pidFile)
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

    /// 进程身份快照：可执行文件 + 命令行 + 启动时间。
    ///
    /// 只用 `kill(pid, 0)` 判断存活是不够的——PID 被回收后重新分配时它照样返回成功，
    /// 因此它只能证明「某个进程占用了这个 PID」，不能证明「还是原来那个进程」。
    /// 启动时间在同一 PID 复用后会不同，所以三者一起比对才是 macOS 上可行的身份判据
    /// （macOS 没有 pidfd）。
    private struct ProcessSnapshot: Equatable {
        let executable: String
        let command: String
        let startedAt: String
    }

    private func processSnapshot(pid: Int32) -> ProcessSnapshot? {
        guard let executable = executablePath(of: pid),
              let startedAt = psField(pid: pid, keyword: "lstart="),
              let command = psField(pid: pid, keyword: "command="),
              !startedAt.isEmpty, !command.isEmpty else { return nil }
        return ProcessSnapshot(executable: executable, command: command, startedAt: startedAt)
    }

    /// 内核对「这个 PID 正在运行哪个程序」的回答。
    ///
    /// 用 `proc_pidpath` 而不是解析 `ps` 的输出：它不读 argv，因此 `exec -a` 伪造不了，
    /// 也不会被 `tail -f <配置文件>` 这类命令行干扰。`libproc` 没有暴露在 Swift 的
    /// Darwin 模块里，所以手动声明。
    private func executablePath(of pid: Int32) -> String? {
        let capacity = 4 * 1024
        var buffer = [UInt8](repeating: 0, count: capacity)
        let written = buffer.withUnsafeMutableBytes { raw -> Int32 in
            proc_pidpath(pid, raw.baseAddress!, UInt32(capacity))
        }
        guard written > 0 else { return nil }
        let path = String(decoding: buffer.prefix(Int(written)), as: UTF8.self)
        return path.isEmpty ? nil : path
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

/// `libproc` 的 `proc_pidpath` 没有暴露在 Swift 的 Darwin 模块里。
@_silgen_name("proc_pidpath")
private func proc_pidpath(_ pid: Int32, _ buffer: UnsafeMutableRawPointer, _ buffersize: UInt32) -> Int32

