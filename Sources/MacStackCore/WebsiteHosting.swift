import Foundation
import Darwin

public enum WebsiteHostingError: Error, LocalizedError {
    case missingDirectory(String)
    case unreadableDirectory(String)
    case symbolicLink(String)
    case publicRootOutsideProject(String)
    case unsafePath(String)
    case invalidHostname(String)

    public var errorDescription: String? {
        switch self {
        case .missingDirectory(let path): "网站目录不存在或不是文件夹：\(path)"
        case .unreadableDirectory(let path): "网站目录无法读取：\(path)"
        case .symbolicLink(let path): "当前版本不接受符号链接作为网站根目录：\(path)"
        case .publicRootOutsideProject(let path): "公开目录必须位于项目目录内部：\(path)"
        case .unsafePath(let path): "网站路径包含无法安全写入配置的换行或空字符：\(path)"
        case .invalidHostname(let value): "本地域名必须为空，或使用小写字母、数字、连字符组成的 .localhost 域名：\(value)"
        }
    }
}

public struct WebsiteHostingValidator: Sendable {
    public init() {}

    public func validate(_ website: Website) throws {
        if !website.hostname.isEmpty {
            let expression = try! NSRegularExpression(pattern: "^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\\.localhost$")
            let range = NSRange(website.hostname.startIndex..<website.hostname.endIndex, in: website.hostname)
            guard expression.firstMatch(in: website.hostname, range: range) != nil else {
                throw WebsiteHostingError.invalidHostname(website.hostname)
            }
        }
        let root = URL(fileURLWithPath: website.rootPath, isDirectory: true).standardizedFileURL
        let publicRoot = URL(fileURLWithPath: website.publicRootPath, isDirectory: true).standardizedFileURL
        for url in [root, publicRoot] {
            guard !url.path.contains("\n"), !url.path.contains("\r"), !url.path.contains("\0") else {
                throw WebsiteHostingError.unsafePath(url.path)
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw WebsiteHostingError.missingDirectory(url.path)
            }
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
                throw WebsiteHostingError.symbolicLink(url.path)
            }
            guard Darwin.access(url.path, R_OK | X_OK) == 0 else {
                throw WebsiteHostingError.unreadableDirectory(url.path)
            }
        }
        let realRoot = root.resolvingSymlinksInPath().path
        let realPublic = publicRoot.resolvingSymlinksInPath().path
        guard realPublic == realRoot || realPublic.hasPrefix(realRoot + "/") else {
            throw WebsiteHostingError.publicRootOutsideProject(publicRoot.path)
        }
    }
}

public enum LocalHostname {
    public static func suggested(from name: String) -> String {
        let value = name.lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        let filtered = value.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !filtered.isEmpty, filtered.count <= 63 else { return "" }
        return filtered + ".localhost"
    }
}

public struct PortAvailability: Sendable {
    public init() {}

    public func isAvailable(_ port: Int) -> Bool {
        guard (1024...65535).contains(port) else { return false }
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    public func nextAvailable(startingAt: Int, excluding: Set<Int>) -> Int? {
        guard startingAt <= 65535 else { return nil }
        for port in max(1024, startingAt)...65535 where !excluding.contains(port) {
            if isAvailable(port) { return port }
        }
        return nil
    }
}
