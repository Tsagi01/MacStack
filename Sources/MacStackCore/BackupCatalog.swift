import Foundation

public struct BackupRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let database: String
    public let filePath: String
    public let byteCount: Int64
    public let createdAt: Date
    public let automatic: Bool

    public init(id: UUID = UUID(), database: String, filePath: String, byteCount: Int64, createdAt: Date = Date(), automatic: Bool) {
        self.id = id
        self.database = database
        self.filePath = filePath
        self.byteCount = byteCount
        self.createdAt = createdAt
        self.automatic = automatic
    }
}

public struct BackupCatalogStore: Sendable {
    public let directory: URL
    public var catalogURL: URL { directory.appendingPathComponent("catalog.json") }

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
    public func register(database: String, file: URL, automatic: Bool, createdAt: Date = Date()) throws -> [BackupRecord] {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        var records = load()
        records.insert(BackupRecord(database: database, filePath: file.path, byteCount: size, createdAt: createdAt, automatic: automatic), at: 0)
        try save(records)
        return records
    }

    public func destination(database: String, date: Date = Date()) throws -> URL {
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

    /// 删除超期的**自动**备份文件，并同步移除 catalog 记录。手工备份不动。
    ///
    /// 之前只把 catalog 截断到 200 条记录，`.sql` 文件本身从不删除，
    /// 开了自动备份之后磁盘会无限增长。
    ///
    /// - Returns: 实际删除的文件数。
    @discardableResult
    public func pruneAutomaticBackups(olderThanDays days: Int, now: Date = Date()) -> Int {
        guard days > 0 else { return 0 }
        let cutoff = now.addingTimeInterval(-TimeInterval(days) * 86_400)
        let container = directory.standardizedFileURL.path + "/"

        var removed = 0
        var kept: [BackupRecord] = []
        for record in load() {
            guard record.automatic, record.createdAt < cutoff else {
                kept.append(record)
                continue
            }
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
