import Foundation
import CryptoKit
import Darwin

public enum WebsiteMigrationError: Error, LocalizedError {
    case sourceMissing(String)
    case sourceNotDirectory(String)
    case sourceContainsSymlink(String)
    case destinationParentInvalid(String)
    case destinationExists(String)
    case destinationInsideSource(String)
    case sourceChanged
    case verificationFailed

    public var errorDescription: String? {
        switch self {
        case .sourceMissing(let path): "源网站不存在：\(path)"
        case .sourceNotDirectory(let path): "源网站不是普通目录：\(path)"
        case .sourceContainsSymlink(let path): "网站包含符号链接，当前版本为避免复制到目录外而拒绝迁移：\(path)"
        case .destinationParentInvalid(let path): "目标位置不是可写的普通目录：\(path)"
        case .destinationExists(let path): "目标已存在，为避免覆盖而停止：\(path)"
        case .destinationInsideSource(let path):
            "目标位置在源网站内部：\(path)\n把网站复制到它自己的子目录里没有意义，请另选一个源目录之外的位置。"
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
        try validateNoNesting(source: source, destinationParent: destinationParent)
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
        // 预览通过之后目标位置仍可能被改到源内部（例如源目录被移动过），
        // 因此这里再校验一次，而不是只依赖 prepare。
        try validateNoNesting(source: plan.source, destinationParent: plan.destination.deletingLastPathComponent())
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

    /// 目标位置不能在源目录内部。
    ///
    /// 否则暂存目录会被创建在**源里面**：`migrate` 先把源复制到
    /// `<目标上级目录>/.macstack-staging-<UUID>`，而这个暂存目录此时就在源目录里。
    /// `copyItem` 遍历源时会遇到它自己——结果取决于 Foundation 是先枚举再复制、
    /// 还是边走边复制，但两种都不是用户要的：前者会把进行中的副本也复制进去，
    /// 后者一路递归下去直到路径超长或磁盘写满。而校验要等复制**完成**才会跑。
    ///
    /// 更重要的是：把网站复制到它自己的子目录里本来就没有意义，应当直接拒绝。
    private func validateNoNesting(source: URL, destinationParent: URL) throws {
        // 用 realpath 解析后再比，否则 `~/Sites` 这类符号链接会绕过检查。
        let sourcePath = realPath(source)
        let parentPath = realPath(destinationParent)
        let prefix = sourcePath.hasSuffix("/") ? sourcePath : sourcePath + "/"
        guard parentPath != sourcePath, !parentPath.hasPrefix(prefix) else {
            throw WebsiteMigrationError.destinationInsideSource(destinationParent.path)
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
