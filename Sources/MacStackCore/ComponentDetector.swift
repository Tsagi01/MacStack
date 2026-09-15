import Foundation

public struct ComponentDetector: Sendable {
    public let prefix: URL
    public let portableRuntimeRoot: URL?
    public init(
        prefix: URL = URL(fileURLWithPath: "/opt/homebrew"),
        portableRuntimeRoot: URL? = nil
    ) {
        self.prefix = prefix
        self.portableRuntimeRoot = portableRuntimeRoot
    }

    // 只读查找，不安装软件、不运行候选文件，也不遍历旧 XAMPP 数据。
    public func inspectAll() -> [ComponentInspection] {
        Component.allCases.map(inspect)
    }

    public func inspect(_ component: Component) -> ComponentInspection {
        do {
            if let runtime = try PortableRuntimeLocator(explicitRoot: portableRuntimeRoot).locate() {
                let urls: [URL]
                switch component {
                case .apache: urls = [runtime.layout.apache]
                case .php: urls = [runtime.layout.php, runtime.layout.phpFPM]
                case .mariadb: urls = [runtime.layout.mariaDBServer]
                }
                let native = urls.allSatisfy(isNative)
                return ComponentInspection(
                    component: component,
                    status: native ? .appleSilicon : .incompatible,
                    executablePaths: urls.map(\.path),
                    detail: native
                        ? "来自 MacStack.app 内置便携运行时 \(runtime.manifest.runtimeVersion)，用户端不需要 Homebrew。"
                        : "MacStack.app 内置运行时存在，但没有通过 ARM64 架构校验。"
                )
            }
        } catch {
            return ComponentInspection(
                component: component,
                status: .incompatible,
                executablePaths: [],
                detail: error.localizedDescription
            )
        }
        let candidates: [[String]]
        switch component {
        case .apache:
            candidates = [["opt/httpd/bin/httpd"]]
        case .php:
            candidates = ["php@8.2", "php@8.3", "php@8.4", "php@8.5", "php"].map {
                ["opt/\($0)/bin/php", "opt/\($0)/sbin/php-fpm"]
            }
        case .mariadb:
            candidates = ["mariadb@10.11", "mariadb@11.4", "mariadb@11.8", "mariadb"].map {
                ["opt/\($0)/bin/mariadbd"]
            }
        }
        let files = FileManager.default
        var fallback: ComponentInspection?
        for group in candidates {
            let urls = group.map { prefix.appendingPathComponent($0).resolvingSymlinksInPath() }
            guard urls.allSatisfy({ files.isExecutableFile(atPath: $0.path) }) else { continue }
            let native = urls.allSatisfy { url in
                guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
                defer { try? handle.close() }
                guard let header = try? handle.read(upToCount: 4096) else { return false }
                return MachOHeader.containsARM64(header)
            }
            let result = ComponentInspection(
                component: component,
                status: native ? .appleSilicon : .incompatible,
                executablePaths: urls.map(\.path),
                detail: native ? "主程序包含 ARM64。依赖库、扩展和实际运行验证待接入。" : "发现可执行文件，但未验证到 ARM64 架构。"
            )
            if native { return result }
            fallback = fallback ?? result
        }
        return fallback ?? ComponentInspection(component: component, status: .missing, executablePaths: [],
            detail: "在 \(prefix.path)/opt 的已知位置未找到完整组件；不代表其他位置没有安装。")
    }

    private func isNative(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 4096) else { return false }
        return MachOHeader.containsARM64(header)
    }
}

// Mach-O 头部检测，兼容单架构与 Universal Binary，不依赖外部命令。
public enum MachOHeader {
    public static func containsARM64(_ data: Data) -> Bool {
        architectures(data).contains("arm64")
    }

    public static func architectures(_ data: Data) -> [String] {
        let bytes = Array(data)
        func word(_ offset: Int, little: Bool = false) -> UInt32? {
            guard offset >= 0, offset + 4 <= bytes.count else { return nil }
            let part = Array(bytes[offset..<offset + 4])
            return (little ? Array(part.reversed()) : part).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        func name(_ cpu: UInt32) -> String {
            switch cpu {
            case 0x0100000c: "arm64"
            case 0x01000007: "x86_64"
            default: String(format: "cpu-0x%08x", cpu)
            }
        }
        guard let magic = word(0) else { return [] }
        switch magic {
        case 0xcffaedfe:
            return word(4, little: true).map { [name($0)] } ?? []
        case 0xfeedfacf:
            return word(4).map { [name($0)] } ?? []
        case 0xcafebabe, 0xcafebabf, 0xbebafeca, 0xbfbafeca:
            let little = magic == 0xbebafeca || magic == 0xbfbafeca
            let stride = magic == 0xcafebabf || magic == 0xbfbafeca ? 32 : 20
            guard let count = word(4, little: little), count > 0, count <= 64,
                  bytes.count >= 8 + Int(count) * stride else { return [] }
            return (0..<Int(count)).compactMap { word(8 + $0 * stride, little: little) }.map(name)
        default: return []
        }
    }
}
