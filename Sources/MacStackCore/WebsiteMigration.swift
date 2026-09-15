import Foundation
import CryptoKit
import Darwin

public enum WebsiteMigrationError: Error, LocalizedError {
    case sourceMissing(String)
    case sourceNotDirectory(String)
    case sourceContainsSymlink(String)
    case destinationParentInvalid(String)
    case destinationExists(String)
    case sourceChanged
    case verificationFailed

    public var errorDescription: String? {
        switch self {
        case .sourceMissing(let path): "源网站不存在：\(path)"
        case .sourceNotDirectory(let path): "源网站不是普通目录：\(path)"
        case .sourceContainsSymlink(let path): "网站包含符号链接，当前版本为避免复制到目录外而拒绝迁移：\(path)"
        case .destinationParentInvalid(let path): "目标位置不是可写的普通目录：\(path)"
        case .destinationExists(let path): "目标已存在，为避免覆盖而停止：\(path)"
        case .sourceChanged: "生成预览后源网站发生变化，请重新预览。"
        case .verificationFailed: "复制后的文件清单或 SHA-256 校验不一致；未发布不完整副本。"
        }
    }
}

public struct WebsiteMigrationFile: Codable, Equatable, Sendable {
    public let relativePath: String
    public let byteCount: Int64
    public let sha256: String
}

public struct WebsiteMigrationPlan: Codable, Equatable, Sendable {
    public let createdAt: Date
    public let source: URL
    public let destination: URL
    public let files: [WebsiteMigrationFile]

    public var fileCount: Int { files.count }
    public var totalByteCount: Int64 { files.reduce(0) { $0 + $1.byteCount } }
}

public struct WebsiteMigrationResult: Equatable, Sendable {
    public let destination: URL
    public let fileCount: Int
    public let byteCount: Int64
}

public struct WebsiteMigrator: Sendable {
    public init() {}

    public func prepare(source: URL, destinationParent: URL) throws -> WebsiteMigrationPlan {
        let source = source.standardizedFileURL
        let destinationParent = destinationParent.standardizedFileURL
        try validateSource(source)
        try validateDestinationParent(destinationParent)
        let destination = destinationParent.appendingPathComponent(source.lastPathComponent, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw WebsiteMigrationError.destinationExists(destination.path)
        }
        return WebsiteMigrationPlan(
            createdAt: Date(),
            source: source,
            destination: destination,
            files: try manifest(for: source)
        )
    }

    public func migrate(_ plan: WebsiteMigrationPlan) throws -> WebsiteMigrationResult {
        try validateSource(plan.source)
        try validateDestinationParent(plan.destination.deletingLastPathComponent())
        guard !FileManager.default.fileExists(atPath: plan.destination.path) else {
            throw WebsiteMigrationError.destinationExists(plan.destination.path)
        }
        guard try manifest(for: plan.source) == plan.files else {
            throw WebsiteMigrationError.sourceChanged
        }

        let staging = plan.destination.deletingLastPathComponent()
            .appendingPathComponent(".macstack-staging-\(UUID().uuidString)", isDirectory: true)
        defer {
            if FileManager.default.fileExists(atPath: staging.path) {
                try? FileManager.default.removeItem(at: staging)
            }
        }
        try FileManager.default.copyItem(at: plan.source, to: staging)
        guard try manifest(for: staging) == plan.files,
              try manifest(for: plan.source) == plan.files else {
            throw WebsiteMigrationError.verificationFailed
        }
        try FileManager.default.moveItem(at: staging, to: plan.destination)
        return WebsiteMigrationResult(
            destination: plan.destination,
            fileCount: plan.fileCount,
            byteCount: plan.totalByteCount
        )
    }

    private func validateSource(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw WebsiteMigrationError.sourceMissing(url.path)
        }
        guard isDirectory.boolValue,
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw WebsiteMigrationError.sourceNotDirectory(url.path)
        }
    }

    private func validateDestinationParent(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.isWritableFile(atPath: url.path),
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw WebsiteMigrationError.destinationParentInvalid(url.path)
        }
    }

    private func manifest(for root: URL) throws -> [WebsiteMigrationFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let canonicalRoot = URL(fileURLWithPath: realPath(root), isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: canonicalRoot, includingPropertiesForKeys: keys) else {
            throw WebsiteMigrationError.sourceNotDirectory(root.path)
        }
        var result: [WebsiteMigrationFile] = []
        let prefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
        while let url = enumerator.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                throw WebsiteMigrationError.sourceContainsSymlink(url.path)
            }
            guard values.isRegularFile == true else { continue }
            guard url.path.hasPrefix(prefix) else { throw WebsiteMigrationError.sourceContainsSymlink(url.path) }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            result.append(WebsiteMigrationFile(
                relativePath: String(url.path.dropFirst(prefix.count)),
                byteCount: Int64(values.fileSize ?? data.count),
                sha256: digest
            ))
        }
        return result.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    private func realPath(_ url: URL) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        return url.path.withCString { path in
            guard Darwin.realpath(path, &buffer) != nil else { return url.path }
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}
