import Foundation

public struct BackupRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let database: String
    public let filePath: String
    public let byteCount: Int64
    public let createdAt: Date
    public let automatic: Bool
    /// 是否是「恢复备份之前自动生成的快照」。
    ///
    /// 它登记为手动备份（`automatic == false`），因此**不会被保留策略清理**：
    /// 恢复出错时这份快照就是唯一的退路，不能因为「太旧」被删掉。
    public let preRestoreSnapshot: Bool

    public init(
        id: UUID = UUID(),
        database: String,
        filePath: String,
        byteCount: Int64,
        createdAt: Date = Date(),
        automatic: Bool,
        preRestoreSnapshot: Bool = false
    ) {
        self.id = id
        self.database = database
        self.filePath = filePath
        self.byteCount = byteCount
        self.createdAt = createdAt
        self.automatic = automatic
        self.preRestoreSnapshot = preRestoreSnapshot
    }

    /// 手写解码。
    ///
    /// 旧版本的 `catalog.json` 里没有 `preRestoreSnapshot` 这个键。用合成的 `Codable`
    /// 会因为缺键直接抛错，导致**整份清单读不出来**（`load()` 里 `try?` 会把它吞成空数组，
    /// 用户看到的是「所有备份都消失了」）。因此必须按缺省 false 解码。
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        database = try values.decode(String.self, forKey: .database)
        filePath = try values.decode(String.self, forKey: .filePath)
        byteCount = try values.decode(Int64.self, forKey: .byteCount)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        automatic = try values.decode(Bool.self, forKey: .automatic)
        preRestoreSnapshot = try values.decodeIfPresent(Bool.self, forKey: .preRestoreSnapshot) ?? false
    }
}

/// 保留策略的预演结果。
///
/// 只描述「按当前策略会发生什么」，不代表已经执行。
public struct BackupPrunePreview: Equatable, Sendable {
    /// 自动备份总数。
    public let automaticCount: Int
    /// 自动备份占用字节数。
    public let automaticBytes: Int64
    /// 按策略会被清理的份数。
    public let removableCount: Int
    /// 会被清理的字节数。
    public let removableBytes: Int64
    /// 手动备份总数（不受清理影响）。
    public let manualCount: Int

    public init(
        automaticCount: Int,
        automaticBytes: Int64,
        removableCount: Int,
        removableBytes: Int64,
        manualCount: Int
    ) {
        self.automaticCount = automaticCount
        self.automaticBytes = automaticBytes
        self.removableCount = removableCount
        self.removableBytes = removableBytes
        self.manualCount = manualCount
    }

    public var hasSomethingToClean: Bool { removableCount > 0 }
}

/// 备份清单的读写。
///
/// **这是 `actor`，不是 `struct`，这是有意的。**
///
/// 之前它是无锁的 `Sendable` struct，却被两处并发访问：每 60 秒的自动备份调度器在
/// `Task.detached` 里读写它，界面同时可能在主线程读写。而 `register` 与
/// `pruneAutomaticBackups` 都是**读-改-写整个 `catalog.json`**：
///
/// ```
/// var records = load()   // 读
/// records.insert(...)    // 改
/// try save(records)      // 全量覆盖写
/// ```
///
/// 具体能复现的后果：自动备份跑到 `pruneAutomaticBackups` 时，用户点了「导出当前数据库」，
/// 等导出的 `register()` 写完之后，清理逻辑用一份**旧快照**覆盖回去，刚导出的备份就从
/// 列表里消失了，而它的 `.sql` 文件还留在磁盘上 —— 正是这个类型想避免的「记录没了、
/// 文件还在」的孤儿，从另一条路径回来。
///
/// 改成 actor 后，所有读写自动串行化，不再需要调用方自己协调。
public enum BackupCatalogError: Error, LocalizedError {
    case unsafeDatabaseName(String)

    public var errorDescription: String? {
        switch self {
        case .unsafeDatabaseName(let name):
            "数据库名不能用作文件名：\(name)\n名称中不能包含路径分隔符或空字符。"
        }
    }
}

