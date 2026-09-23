import Foundation

public struct DatabaseRestorePlan: Equatable, Sendable {
    public let source: URL
    public let sourceBytes: Int64
    public let availableBytes: Int64
    public let recommendedFreeBytes: Int64
}

public final class DatabaseRestoreJob: @unchecked Sendable {
    private let installation: InstalledDatabaseStack
    private let layout: RuntimeLayout
    private let operatingSystemUser: String
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    public init(
        installation: InstalledDatabaseStack,
        layout: RuntimeLayout = .applicationSupport(),
        operatingSystemUser: String = NSUserName()
    ) {
        self.installation = installation
        self.layout = layout
        self.operatingSystemUser = operatingSystemUser
    }

    public func prepare(source: URL) throws -> DatabaseRestorePlan {
        let input = source.standardizedFileURL
        guard input.pathExtension.lowercased() == "sql",
              let attributes = try? FileManager.default.attributesOfItem(atPath: input.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0 else {
            throw DatabaseBackupError.invalidBackup(input.path)
        }
        let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let values = try input.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let available = values.volumeAvailableCapacityForImportantUsage ?? 0
        let recommended = max(64 * 1_024 * 1_024, bytes * 2)
        guard available == 0 || available >= recommended else {
            throw DatabaseBackupError.insufficientSpace(required: recommended, available: available)
        }
        return DatabaseRestorePlan(
            source: input,
            sourceBytes: bytes,
            availableBytes: available,
            recommendedFreeBytes: recommended
        )
    }

    public func restore(
        plan: DatabaseRestorePlan,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) throws {
        lock.lock()
        cancelled = false
        lock.unlock()
        let errorFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("macstack-restore-\(UUID().uuidString).stderr")
        defer {
            try? FileManager.default.removeItem(at: errorFile)
            lock.lock(); process = nil; lock.unlock()
        }
        FileManager.default.createFile(atPath: errorFile.path, contents: nil)
        let sourceHandle = try FileHandle(forReadingFrom: plan.source)
        let errorHandle = try FileHandle(forWritingTo: errorFile)
        let inputPipe = Pipe()
        defer {
            try? sourceHandle.close()
            try? errorHandle.close()
            try? inputPipe.fileHandleForWriting.close()
        }
        let next = Process()
        next.executableURL = installation.client
        next.arguments = DatabaseClientArguments.standard(
            socket: layout.databaseSocket,
            user: operatingSystemUser
        )
        next.standardInput = inputPipe
        next.standardOutput = FileHandle.nullDevice
        next.standardError = errorHandle
        lock.lock(); process = next; lock.unlock()
        try next.run()

        var completed: Int64 = 0
        do {
            while true {
                if isCancelled { throw DatabaseBackupError.restoreCancelled }
                let data = try sourceHandle.read(upToCount: 1_024 * 1_024) ?? Data()
                if data.isEmpty { break }
                try inputPipe.fileHandleForWriting.write(contentsOf: data)
                completed += Int64(data.count)
                progress(completed, plan.sourceBytes)
            }
            try inputPipe.fileHandleForWriting.close()
            next.waitUntilExit()
        } catch {
            if next.isRunning { next.terminate() }
            next.waitUntilExit()
            if isCancelled { throw DatabaseBackupError.restoreCancelled }
            // 写入失败通常是因为 mariadb 已经退出——客户端在批处理模式下**遇错即停**，
            // SQL 有语法错误就会立刻结束，管道读端关闭，后续写入抛出 EPIPE。
            //
            // 直接把 EPIPE（“Broken pipe”）报给用户毫无意义：真正的原因在它的 stderr 里。
            // 所以子进程非正常退出时优先报它的错误信息，否则用户看到的是
            // “The file couldn't be saved” 而不是 “ERROR 1064 at line 42”。
            try? errorHandle.synchronize()
            let childError = (try? String(contentsOf: errorFile, encoding: .utf8)) ?? ""
            if next.terminationStatus != 0, !childError.isEmpty {
                throw DatabaseBackupError.commandFailed("mariadb restore", next.terminationStatus, childError)
            }
            throw error
        }
        try errorHandle.synchronize()
        let errorText = (try? String(contentsOf: errorFile, encoding: .utf8)) ?? ""
        if isCancelled { throw DatabaseBackupError.restoreCancelled }
        guard next.terminationStatus == 0 else {
            throw DatabaseBackupError.commandFailed("mariadb restore", next.terminationStatus, errorText)
        }
        progress(plan.sourceBytes, plan.sourceBytes)
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        let current = process
        lock.unlock()
        if current?.isRunning == true { current?.terminate() }
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
}
