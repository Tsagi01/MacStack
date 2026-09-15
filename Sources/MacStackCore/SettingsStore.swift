import Foundation

public struct SettingsStore: Sendable {
    public let directory: URL
    public var fileURL: URL { directory.appendingPathComponent("workspace.json") }
    public var version1BackupURL: URL { directory.appendingPathComponent("workspace-v1-backup.json") }
    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacStack", isDirectory: true)
    }

    // 首次启动只返回默认值，显式保存时才创建应用目录。
    public func load() throws -> WorkspaceSettings {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return WorkspaceSettings() }
        var value = try JSONDecoder().decode(WorkspaceSettings.self, from: Data(contentsOf: fileURL))
        guard value.schemaVersion == 1 || value.schemaVersion == 2 else { throw SettingsError.unsupportedSchema }
        if value.schemaVersion == 1 { try value.migrateFromVersion1() }
        try value.validate()
        return value
    }

    public func save(_ value: WorkspaceSettings) throws {
        guard value.schemaVersion == 2 else { throw SettingsError.unsupportedSchema }
        try value.validate()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: fileURL.path),
           !FileManager.default.fileExists(atPath: version1BackupURL.path),
           let data = try? Data(contentsOf: fileURL),
           let existing = try? JSONDecoder().decode(WorkspaceSettings.self, from: data),
           existing.schemaVersion == 1 {
            try data.write(to: version1BackupURL, options: .withoutOverwriting)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: fileURL, options: .atomic)
    }
}
