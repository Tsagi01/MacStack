import Foundation

public actor LocalWebStackController: ServiceControlling, WebStackControlling {
    private struct ManagedProcess {
        let process: Process
        let logHandle: FileHandle
    }

    private let installation: InstalledWebStack
    private let layout: RuntimeLayout
    private var processes: [Component: ManagedProcess] = [:]

    public init(installation: InstalledWebStack, layout: RuntimeLayout) {
        self.installation = installation
        self.layout = layout
    }

    public func start(_ component: Component) async throws {
        guard component == .apache || component == .php else {
            throw ServiceControlError.unsupportedComponent
        }
        if let current = processes[component], current.process.isRunning { return }
        cleanup(component)

        let process = Process()
        switch component {
        case .apache:
            process.executableURL = installation.apache
            process.arguments = ["-D", "FOREGROUND", "-f", layout.apacheConfiguration.path]
        case .php:
            process.executableURL = installation.phpFPM
            process.arguments = [
                "--nodaemonize",
                "--fpm-config", layout.phpFPMConfiguration.path,
                "--php-ini", layout.phpConfiguration.path
            ]
            process.environment = ProcessInfo.processInfo.environment.merging([
                "PHP_INI_SCAN_DIR": layout.phpExtensionConfigurationDirectory.path
            ]) { _, new in new }
        case .mariadb:
            throw ServiceControlError.unsupportedComponent
        }

        let launchLog = layout.logDirectory.appendingPathComponent("\(component.rawValue)-launcher.log")
        // 这个文件的轮转时机只能在这里：`start` 只在没有存活进程时才会走到，
        // 上一个写入句柄已经关闭，而新句柄还没打开。
        //
        // 之前考虑过在 LogMaintainer 里永久跳过 `*-launcher.log`，那只是把
        // 「轮转后写入进错文件」换成了「这些日志永不轮转、无限增长」。
        // 只轮转自己这一个文件，避免动到其他组件仍持有句柄的日志。
        // 只轮转这个组件自己的日志（`<组件>-launcher.log`）。日志目录与数据库共享，
        // 不能用全量轮转，否则会动到数据库仍持有句柄的日志。
        _ = try? LogMaintainer().rotate(
            directory: layout.logDirectory,
            prefixes: [component.rawValue]
        )
        if !FileManager.default.fileExists(atPath: launchLog.path) {
            FileManager.default.createFile(atPath: launchLog.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: launchLog)
        try handle.seekToEnd()
        process.standardOutput = handle
        process.standardError = handle
        do {
            try process.run()
            processes[component] = ManagedProcess(process: process, logHandle: handle)
        } catch {
            try? handle.close()
            throw error
        }

        try await Task.sleep(for: .milliseconds(250))
        guard process.isRunning else {
            let status = process.terminationStatus
            cleanup(component)
            throw ServiceControlError.exitedEarly(component, status)
        }
    }

    public func stop(_ component: Component) async throws {
        guard let managed = processes[component] else { return }
        guard managed.process.isRunning else {
            cleanup(component)
            return
        }
        managed.process.terminate()
        for _ in 0..<40 {
            if !managed.process.isRunning {
                cleanup(component)
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ServiceControlError.stopTimedOut(component)
    }

    public func state(of component: Component) async -> ServiceState {
        guard component == .apache || component == .php else { return .notConnected }
        guard let managed = processes[component] else { return .stopped }
        if managed.process.isRunning { return .running }
        let status = managed.process.terminationStatus
        cleanup(component)
        return status == 0 ? .stopped : .failed("退出码 \(status)")
    }

    public func startWebStack(httpPort: Int) async throws {
        do {
            try await start(.php)
            try await waitForSocket()
            try await start(.apache)
            try await waitForPHP(httpPort: httpPort)
        } catch {
            try? await stop(.apache)
            try? await stop(.php)
            throw error
        }
    }

    public func stopWebStack() async throws {
        var firstError: Error?
        do { try await stop(.apache) } catch { firstError = error }
        do { try await stop(.php) } catch { firstError = firstError ?? error }
        if let firstError { throw firstError }
    }

    private func waitForSocket() async throws {
        for _ in 0..<30 {
            if FileManager.default.fileExists(atPath: layout.phpSocket.path) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ServiceControlError.healthCheckFailed("PHP-FPM socket 未出现。")
    }

    private func waitForPHP(httpPort: Int) async throws {
        let url = URL(string: "http://127.0.0.1:\(httpPort)/__macstack/health.php")!
        var lastDetail = "HTTP 尚未就绪。"
        for _ in 0..<30 {
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 1
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let body = String(decoding: data, as: UTF8.self)
                if status == 200, body.contains("MacStack Internal Health OK") { return }
                lastDetail = "内部健康检查返回 HTTP \(status)，响应未通过 PHP 标记校验。"
            } catch {
                lastDetail = error.localizedDescription
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ServiceControlError.healthCheckFailed(lastDetail)
    }

    private func cleanup(_ component: Component) {
        guard let managed = processes.removeValue(forKey: component) else { return }
        try? managed.logHandle.synchronize()
        try? managed.logHandle.close()
    }
}