public actor BackupCatalogStore {
    /// 每个库保留的自动备份份数上限。
    ///
    /// 天数保留策略之外的第二道防线。`backupRetentionDays = 0` 表示「不按天数清理」，
    /// 若没有份数上限，自动备份会无限增长——这是去掉 `register` 里 200 条截断后
    /// 暴露出来的问题：截断本身会产生孤儿文件，但它至少挡住了无限增长。
    ///
    /// **手动备份不受这个上限约束**，那是用户主动创建的。
    public static let maximumAutomaticBackupsPerDatabase = 50

    public nonisolated let directory: URL
    public nonisolated var catalogURL: URL { directory.appendingPathComponent("catalog.json") }

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacStack/backups", isDirectory: true)
        self.directory = base
    }

    public func load() -> [BackupRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: catalogURL),
              let records = try? decoder.decode([BackupRecord].self, from: data) else { return [] }
        return records.sorted { $0.createdAt > $1.createdAt }
    }

    /// 登记一份新备份。
    ///
    /// **刻意不在这里截断记录数。** 之前写的是 `records.prefix(200)`，后果是被挤出去的
    /// 记录对应的 `.sql` 文件仍留在磁盘上，而 `pruneAutomaticBackups` 只遍历 catalog
    /// 里现存的记录 —— 那些文件从此再也找不到，永远不会被清理；手动备份也可能从
    /// 界面上消失但文件还在。
    ///
    /// 删除记录的唯一位置是 `pruneAutomaticBackups`，它会**连同文件一起**删掉，
    /// 因此不会产生「记录没了、文件还在」的孤儿。
    public func register(
        database: String,
        file: URL,
        automatic: Bool,
        createdAt: Date = Date(),
        preRestoreSnapshot: Bool = false
    ) throws -> [BackupRecord] {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        var records = load()
        records.insert(
            BackupRecord(
                database: database,
                filePath: file.path,
                byteCount: size,
                createdAt: createdAt,
                automatic: automatic,
                preRestoreSnapshot: preRestoreSnapshot
            ),
            at: 0
        )
        try save(records)
        return records
    }

    public func destination(database: String, date: Date = Date()) throws -> URL {
        // 库名会拼进文件名，所以必须先确认它可以安全地作为一个路径组件。
        //
        // MariaDB **接受**含 `/` 的库名（实测 `a/b` 可以创建），而库名是从服务器读回来的
        // 外部数据——不校验的话 `../x` 这类名字会让备份写到目录之外。
        // 这里只拒绝路径分隔符与空字符，不套用 `DatabaseBackupManager` 那套
        // 「字母开头 + 字母数字下划线」的严格规则：`my-site`、`中文库` 都是合法库名，
        // 也都能安全用作文件名。
        guard !database.isEmpty,
              !database.contains("/"),
              !database.contains("\\"),
              !database.contains("\0") else {
            throw BackupCatalogError.unsafeDatabaseName(database)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return directory.appendingPathComponent("\(database)-\(formatter.string(from: date))-\(UUID().uuidString.prefix(6)).sql")
    }

    /// 某个业务库最近一次自动备份的时间。
    ///
    /// 必须按库判断。之前用的是「全局最新一次自动备份时间」，后果是新登记的业务库
    /// 要等满一整个间隔（最长 168 小时）才会被首次备份。
    public func lastAutomaticBackupDate(database: String) -> Date? {
        // load() 已按 createdAt 倒序，第一条即最新。
        load().first { $0.automatic && $0.database == database }?.createdAt
    }

    /// 选出应当清理的自动备份。
    ///
    /// **预览与执行共用这一套判断。** 两边各写一份的话，会出现「预览说会删 3 份、
    /// 执行却删了 5 份」——那比没有预览更糟，因为用户会基于错误的信息做决定。
    private func pruneSelection(
        olderThanDays days: Int,
        keepingAtMost maximumPerDatabase: Int,
        now: Date
    ) -> (removable: [BackupRecord], kept: [BackupRecord]) {
        let cutoff = days > 0 ? now.addingTimeInterval(-TimeInterval(days) * 86_400) : nil

        // load() 已按 createdAt 倒序，因此每个库的自动备份按「新 → 旧」出现，
        // 数到第 N 个之后的就是超出份数上限的。
        var automaticSeenPerDatabase: [String: Int] = [:]
        var removable: [BackupRecord] = []
        var kept: [BackupRecord] = []

        for record in load() {
            guard record.automatic else {
                // 手动备份只受用户自己控制，不参与自动清理。
                kept.append(record)
                continue
            }
            let seen = automaticSeenPerDatabase[record.database, default: 0]
            automaticSeenPerDatabase[record.database] = seen + 1

            let expiredByAge = cutoff.map { record.createdAt < $0 } ?? false
            let expiredByCount = maximumPerDatabase > 0 && seen >= maximumPerDatabase
            if expiredByAge || expiredByCount {
                removable.append(record)
            } else {
                kept.append(record)
            }
        }
        return (removable, kept)
    }

    /// 按当前保留策略**预演**会清理掉什么，但**不删任何东西**。
    ///
    /// 用来在界面上告诉用户「这样设置会删掉几份、释放多少空间」，而不是等清理
    /// 真的跑完才发现。
    public func prunePreview(
        olderThanDays days: Int,
        keepingAtMost maximumPerDatabase: Int = BackupCatalogStore.maximumAutomaticBackupsPerDatabase,
        now: Date = Date()
    ) -> BackupPrunePreview {
        let records = load()
        let selection = pruneSelection(
            olderThanDays: days,
            keepingAtMost: maximumPerDatabase,
            now: now
        )
        let automatic = records.filter(\.automatic)
        return BackupPrunePreview(
            automaticCount: automatic.count,
            automaticBytes: automatic.reduce(0) { $0 + $1.byteCount },
            removableCount: selection.removable.count,
            removableBytes: selection.removable.reduce(0) { $0 + $1.byteCount },
            manualCount: records.count - automatic.count
        )
    }

    /// 清理自动备份：按天数超期，或按份数超出上限。**文件与记录一起删。**
    ///
    /// 两条策略同时生效：
    ///
    /// - `days > 0`：删除早于该天数的自动备份。`days == 0` 表示不按天数清理。
    /// - `maximumPerDatabase > 0`：每个库最多保留这么多份自动备份，超出的按时间从旧到新删。
    ///   即使 `days == 0`，这条也生效——否则自动备份会无限增长。
    ///
    /// 手动备份不受影响。
    ///
    /// - Returns: 实际删除的文件数。
    @discardableResult
    public func pruneAutomaticBackups(
        olderThanDays days: Int,
        keepingAtMost maximumPerDatabase: Int = BackupCatalogStore.maximumAutomaticBackupsPerDatabase,
        now: Date = Date()
    ) -> Int {
        let container = directory.standardizedFileURL.path + "/"
        let selection = pruneSelection(
            olderThanDays: days,
            keepingAtMost: maximumPerDatabase,
            now: now
        )
        var removed = 0
        var kept = selection.kept

        for record in selection.removable {
            // 只删自己备份目录里的文件。catalog 万一被改过，也不能波及目录外的路径。
            let url = URL(fileURLWithPath: record.filePath).standardizedFileURL
            guard url.path.hasPrefix(container) else {
                kept.append(record)
                continue
            }
            if FileManager.default.fileExists(atPath: url.path) {
                do { try FileManager.default.removeItem(at: url) }
                catch {
                    // 删不掉就保留记录，下次再试，不留下「记录没了文件还在」的孤儿。
                    kept.append(record)
                    continue
                }
            }
            removed += 1
        }
        if removed > 0 { try? save(kept) }
        return removed
    }

    private func save(_ records: [BackupRecord]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(records).write(to: catalogURL, options: .atomic)
    }
}
