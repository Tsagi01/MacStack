import Foundation

public struct ServiceIntent: Codable, Equatable, Sendable {
    public var webRunning: Bool
    public var databaseRunning: Bool

    public init(webRunning: Bool = false, databaseRunning: Bool = false) {
        self.webRunning = webRunning
        self.databaseRunning = databaseRunning
    }
}

public struct ServiceIntentStore: Sendable {
    public let fileURL: URL

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacStack", isDirectory: true)
        fileURL = base.appendingPathComponent("service-intent.json")
    }

    public func load() -> ServiceIntent {
        guard let data = try? Data(contentsOf: fileURL),
              let value = try? JSONDecoder().decode(ServiceIntent.self, from: data) else {
            return ServiceIntent()
        }
        return value
    }

    public func save(_ value: ServiceIntent) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: fileURL, options: .atomic)
    }
}
